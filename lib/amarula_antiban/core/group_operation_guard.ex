defmodule AmarulaAntiban.Core.GroupOperationGuard do
  @moduledoc """
  Pure fixed-window rate limiter for group operations (add/remove/create/invite).

  Unlike message sends, group operations (`Amarula.Group.participants/4`,
  `Amarula.Group.create/3`, `Amarula.Group.invite_code/2`, ...) don't flow
  through `Amarula.Plugin`'s `on_send`/`on_recv` pipeline — that pipeline only
  wraps message sends. Hosts must call `check/4` explicitly before invoking a
  group operation:

      case AmarulaAntiban.check_group_operation(session, :add, group_jid) do
        {:allow, :ok} -> Amarula.Group.participants(conn, group_jid, participants, :add)
        {:deny, decision} -> {:error, decision.detail}
      end

  Each `{operation, key}` pair gets its own fixed (non-sliding) window: the
  first call in a window is always allowed and starts the window at count 1;
  subsequent calls increment the counter until `limit.max` is reached, after
  which every call is denied until the window's `reset_at` elapses.
  """

  defmodule Config do
    @moduledoc "Per-operation limits and the injected random source's config-free counterpart."

    @type limit :: %{max: pos_integer(), window_ms: pos_integer()}
    @type t :: %__MODULE__{enabled: boolean(), limits: %{atom() => limit()}}

    defstruct enabled: false,
              limits: %{
                add: %{max: 3, window_ms: 600_000},
                remove: %{max: 5, window_ms: 600_000},
                create: %{max: 2, window_ms: 600_000},
                invite: %{max: 10, window_ms: 600_000}
              }
  end

  @typedoc "The default config covers `:add | :remove | :create | :invite`; any atom present in `config.limits` works."
  @type operation :: atom()
  @type window :: %{count: pos_integer(), reset_at: integer()}
  @type t :: %__MODULE__{config: Config.t(), windows: %{String.t() => window()}}
  @type ban_signal :: :reachout_restricted | :rate_overlimit | :group_locked | :invite_expired

  defstruct config: nil, windows: %{}

  @doc "Builds a guard from keyword options or a map."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []), do: %__MODULE__{config: struct!(Config, Map.new(options)), windows: %{}}

  @doc """
  Checks and, on success, reserves one `{op, key}` slot in the current window.

  `key` is the group JID, except for `:create` where upstream uses the new
  group's subject (there is no JID yet).
  """
  @spec check(t(), operation(), String.t(), integer()) ::
          {:allow, t()} | {:deny, String.t(), non_neg_integer(), t()}
  def check(%__MODULE__{config: %{enabled: false}} = guard, _op, _key, _now_ms),
    do: {:allow, guard}

  def check(guard, op, key, now_ms) do
    window_key = window_key(op, key)
    limit = Map.fetch!(guard.config.limits, op)

    case Map.get(guard.windows, window_key) do
      nil ->
        {:allow, put_window(guard, window_key, now_ms, limit)}

      %{reset_at: reset_at} when now_ms > reset_at ->
        {:allow, put_window(guard, window_key, now_ms, limit)}

      %{count: count} = entry when count >= limit.max ->
        retry_after_sec = ceil((entry.reset_at - now_ms) / 1000)
        {:deny, deny_reason(op, retry_after_sec), retry_after_sec, guard}

      entry ->
        {:allow, put_in_window(guard, window_key, %{entry | count: entry.count + 1})}
    end
  end

  @doc "Clears one `{op, key}` window, allowing immediate reuse."
  @spec reset(t(), operation(), String.t()) :: t()
  def reset(guard, op, key),
    do: %{guard | windows: Map.delete(guard.windows, window_key(op, key))}

  @doc """
  Classifies a group-operation error into a ban-adjacent signal, or `nil`.

  Amarula's group operations fail as `{:error, {:group_op_failed, code,
  text}}` — a structured tuple, never a bare string — so this matches on the
  server's own `text` condition instead of parsing message substrings like
  upstream's JS regex/substring matching did. The four `text` values below are
  confirmed WhatsApp binary-protocol tokens (see
  `Amarula.Protocol.Binary.Constants`); the mapping from token to ban-adjacent
  meaning follows public WhatsApp/XMPP stanza-error conventions and has not
  been independently verified against a live server for group operations
  specifically — treat it as a best-effort classification to refine once real
  error payloads are observed.
  """
  @spec classify_error(term()) :: ban_signal() | nil
  def classify_error({:group_op_failed, _code, "rate-overlimit"}), do: :rate_overlimit
  def classify_error({:group_op_failed, _code, "locked"}), do: :group_locked
  def classify_error({:group_op_failed, _code, "forbidden"}), do: :reachout_restricted
  def classify_error({:group_op_failed, _code, "item-not-found"}), do: :invite_expired
  def classify_error(_reason), do: nil

  @doc "Returns lightweight observability stats."
  @spec stats(t()) :: %{tracked_windows: non_neg_integer()}
  def stats(guard), do: %{tracked_windows: map_size(guard.windows)}

  @doc "Exports windows for persistence."
  @spec export(t()) :: map()
  def export(guard), do: %{windows: guard.windows}

  @doc "Restores windows from a persisted map while retaining configuration."
  @spec restore(t(), map()) :: t()
  def restore(guard, state) when is_map(state) do
    case persisted_value(state, :windows) do
      windows when is_map(windows) -> %{guard | windows: normalize_windows(windows)}
      _invalid -> guard
    end
  end

  defp window_key(op, key), do: "#{op}:#{key}"

  defp put_window(guard, window_key, now_ms, limit) do
    put_in_window(guard, window_key, %{count: 1, reset_at: now_ms + limit.window_ms})
  end

  defp put_in_window(guard, window_key, window),
    do: %{guard | windows: Map.put(guard.windows, window_key, window)}

  defp deny_reason(op, retry_after_sec) do
    minutes = ceil(retry_after_sec / 60)

    "Too many #{op} attempts. WhatsApp rate-limits group operations — " <>
      "wait #{minutes} min before trying again."
  end

  defp normalize_windows(windows),
    do: Map.new(windows, fn {key, record} -> {to_string(key), normalize_window(record)} end)

  defp normalize_window(record) when is_map(record) do
    %{
      count: persisted_int(record, :count, 0),
      reset_at: persisted_int(record, :reset_at, 0)
    }
  end

  defp normalize_window(_invalid), do: %{count: 0, reset_at: 0}

  defp persisted_int(map, key, default) do
    case persisted_value(map, key, default) do
      value when is_integer(value) -> value
      _invalid -> default
    end
  end

  defp persisted_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
