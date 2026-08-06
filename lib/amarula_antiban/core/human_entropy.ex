defmodule AmarulaAntiban.Core.HumanEntropy do
  @moduledoc """
  Pure, RNG-injected decision core for background humanization cycles.

  Three actions, matching upstream's `performTypingPresence` (type, then
  stop), `performPresenceToggle` (briefly go unavailable, then available
  again), and `performReadReceipt` (mark accumulated unread messages from one
  contact read, after a `Core.ReadReceiptVariance` delay). Read-receipt
  tracking piggybacks on the same `recent_contacts` list `:typing` already
  uses to pick a target — every contact tracked via `track_incoming/4` also
  carries the message IDs still owed a read receipt.

  This module only *decides*; it never sleeps, sends, or reads a clock (the
  one exception is `roll_cycle/2`'s `now_ms`, needed only to check whether a
  contact's backlog is old enough to skip the artificial delay).
  `AmarulaAntiban.HumanEntropyWorker` is the impure shell: a per-session
  background process (the only part of this port running outside the send
  flow) that fetches a snapshot of this state from `Session`, calls
  `roll_cycle/2`, executes the resulting actions against Amarula, and reports
  back via `record_cycle/2` for accounting.
  """

  alias AmarulaAntiban.Core.ReadReceiptVariance

  defmodule Config do
    @moduledoc "Cycle interval bounds, action probabilities, and durations."

    @type t :: %__MODULE__{
            enabled: boolean(),
            min_interval_ms: pos_integer(),
            max_interval_ms: pos_integer(),
            max_recent_contacts: pos_integer(),
            max_pending_reads_per_contact: pos_integer(),
            typing_probability: float(),
            typing_min_ms: pos_integer(),
            typing_max_ms: pos_integer(),
            presence_toggle_probability: float(),
            presence_toggle_min_ms: pos_integer(),
            presence_toggle_max_ms: pos_integer(),
            read_receipt_probability: float(),
            rand_fun: (-> float())
          }

    defstruct enabled: false,
              min_interval_ms: 7_200_000,
              max_interval_ms: 21_600_000,
              max_recent_contacts: 30,
              max_pending_reads_per_contact: 20,
              typing_probability: 0.3,
              typing_min_ms: 3_000,
              typing_max_ms: 8_000,
              presence_toggle_probability: 0.15,
              presence_toggle_min_ms: 30_000,
              presence_toggle_max_ms: 120_000,
              read_receipt_probability: 0.5,
              rand_fun: &:rand.uniform_real/0
  end

  @type contact :: %{
          jid: String.t(),
          last_message_at: integer(),
          pending_message_ids: [String.t()]
        }
  @type action ::
          {:typing, String.t(), pos_integer()}
          | {:presence_toggle, pos_integer()}
          | {:read_receipt, String.t(), [String.t()], non_neg_integer()}
  @type stats :: %{
          cycles_run: non_neg_integer(),
          typing_events: non_neg_integer(),
          presence_toggles: non_neg_integer(),
          read_receipts_sent: non_neg_integer()
        }
  @type t :: %__MODULE__{
          config: Config.t(),
          recent_contacts: [contact()],
          read_receipt_variance: ReadReceiptVariance.t(),
          stats: stats()
        }

  defstruct config: nil,
            recent_contacts: [],
            read_receipt_variance: nil,
            stats: %{cycles_run: 0, typing_events: 0, presence_toggles: 0, read_receipts_sent: 0}

  @doc """
  Builds a fresh decision core. `read_receipt_options` configures the nested
  `Core.ReadReceiptVariance` used to delay `:read_receipt` actions.
  """
  @spec new(keyword() | map(), keyword() | map()) :: t()
  def new(options \\ [], read_receipt_options \\ []) do
    %__MODULE__{
      config: struct!(Config, Map.new(options)),
      read_receipt_variance: ReadReceiptVariance.new(read_receipt_options)
    }
  end

  @doc """
  Records an inbound message from `jid`, deduping contacts by JID, keeping
  only the `max_recent_contacts` most recently active, and — when
  `message_id` is given — queuing it as owed a read receipt (capped at
  `max_pending_reads_per_contact`, oldest dropped first).
  """
  @spec track_incoming(t(), String.t(), String.t() | nil, integer()) :: t()
  def track_incoming(entropy, jid, message_id, now_ms) do
    pending = pending_for(entropy, jid, message_id)
    contact = %{jid: jid, last_message_at: now_ms, pending_message_ids: pending}

    contacts =
      entropy.recent_contacts
      |> Enum.reject(&(&1.jid == jid))
      |> then(&[contact | &1])
      |> Enum.take(entropy.config.max_recent_contacts)

    %{entropy | recent_contacts: contacts}
  end

  @doc "Returns a uniform random delay (ms) until the next cycle should run."
  @spec next_delay_ms(t()) :: pos_integer()
  def next_delay_ms(entropy) do
    config = entropy.config
    uniform(config.rand_fun, config.min_interval_ms, config.max_interval_ms)
  end

  @doc """
  Independently rolls each action for one cycle (any subset, including none
  or all three, may fire — this isn't an exclusive choice). Never mutates
  `entropy`; the caller reports the outcome back through `record_cycle/2`.
  """
  @spec roll_cycle(t(), integer()) :: [action()]
  def roll_cycle(%__MODULE__{config: %{enabled: false}}, _now_ms), do: []

  def roll_cycle(entropy, now_ms) do
    [
      typing_action(entropy),
      presence_toggle_action(entropy),
      read_receipt_action(entropy, now_ms)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Records the actions a cycle executed for accounting and clears read contacts' backlog."
  @spec record_cycle(t(), [action()]) :: t()
  def record_cycle(entropy, actions) do
    entropy = Enum.reduce(actions, entropy, &clear_read_backlog/2)

    stats = %{
      entropy.stats
      | cycles_run: entropy.stats.cycles_run + 1,
        typing_events: entropy.stats.typing_events + count_kind(actions, :typing),
        presence_toggles: entropy.stats.presence_toggles + count_kind(actions, :presence_toggle),
        read_receipts_sent: entropy.stats.read_receipts_sent + count_kind(actions, :read_receipt)
    }

    %{entropy | stats: stats}
  end

  @doc "Returns cycle/action counters."
  @spec stats(t()) :: stats()
  def stats(entropy), do: entropy.stats

  @doc """
  Exports persistable state for `Snapshot`: `recent_contacts` and `stats`.

  Unlike most core modules, `human_entropy` can't use the generic
  `mutable_data`/`restore_struct` snapshot helpers — `read_receipt_variance`
  is a nested struct carrying its own `config.rand_fun` closure two levels
  deep, which those helpers only strip at the top level.
  """
  @spec export(t()) :: map()
  def export(entropy), do: %{recent_contacts: entropy.recent_contacts, stats: entropy.stats}

  @doc "Restores `recent_contacts` and `stats` while retaining configuration."
  @spec restore(t(), map()) :: t()
  def restore(entropy, state) when is_map(state) do
    %{
      entropy
      | recent_contacts: state |> persisted_value(:recent_contacts, []) |> normalize_contacts(),
        stats: restore_stats(entropy.stats, persisted_value(state, :stats, %{}))
    }
  end

  defp normalize_contacts(contacts) when is_list(contacts) do
    Enum.map(contacts, fn contact ->
      %{
        jid: persisted_value(contact, :jid, ""),
        last_message_at: persisted_value(contact, :last_message_at, 0),
        pending_message_ids:
          contact |> persisted_value(:pending_message_ids, []) |> normalize_ids()
      }
    end)
  end

  defp normalize_contacts(_invalid), do: []

  defp normalize_ids(ids) when is_list(ids), do: Enum.filter(ids, &is_binary/1)
  defp normalize_ids(_invalid), do: []

  defp restore_stats(fresh_stats, data) do
    Map.new(fresh_stats, fn {key, default} ->
      value =
        case persisted_value(data, key, default) do
          value when is_integer(value) and value >= 0 -> value
          _invalid -> default
        end

      {key, value}
    end)
  end

  defp persisted_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp pending_for(entropy, jid, message_id) do
    existing = Enum.find(entropy.recent_contacts, &(&1.jid == jid))
    pending = if existing, do: existing.pending_message_ids, else: []

    if message_id do
      [message_id | pending]
      |> Enum.uniq()
      |> Enum.take(entropy.config.max_pending_reads_per_contact)
    else
      pending
    end
  end

  defp typing_action(%{recent_contacts: []}), do: nil

  defp typing_action(entropy) do
    config = entropy.config

    if sample(config.rand_fun) < config.typing_probability do
      contact =
        Enum.at(
          entropy.recent_contacts,
          floor(sample(config.rand_fun) * length(entropy.recent_contacts))
        )

      {:typing, contact.jid, uniform(config.rand_fun, config.typing_min_ms, config.typing_max_ms)}
    end
  end

  defp presence_toggle_action(entropy) do
    config = entropy.config

    if sample(config.rand_fun) < config.presence_toggle_probability do
      {:presence_toggle,
       uniform(config.rand_fun, config.presence_toggle_min_ms, config.presence_toggle_max_ms)}
    end
  end

  defp read_receipt_action(entropy, now_ms) do
    config = entropy.config
    candidates = Enum.filter(entropy.recent_contacts, &(&1.pending_message_ids != []))

    if candidates != [] and sample(config.rand_fun) < config.read_receipt_probability do
      contact = Enum.at(candidates, floor(sample(config.rand_fun) * length(candidates)))
      delay_ms = read_receipt_delay_ms(entropy.read_receipt_variance, contact, now_ms)
      {:read_receipt, contact.jid, contact.pending_message_ids, delay_ms}
    end
  end

  defp read_receipt_delay_ms(variance, contact, now_ms) do
    backlog_key = [%{message_timestamp: div(contact.last_message_at, 1_000)}]

    if ReadReceiptVariance.backlog?(backlog_key, variance, now_ms) do
      0
    else
      ReadReceiptVariance.delay_ms(variance)
    end
  end

  defp clear_read_backlog({:read_receipt, jid, _ids, _delay}, entropy) do
    contacts =
      Enum.map(entropy.recent_contacts, fn
        %{jid: ^jid} = contact -> %{contact | pending_message_ids: []}
        contact -> contact
      end)

    %{entropy | recent_contacts: contacts}
  end

  defp clear_read_backlog(_action, entropy), do: entropy

  defp count_kind(actions, kind), do: Enum.count(actions, &(elem(&1, 0) == kind))

  defp uniform(rand_fun, min, max), do: min + floor(sample(rand_fun) * (max - min + 1))

  defp sample(rand_fun), do: rand_fun.() |> max(0.0) |> min(1.0 - 1.0e-12)
end
