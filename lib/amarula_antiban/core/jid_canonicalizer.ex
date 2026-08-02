defmodule AmarulaAntiban.Core.JidCanonicalizer do
  @moduledoc """
  Produces stable storage keys for WhatsApp JIDs and tracks antiban statistics.

  Identity resolution is deliberately not implemented here. For an `@lid`
  JID, callers may pass the PN JID returned by Amarula's LID/PN lookup. This
  keeps Amarula as the sole source of identity truth while preserving the
  useful `canonicalKey` behavior from baileys-antiban.
  """

  defmodule Stats do
    @moduledoc "Canonical-key hit and LID-miss counters."

    @type t :: %__MODULE__{
            canonical_key_hits: non_neg_integer(),
            canonical_key_misses: non_neg_integer()
          }

    defstruct canonical_key_hits: 0, canonical_key_misses: 0
  end

  @type t :: %__MODULE__{stats: Stats.t()}
  defstruct stats: nil

  @doc "Builds an empty canonicalizer statistics state."
  @spec new() :: t()
  def new, do: %__MODULE__{stats: struct(Stats)}

  @doc """
  Returns a stable `thread:*` key and the updated statistics state.

  `resolved_pn` must come from Amarula (for example `Amarula.Contacts.pn_for_lid/2`).
  It is only consulted for `@lid` input; no mapping is retained locally.
  """
  @spec canonical_key(t(), term(), String.t() | nil) :: {String.t(), t()}
  def canonical_key(canonicalizer, jid, resolved_pn \\ nil)

  def canonical_key(%__MODULE__{} = canonicalizer, jid, resolved_pn) when is_binary(jid) do
    normalized = jid |> String.trim() |> String.downcase()

    case String.split(normalized, "@", parts: 2) do
      ["", _domain] -> {"thread:invalid", canonicalizer}
      [_without_domain] -> {"thread:invalid", canonicalizer}
      [user, "g.us"] -> {"thread:group:#{user}", canonicalizer}
      [user, "broadcast"] -> {"thread:broadcast:#{user}", canonicalizer}
      [user, "newsletter"] -> {"thread:newsletter:#{user}", canonicalizer}
      [user, "s.whatsapp.net"] -> hit(canonicalizer, "thread:#{user}")
      [user, "lid"] -> canonical_lid_key(canonicalizer, user, resolved_pn)
      [user, domain] -> {"thread:#{domain}:#{user}", canonicalizer}
    end
  end

  def canonical_key(%__MODULE__{} = canonicalizer, _jid, _resolved_pn),
    do: {"thread:invalid", canonicalizer}

  @doc "Returns the current immutable statistics snapshot."
  @spec stats(t()) :: Stats.t()
  def stats(%__MODULE__{stats: stats}), do: stats

  @doc "Resets canonical-key counters."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = canonicalizer), do: %{canonicalizer | stats: struct(Stats)}

  defp canonical_lid_key(canonicalizer, lid_user, resolved_pn) do
    case pn_user(resolved_pn) do
      {:ok, user} -> hit(canonicalizer, "thread:#{user}")
      :error -> miss(canonicalizer, "thread:lid:#{lid_user}")
    end
  end

  defp pn_user(pn) when is_binary(pn) do
    normalized = pn |> String.trim() |> String.downcase()

    case String.split(normalized, "@", parts: 2) do
      [user, "s.whatsapp.net"] when user != "" -> {:ok, user}
      _other -> :error
    end
  end

  defp pn_user(_pn), do: :error

  defp hit(canonicalizer, key) do
    stats = canonicalizer.stats
    {key, %{canonicalizer | stats: %{stats | canonical_key_hits: stats.canonical_key_hits + 1}}}
  end

  defp miss(canonicalizer, key) do
    stats = canonicalizer.stats

    {key,
     %{canonicalizer | stats: %{stats | canonical_key_misses: stats.canonical_key_misses + 1}}}
  end
end
