defmodule AmarulaAntiban.Core.HumanEntropy do
  @moduledoc """
  Pure, RNG-injected decision core for background humanization cycles.

  Scope reduced to `performTypingPresence` (type, then stop) and
  `performPresenceToggle` (briefly go unavailable, then available again) —
  the two upstream actions whose Amarula calls are already confirmed
  elsewhere in this port (`Amarula.send_chatstate/3`, `Amarula.set_presence/2`,
  both already used by `Plugin`). `performReadReceipt` is out of scope: it
  needs a real message ID, and `Session.record_incoming/2,3` currently
  discards the plugin ctx's `id` — that requires its own follow-up pass.

  This module only *decides*; it never sleeps, sends, or reads a clock.
  `AmarulaAntiban.HumanEntropyWorker` is the impure shell: a per-session
  background process (the only part of this port running outside the send
  flow) that fetches a snapshot of this state from `Session`, calls
  `roll_cycle/1`, executes the resulting actions against Amarula, and reports
  back via `record_cycle/2` for accounting.
  """

  defmodule Config do
    @moduledoc "Cycle interval bounds, action probabilities, and durations."

    @type t :: %__MODULE__{
            enabled: boolean(),
            min_interval_ms: pos_integer(),
            max_interval_ms: pos_integer(),
            max_recent_contacts: pos_integer(),
            typing_probability: float(),
            typing_min_ms: pos_integer(),
            typing_max_ms: pos_integer(),
            presence_toggle_probability: float(),
            presence_toggle_min_ms: pos_integer(),
            presence_toggle_max_ms: pos_integer(),
            rand_fun: (-> float())
          }

    defstruct enabled: false,
              min_interval_ms: 7_200_000,
              max_interval_ms: 21_600_000,
              max_recent_contacts: 30,
              typing_probability: 0.3,
              typing_min_ms: 3_000,
              typing_max_ms: 8_000,
              presence_toggle_probability: 0.15,
              presence_toggle_min_ms: 30_000,
              presence_toggle_max_ms: 120_000,
              rand_fun: &:rand.uniform_real/0
  end

  @type contact :: %{jid: String.t(), last_message_at: integer()}
  @type action :: {:typing, String.t(), pos_integer()} | {:presence_toggle, pos_integer()}
  @type stats :: %{
          cycles_run: non_neg_integer(),
          typing_events: non_neg_integer(),
          presence_toggles: non_neg_integer()
        }
  @type t :: %__MODULE__{config: Config.t(), recent_contacts: [contact()], stats: stats()}

  defstruct config: nil,
            recent_contacts: [],
            stats: %{cycles_run: 0, typing_events: 0, presence_toggles: 0}

  @doc "Builds a fresh decision core from keyword options or a map."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []), do: %__MODULE__{config: struct!(Config, Map.new(options))}

  @doc """
  Records an inbound message from `jid`, deduping by JID and keeping only the
  `max_recent_contacts` most recently active contacts.
  """
  @spec track_incoming(t(), String.t(), integer()) :: t()
  def track_incoming(entropy, jid, now_ms) do
    contacts =
      entropy.recent_contacts
      |> Enum.reject(&(&1.jid == jid))
      |> then(&[%{jid: jid, last_message_at: now_ms} | &1])
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
  Independently rolls each action for one cycle (both, either, or neither may
  fire — this isn't an exclusive choice). Never mutates `entropy`; the caller
  reports the outcome back through `record_cycle/2`.
  """
  @spec roll_cycle(t()) :: [action()]
  def roll_cycle(%__MODULE__{config: %{enabled: false}}), do: []

  def roll_cycle(entropy) do
    [typing_action(entropy), presence_toggle_action(entropy)]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Records the actions a cycle executed for accounting."
  @spec record_cycle(t(), [action()]) :: t()
  def record_cycle(entropy, actions) do
    stats = %{
      entropy.stats
      | cycles_run: entropy.stats.cycles_run + 1,
        typing_events: entropy.stats.typing_events + count_kind(actions, :typing),
        presence_toggles: entropy.stats.presence_toggles + count_kind(actions, :presence_toggle)
    }

    %{entropy | stats: stats}
  end

  @doc "Returns cycle/action counters."
  @spec stats(t()) :: stats()
  def stats(entropy), do: entropy.stats

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

  defp count_kind(actions, kind), do: Enum.count(actions, &(elem(&1, 0) == kind))

  defp uniform(rand_fun, min, max), do: min + floor(sample(rand_fun) * (max - min + 1))

  defp sample(rand_fun), do: rand_fun.() |> max(0.0) |> min(1.0 - 1.0e-12)
end
