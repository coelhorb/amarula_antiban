defmodule AmarulaAntiban.Core.ContactGraph do
  @moduledoc """
  Pure social-graph warmer for contact handshakes and group lurk periods.

  The state machine mirrors the upstream progression
  `:stranger -> :handshake_sent -> :handshake_complete -> :known`.
  """

  alias AmarulaAntiban.Jid

  @milliseconds_per_day 86_400_000
  @milliseconds_per_minute 60_000

  defmodule Config do
    @moduledoc "Contact-graph thresholds."
    defstruct enabled: false,
              require_handshake_before_group_send: true,
              handshake_min_delay_ms: 3_600_000,
              group_lurk_period_ms: 43_200_000,
              max_stranger_messages_per_day: 5,
              auto_register_on_incoming: true

    @type t :: %__MODULE__{
            enabled: boolean(),
            require_handshake_before_group_send: boolean(),
            handshake_min_delay_ms: non_neg_integer(),
            group_lurk_period_ms: non_neg_integer(),
            max_stranger_messages_per_day: non_neg_integer(),
            auto_register_on_incoming: boolean()
          }
  end

  defmodule Stats do
    @moduledoc "Contact and group graph statistics."
    defstruct known_contacts: 0,
              pending_handshakes: 0,
              strangers_today: 0,
              groups_joined: []

    @type t :: %__MODULE__{
            known_contacts: non_neg_integer(),
            pending_handshakes: non_neg_integer(),
            strangers_today: non_neg_integer(),
            groups_joined: [map()]
          }
  end

  @type contact_state :: :stranger | :handshake_sent | :handshake_complete | :known
  @type t :: %__MODULE__{
          config: Config.t(),
          contacts: map(),
          groups: map(),
          stranger_messages_today: non_neg_integer(),
          last_stranger_reset_day: integer()
        }

  defstruct config: nil,
            contacts: %{},
            groups: %{},
            stranger_messages_today: 0,
            last_stranger_reset_day: 0

  @doc "Builds a graph at the injected time."
  @spec new(keyword() | map(), integer()) :: t()
  def new(options \\ [], now_ms) do
    %__MODULE__{
      config: struct!(Config, Map.new(options)),
      last_stranger_reset_day: day(now_ms)
    }
  end

  @doc "Checks a contact or group and returns the updated daily counter state."
  @spec can_message(t(), String.t(), integer()) ::
          {:allow, boolean(), t()} | {:deny, String.t(), boolean(), t()}
  def can_message(%__MODULE__{config: %{enabled: false}} = graph, _jid, _now_ms),
    do: {:allow, false, graph}

  def can_message(graph, jid, now_ms) do
    graph = reset_day_if_needed(graph, now_ms)

    if Jid.group?(jid),
      do: check_group(graph, jid, now_ms),
      else: check_contact(graph, jid, now_ms)
  end

  @doc "Marks a one-to-one handshake as sent at `now_ms`."
  @spec mark_handshake_sent(t(), String.t(), integer()) :: t()
  def mark_handshake_sent(%__MODULE__{config: %{enabled: false}} = graph, _jid, _now_ms),
    do: graph

  def mark_handshake_sent(graph, jid, now_ms) do
    if Jid.group?(jid) do
      graph
    else
      put_in(graph.contacts[jid], %{state: :handshake_sent, handshake_sent_at: now_ms})
    end
  end

  @doc "Marks a contact handshake complete."
  @spec mark_handshake_complete(t(), String.t()) :: t()
  def mark_handshake_complete(graph, jid), do: put_contact_state(graph, jid, :handshake_complete)

  @doc "Registers a contact as known, bypassing handshake checks."
  @spec register_known_contact(t(), String.t()) :: t()
  def register_known_contact(graph, jid), do: put_contact_state(graph, jid, :known)

  @doc "Registers a group join for lurk-period enforcement."
  @spec register_group_join(t(), String.t(), integer()) :: t()
  def register_group_join(%__MODULE__{config: %{enabled: false}} = graph, _jid, _now_ms),
    do: graph

  def register_group_join(graph, jid, now_ms) do
    if Jid.group?(jid), do: put_in(graph.groups[jid], %{joined_at: now_ms}), else: graph
  end

  @doc "Returns a contact's state; groups are always considered known."
  @spec contact_state(t(), String.t()) :: contact_state()
  def contact_state(graph, jid) do
    if Jid.group?(jid), do: :known, else: get_in(graph.contacts, [jid, :state]) || :stranger
  end

  @doc "Handles an incoming message according to auto-registration policy."
  @spec incoming(t(), String.t()) :: t()
  def incoming(
        %__MODULE__{config: %{enabled: true, auto_register_on_incoming: true}} = graph,
        jid
      ),
      do: register_known_contact(graph, jid)

  def incoming(graph, _jid), do: graph

  @doc "Returns graph statistics."
  @spec stats(t()) :: Stats.t()
  def stats(graph) do
    values = Map.values(graph.contacts)

    %Stats{
      known_contacts: Enum.count(values, &(&1.state == :known)),
      pending_handshakes: Enum.count(values, &(&1.state == :handshake_sent)),
      strangers_today: graph.stranger_messages_today,
      groups_joined:
        Enum.map(graph.groups, fn {jid, record} ->
          %{
            group_jid: jid,
            joined_at: record.joined_at,
            first_send_unlocks_at: record.joined_at + graph.config.group_lurk_period_ms
          }
        end)
    }
  end

  @doc "Clears graph state and resets the UTC day anchor."
  @spec reset(t(), integer()) :: t()
  def reset(graph, now_ms) do
    %{
      graph
      | contacts: %{},
        groups: %{},
        stranger_messages_today: 0,
        last_stranger_reset_day: day(now_ms)
    }
  end

  @doc "Exports graph state for persistence."
  @spec export(t()) :: map()
  def export(graph) do
    Map.take(graph, [:contacts, :groups, :stranger_messages_today, :last_stranger_reset_day])
  end

  @doc "Restores graph state while retaining configuration."
  @spec restore(t(), map()) :: t()
  def restore(graph, state) when is_map(state) do
    %{
      graph
      | contacts: state |> persisted_value(:contacts, %{}) |> normalize_contacts(),
        groups: state |> persisted_value(:groups, %{}) |> normalize_groups(),
        stranger_messages_today:
          persisted_value(state, :stranger_messages_today, graph.stranger_messages_today),
        last_stranger_reset_day:
          persisted_value(state, :last_stranger_reset_day, graph.last_stranger_reset_day)
    }
  end

  defp check_group(graph, jid, now_ms) do
    case Map.get(graph.groups, jid) do
      nil ->
        {:allow, false, graph}

      record ->
        unlocks_at = record.joined_at + graph.config.group_lurk_period_ms

        if now_ms < unlocks_at do
          minutes_left = ceil((unlocks_at - now_ms) / @milliseconds_per_minute)
          {:deny, "Group lurk period not elapsed — wait #{minutes_left} minutes", false, graph}
        else
          {:allow, false, graph}
        end
    end
  end

  defp check_contact(graph, jid, now_ms) do
    case Map.get(graph.contacts, jid, %{state: :stranger}) do
      %{state: :stranger} ->
        check_stranger(graph)

      %{state: :handshake_sent, handshake_sent_at: sent_at} ->
        elapsed = now_ms - sent_at

        if elapsed < graph.config.handshake_min_delay_ms do
          minutes_left =
            ceil((graph.config.handshake_min_delay_ms - elapsed) / @milliseconds_per_minute)

          {:deny, "Handshake too recent — wait #{minutes_left} minutes", false, graph}
        else
          {:allow, false, graph}
        end

      %{state: :handshake_sent} ->
        {:allow, false, graph}

      _known ->
        {:allow, false, graph}
    end
  end

  defp check_stranger(%{config: %{require_handshake_before_group_send: false}} = graph),
    do: {:allow, true, graph}

  defp check_stranger(graph) do
    if graph.stranger_messages_today >= graph.config.max_stranger_messages_per_day do
      {:deny, "Daily new-contact limit reached (#{graph.config.max_stranger_messages_per_day})",
       true, graph}
    else
      {:allow, true, %{graph | stranger_messages_today: graph.stranger_messages_today + 1}}
    end
  end

  defp put_contact_state(%__MODULE__{config: %{enabled: false}} = graph, _jid, _state), do: graph

  defp put_contact_state(graph, jid, state) do
    if Jid.group?(jid) do
      graph
    else
      record = Map.get(graph.contacts, jid, %{state: :stranger}) |> Map.put(:state, state)
      put_in(graph.contacts[jid], record)
    end
  end

  defp reset_day_if_needed(graph, now_ms) do
    current_day = day(now_ms)

    if current_day == graph.last_stranger_reset_day do
      graph
    else
      %{graph | stranger_messages_today: 0, last_stranger_reset_day: current_day}
    end
  end

  defp day(now_ms), do: floor(now_ms / @milliseconds_per_day)

  defp normalize_contacts(contacts) when is_map(contacts) do
    Map.new(contacts, fn {jid, record} ->
      normalized = %{state: normalize_contact_state(persisted_value(record, :state, :stranger))}

      normalized =
        case persisted_value(record, :handshake_sent_at) do
          value when is_integer(value) -> Map.put(normalized, :handshake_sent_at, value)
          _missing -> normalized
        end

      {to_string(jid), normalized}
    end)
  end

  defp normalize_contacts(_invalid), do: %{}

  defp normalize_groups(groups) when is_map(groups) do
    Map.new(groups, fn {jid, record} ->
      {to_string(jid), %{joined_at: persisted_value(record, :joined_at)}}
    end)
  end

  defp normalize_groups(_invalid), do: %{}

  defp normalize_contact_state(:stranger), do: :stranger
  defp normalize_contact_state(:handshake_sent), do: :handshake_sent
  defp normalize_contact_state(:handshake_complete), do: :handshake_complete
  defp normalize_contact_state(:known), do: :known
  defp normalize_contact_state("stranger"), do: :stranger
  defp normalize_contact_state("handshake_sent"), do: :handshake_sent
  defp normalize_contact_state("handshake_complete"), do: :handshake_complete
  defp normalize_contact_state("known"), do: :known
  defp normalize_contact_state(_invalid), do: :stranger

  defp persisted_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
