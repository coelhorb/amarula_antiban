defmodule AmarulaAntiban.Core.ReplyRatio do
  @moduledoc """
  Pure per-contact inbound/outbound ratio guard.

  Time and randomness are explicit so cooldowns and reply suggestions remain
  deterministic. The guard is opt-in, matching the upstream default.
  """

  alias AmarulaAntiban.Jid

  @milliseconds_per_hour 3_600_000

  defmodule Config do
    @moduledoc "Reply-ratio thresholds and injected random source."

    @type t :: %__MODULE__{
            enabled: boolean(),
            min_ratio: number(),
            min_messages_before_enforce: non_neg_integer(),
            inbound_auto_reply_probability: number(),
            auto_reply_templates: [String.t()],
            cooldown_hours_on_violation: non_neg_integer(),
            scope: :individual | :all,
            rand_fun: (-> float())
          }

    defstruct enabled: false,
              min_ratio: 0.10,
              min_messages_before_enforce: 5,
              inbound_auto_reply_probability: 0.25,
              auto_reply_templates: ["👍", "👌", "ok", "noted", "thanks", "🙏", "got it"],
              cooldown_hours_on_violation: 24,
              scope: :individual,
              rand_fun: &:rand.uniform_real/0
  end

  defmodule Stats do
    @moduledoc "Per-contact and aggregate reply-ratio statistics."
    defstruct per_contact: [],
              global_sent: 0,
              global_received: 0,
              global_ratio: 0.0,
              contacts_on_cooldown: 0

    @type t :: %__MODULE__{
            per_contact: [map()],
            global_sent: non_neg_integer(),
            global_received: non_neg_integer(),
            global_ratio: float(),
            contacts_on_cooldown: non_neg_integer()
          }
  end

  @type contact_record :: %{
          required(:sent) => non_neg_integer(),
          required(:received) => non_neg_integer(),
          optional(:cooled_until) => integer()
        }
  @type t :: %__MODULE__{config: Config.t(), contacts: %{String.t() => contact_record()}}

  defstruct config: nil, contacts: %{}

  @doc "Builds a reply-ratio guard from keyword options or a map."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []), do: %__MODULE__{config: struct!(Config, Map.new(options))}

  @doc "Checks whether a send is allowed and starts a cooldown on a new violation."
  @spec before_send(t(), String.t(), integer()) ::
          {:allow, t()} | {:deny, String.t(), t()}
  def before_send(%__MODULE__{config: %{enabled: false}} = ratio, _jid, _now_ms),
    do: {:allow, ratio}

  def before_send(%__MODULE__{config: %{scope: :individual}} = ratio, jid, now_ms)
      when is_binary(jid) do
    if Jid.group?(jid), do: {:allow, ratio}, else: check_contact(ratio, jid, now_ms)
  end

  def before_send(ratio, jid, now_ms), do: check_contact(ratio, jid, now_ms)

  @doc "Records one outbound message when enforcement is enabled."
  @spec record_sent(t(), String.t()) :: t()
  def record_sent(%__MODULE__{config: %{enabled: false}} = ratio, _jid), do: ratio

  def record_sent(ratio, jid) do
    update_contact(ratio, jid, fn record -> %{record | sent: record.sent + 1} end)
  end

  @doc "Records an inbound message and clears that contact's cooldown."
  @spec record_received(t(), String.t()) :: t()
  def record_received(%__MODULE__{config: %{enabled: false}} = ratio, _jid), do: ratio

  def record_received(ratio, jid) do
    update_contact(ratio, jid, fn record ->
      record |> Map.delete(:cooled_until) |> Map.update!(:received, &(&1 + 1))
    end)
  end

  @doc "Returns an optional auto-reply suggestion using the injected RNG."
  @spec suggest_reply(t(), String.t()) :: {:none, t()} | {{:reply, String.t()}, t()}
  def suggest_reply(%__MODULE__{config: %{enabled: false}} = ratio, _jid), do: {:none, ratio}

  def suggest_reply(%__MODULE__{config: %{scope: :individual}} = ratio, jid) do
    if Jid.group?(jid), do: {:none, ratio}, else: roll_reply(ratio)
  end

  def suggest_reply(ratio, _jid), do: roll_reply(ratio)

  @doc "Returns aggregate statistics at the injected time."
  @spec stats(t(), integer()) :: Stats.t()
  def stats(ratio, now_ms) do
    per_contact =
      Enum.map(ratio.contacts, fn {jid, record} ->
        Map.merge(record, %{
          jid: jid,
          ratio: if(record.sent == 0, do: 0.0, else: record.received / record.sent)
        })
      end)

    global_sent = Enum.sum(Enum.map(per_contact, & &1.sent))
    global_received = Enum.sum(Enum.map(per_contact, & &1.received))

    %Stats{
      per_contact: per_contact,
      global_sent: global_sent,
      global_received: global_received,
      global_ratio: if(global_sent == 0, do: 0.0, else: global_received / global_sent),
      contacts_on_cooldown: Enum.count(per_contact, &(Map.get(&1, :cooled_until, 0) > now_ms))
    }
  end

  @doc "Clears all contact counters."
  @spec reset(t()) :: t()
  def reset(ratio), do: %{ratio | contacts: %{}}

  @doc "Exports the persistence-safe contact map."
  @spec export(t()) :: map()
  def export(ratio), do: %{contacts: ratio.contacts}

  @doc "Restores contact counters from a map while retaining configuration."
  @spec restore(t(), map()) :: t()
  def restore(ratio, state) when is_map(state) do
    case persisted_value(state, :contacts) do
      contacts when is_map(contacts) -> %{ratio | contacts: normalize_contacts(contacts)}
      _invalid -> ratio
    end
  end

  defp check_contact(ratio, jid, now_ms) do
    case Map.get(ratio.contacts, jid) do
      nil ->
        {:allow, ratio}

      %{cooled_until: cooled_until} = record when now_ms < cooled_until ->
        hours_left = ceil((cooled_until - now_ms) / @milliseconds_per_hour)

        {:deny,
         "Reply ratio cooldown — #{record.sent} sent, #{record.received} received. Retry in #{hours_left}h",
         ratio}

      %{sent: sent} = record when sent >= ratio.config.min_messages_before_enforce ->
        current_ratio = if(sent == 0, do: 1.0, else: record.received / sent)

        if current_ratio < ratio.config.min_ratio do
          cooled_until =
            now_ms + ratio.config.cooldown_hours_on_violation * @milliseconds_per_hour

          ratio = put_in(ratio.contacts[jid], Map.put(record, :cooled_until, cooled_until))

          {:deny,
           "Reply ratio too low (#{percent(current_ratio)}% < #{percent(ratio.config.min_ratio)}%). Cooldown #{ratio.config.cooldown_hours_on_violation}h",
           ratio}
        else
          {:allow, ratio}
        end

      _record ->
        {:allow, ratio}
    end
  end

  defp roll_reply(ratio) do
    if sample(ratio.config.rand_fun) < ratio.config.inbound_auto_reply_probability and
         ratio.config.auto_reply_templates != [] do
      templates = ratio.config.auto_reply_templates
      index = floor(sample(ratio.config.rand_fun) * length(templates))
      {{:reply, Enum.at(templates, index)}, ratio}
    else
      {:none, ratio}
    end
  end

  defp update_contact(ratio, jid, fun) do
    record = Map.get(ratio.contacts, jid, %{sent: 0, received: 0})
    %{ratio | contacts: Map.put(ratio.contacts, jid, fun.(record))}
  end

  defp normalize_contacts(contacts) do
    Map.new(contacts, fn {jid, record} ->
      normalized = %{
        sent: persisted_value(record, :sent, 0),
        received: persisted_value(record, :received, 0)
      }

      normalized =
        case persisted_value(record, :cooled_until) do
          value when is_integer(value) -> Map.put(normalized, :cooled_until, value)
          _missing -> normalized
        end

      {to_string(jid), normalized}
    end)
  end

  defp persisted_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp sample(rand_fun), do: rand_fun.() |> max(0.0) |> min(1.0 - 1.0e-12)

  defp percent(value), do: :erlang.float_to_binary(value * 100.0, decimals: 1)
end
