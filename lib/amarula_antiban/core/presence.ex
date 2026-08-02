defmodule AmarulaAntiban.Core.Presence do
  @moduledoc """
  Pure presence and typing-plan choreographer.

  It computes steps for the OTP shell to execute; this module performs no
  sleeping, presence I/O, or implicit clock reads. IANA timezone conversion
  uses an explicit time-zone database and preserves daylight-saving changes;
  `utc_offset_minutes` remains available when no `timezone` is configured.
  """

  @type circadian_profile :: :default | :night_owl | :early_bird | :always_on
  @type activity_curve :: :office | :social | :global
  @type step ::
          {:typing, non_neg_integer()}
          | {:pause, non_neg_integer()}
          | {:available, non_neg_integer()}

  @curves %{
    office: [
      0.1,
      0.1,
      0.1,
      0.1,
      0.1,
      0.1,
      0.1,
      0.1,
      0.5,
      0.5,
      0.95,
      0.95,
      0.6,
      0.9,
      0.9,
      0.9,
      0.9,
      0.6,
      0.6,
      0.4,
      0.4,
      0.2,
      0.2,
      0.2
    ],
    social: [
      0.1,
      0.1,
      0.1,
      0.1,
      0.1,
      0.1,
      0.1,
      0.1,
      0.3,
      0.4,
      0.7,
      0.8,
      0.5,
      0.7,
      0.7,
      0.4,
      0.8,
      0.9,
      0.9,
      0.6,
      0.8,
      0.85,
      0.9,
      0.95
    ],
    global: [
      0.5,
      0.5,
      0.5,
      0.5,
      0.5,
      0.5,
      0.4,
      0.4,
      0.6,
      0.7,
      0.8,
      0.8,
      0.6,
      0.8,
      0.8,
      0.8,
      0.8,
      0.7,
      0.7,
      0.6,
      0.5,
      0.5,
      0.5,
      0.5
    ]
  }

  defmodule Config do
    @moduledoc "Presence probabilities, timing model, and injected RNG."

    defstruct enabled: false,
              enable_circadian_rhythm: true,
              activity_curve: :office,
              timezone: nil,
              time_zone_database: Zoneinfo.TimeZoneDatabase,
              utc_offset_minutes: 0,
              circadian_enabled: true,
              circadian_profile: :default,
              distraction_pause_probability: 0.05,
              distraction_pause_min_ms: 300_000,
              distraction_pause_max_ms: 1_200_000,
              read_receipt_delay_min_ms: 3_000,
              read_receipt_delay_max_ms: 45_000,
              read_receipt_skip_probability: 0.15,
              offline_gap_probability: 0.03,
              offline_gap_min_ms: 300_000,
              offline_gap_max_ms: 900_000,
              enable_typing_model: true,
              typing_wpm: 45,
              typing_wpm_std_dev: 15,
              think_pause_probability: 0.08,
              think_pause_min_ms: 800,
              think_pause_max_ms: 3_500,
              intermittent_paused_probability: 0.4,
              typing_max_ms: 90_000,
              typing_min_ms: 600,
              rand_fun: &:rand.uniform_real/0

    @type t :: %__MODULE__{}
  end

  defmodule Stats do
    @moduledoc "Presence-planning counters and current circadian context."
    defstruct current_activity_factor: 1.0,
              distraction_pauses_injected: 0,
              offline_gaps_injected: 0,
              read_receipts_delayed: 0,
              read_receipts_skipped: 0,
              current_hour_local: 0,
              typing_plans_computed: 0,
              typing_plans_executed: 0,
              total_typing_time_ms: 0

    @type t :: %__MODULE__{}
  end

  @type t :: %__MODULE__{config: Config.t(), counters: map()}
  defstruct config: nil, counters: nil

  @doc "Builds a choreographer from keyword options or a map."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []) do
    %__MODULE__{config: struct!(Config, Map.new(options)), counters: struct!(Stats, %{})}
  end

  @doc "Returns the upstream activity-curve factor for the local hour at `now_ms`."
  @spec activity_factor(t(), integer()) :: float()
  def activity_factor(%__MODULE__{config: config}, now_ms) do
    if config.enabled and config.enable_circadian_rhythm do
      config.activity_curve
      |> then(&Map.fetch!(@curves, &1))
      |> Enum.at(local_hour(config, now_ms), 0.5)
    else
      1.0
    end
  end

  @doc "Computes the exact piecewise circadian delay multiplier for an hour."
  @spec circadian_multiplier(0..23, circadian_profile()) :: float()
  def circadian_multiplier(_hour, :always_on), do: 1.0

  def circadian_multiplier(hour, profile) when hour in 0..23 do
    hour |> shift_hour(profile) |> multiplier_for_hour()
  end

  @doc "Rolls a distraction pause and updates its counter."
  @spec distraction_pause(t()) :: {{:pause, non_neg_integer()} | :none, t()}
  def distraction_pause(%__MODULE__{config: %{enabled: false}} = presence),
    do: {:none, presence}

  def distraction_pause(presence) do
    if random(presence) < presence.config.distraction_pause_probability do
      duration =
        random_between(
          presence,
          presence.config.distraction_pause_min_ms,
          presence.config.distraction_pause_max_ms
        )

      {{:pause, duration}, increment(presence, :distraction_pauses_injected)}
    else
      {:none, presence}
    end
  end

  @doc "Rolls an offline/available gap and updates its counter."
  @spec offline_gap(t()) :: {{:available, non_neg_integer()} | :none, t()}
  def offline_gap(%__MODULE__{config: %{enabled: false}} = presence), do: {:none, presence}

  def offline_gap(presence) do
    if random(presence) < presence.config.offline_gap_probability do
      duration =
        random_between(
          presence,
          presence.config.offline_gap_min_ms,
          presence.config.offline_gap_max_ms
        )

      {{:available, duration}, increment(presence, :offline_gaps_injected)}
    else
      {:none, presence}
    end
  end

  @doc "Plans whether and when to send a read receipt."
  @spec read_receipt(t(), integer()) :: {{:mark, non_neg_integer()} | :skip, t()}
  def read_receipt(%__MODULE__{config: %{enabled: false}} = presence, _now_ms),
    do: {{:mark, 0}, presence}

  def read_receipt(presence, now_ms) do
    if random(presence) < presence.config.read_receipt_skip_probability do
      {:skip, increment(presence, :read_receipts_skipped)}
    else
      base =
        random_between(
          presence,
          presence.config.read_receipt_delay_min_ms,
          presence.config.read_receipt_delay_max_ms
        )

      delay = floor(base * current_circadian_multiplier(presence, now_ms))
      {{:mark, delay}, increment(presence, :read_receipts_delayed)}
    end
  end

  @doc "Computes a WPM-based typing plan for text at `now_ms`."
  @spec plan(t(), String.t(), integer()) :: {[step()], t()}
  def plan(%__MODULE__{config: config} = presence, _text, _now_ms)
      when not config.enabled or not config.enable_typing_model do
    {[{:typing, config.typing_min_ms}], presence}
  end

  def plan(presence, text, now_ms) do
    presence = increment(presence, :typing_plans_computed)
    length = utf16_length(text)

    if length == 0 do
      {[{:typing, presence.config.typing_min_ms}], presence}
    else
      multiplier = current_circadian_multiplier(presence, now_ms)

      wpm =
        gaussian(presence, presence.config.typing_wpm, presence.config.typing_wpm_std_dev)
        |> clamp(10, 120)

      cps = wpm * 5 / 60

      target_ms =
        (length / cps * 1_000 * multiplier)
        |> clamp(presence.config.typing_min_ms, presence.config.typing_max_ms)

      steps = build_typing_steps(presence, length, target_ms, multiplier)
      {ensure_typing_step(steps, presence.config.typing_min_ms), presence}
    end
  end

  @doc "Accounts for a plan after the shell has executed it."
  @spec record_executed(t(), [step()]) :: t()
  def record_executed(presence, steps) do
    total = Enum.sum(Enum.map(steps, fn {_kind, duration} -> duration end))

    presence
    |> increment(:typing_plans_executed)
    |> update_counter(:total_typing_time_ms, &(&1 + total))
  end

  @doc "Returns current counters plus clock-derived activity fields."
  @spec stats(t(), integer()) :: Stats.t()
  def stats(%__MODULE__{counters: %Stats{} = counters} = presence, now_ms) do
    %Stats{
      counters
      | current_activity_factor: activity_factor(presence, now_ms),
        current_hour_local: local_hour(presence.config, now_ms)
    }
  end

  @doc "Clears all counters while retaining configuration."
  @spec reset_stats(t()) :: t()
  def reset_stats(presence), do: %{presence | counters: struct!(Stats, %{})}

  defp build_typing_steps(presence, message_length, target_ms, multiplier) do
    chunks = max(1, ceil(message_length / 10))
    steps = build_chunks(presence, message_length, multiplier, 0, chunks, target_ms, 0, [])

    maybe_final_pause(presence, steps, multiplier)
  end

  defp build_chunks(_presence, _length, _multiplier, index, chunks, _remaining, _position, steps)
       when index >= chunks,
       do: steps

  defp build_chunks(_presence, _length, _multiplier, _index, _chunks, remaining, _position, steps)
       when remaining <= 0,
       do: steps

  defp build_chunks(presence, length, multiplier, index, chunks, remaining, position, steps) do
    chunk_ms = floor(min(remaining / (chunks - index), remaining))

    if chunk_ms <= 0 do
      steps
    else
      inject_pause =
        index > 0 and index < chunks - 1 and
          random(presence) < presence.config.think_pause_probability

      steps = add_chunk_steps(presence, steps, chunk_ms, inject_pause, multiplier)
      chars = min(10, length - position)

      build_chunks(
        presence,
        length,
        multiplier,
        index + 1,
        chunks,
        remaining - chunk_ms,
        position + chars,
        steps
      )
    end
  end

  defp add_chunk_steps(presence, steps, chunk_ms, true, multiplier) do
    pause =
      random_between(
        presence,
        presence.config.think_pause_min_ms,
        presence.config.think_pause_max_ms
      )

    append_typing(steps, chunk_ms, true) ++ [{:pause, floor(pause * multiplier)}]
  end

  defp add_chunk_steps(_presence, steps, chunk_ms, false, _multiplier) do
    append_typing(steps, chunk_ms, false)
  end

  defp maybe_final_pause(presence, steps, multiplier) do
    if random(presence) < presence.config.intermittent_paused_probability do
      final_pause = random_between(presence, 200, 800)
      steps ++ [{:pause, floor(final_pause * multiplier)}]
    else
      steps
    end
  end

  defp append_typing(steps, duration, true), do: steps ++ [{:typing, duration}]

  defp append_typing(steps, duration, false) do
    case List.last(steps) do
      {:typing, _current} ->
        List.update_at(steps, -1, fn {:typing, current} -> {:typing, current + duration} end)

      _empty_or_paused ->
        steps ++ [{:typing, duration}]
    end
  end

  defp ensure_typing_step(steps, minimum) do
    if Enum.any?(steps, fn {kind, _duration} -> kind == :typing end),
      do: steps,
      else: [{:typing, minimum}]
  end

  defp current_circadian_multiplier(presence, now_ms) do
    if presence.config.circadian_enabled do
      circadian_multiplier(local_hour(presence.config, now_ms), presence.config.circadian_profile)
    else
      1.0
    end
  end

  defp shift_hour(hour, :night_owl), do: Integer.mod(hour - 3, 24)
  defp shift_hour(hour, :early_bird), do: Integer.mod(hour + 2, 24)
  defp shift_hour(hour, :default), do: hour

  defp multiplier_for_hour(hour) when hour >= 9 and hour < 22 do
    t = (hour - 9) / 13
    1.0 + 0.2 * :math.cos(2 * :math.pi() * t)
  end

  defp multiplier_for_hour(hour) when hour >= 22, do: 1.2 + 1.3 * ((hour - 22) / 2)
  defp multiplier_for_hour(hour) when hour < 2, do: 2.5 + 1.5 * (hour / 2)

  defp multiplier_for_hour(hour) when hour < 6 do
    5.0 + :math.cos(:math.pi() * ((hour - 2) / 4))
  end

  defp multiplier_for_hour(hour), do: 4.0 - 3.0 * ((hour - 6) / 3)

  defp local_hour(%{timezone: timezone} = config, now_ms) when is_binary(timezone) do
    now_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.shift_zone(timezone, config.time_zone_database)
    |> case do
      {:ok, datetime} ->
        datetime.hour

      {:error, reason} ->
        raise ArgumentError, "invalid IANA timezone #{inspect(timezone)}: #{inspect(reason)}"
    end
  end

  defp local_hour(config, now_ms) do
    shifted = now_ms + config.utc_offset_minutes * 60_000
    shifted |> div(3_600_000) |> Integer.mod(24)
  end

  defp gaussian(presence, mean, std_dev) do
    u1 = max(random(presence), 1.0e-12)
    u2 = random(presence)
    z0 = :math.sqrt(-2 * :math.log(u1)) * :math.cos(2 * :math.pi() * u2)
    mean + z0 * std_dev
  end

  defp random(presence) do
    presence.config.rand_fun.() |> max(0.0) |> min(1.0 - 1.0e-12)
  end

  defp random_between(presence, minimum, maximum) do
    floor(random(presence) * (maximum - minimum + 1)) + minimum
  end

  defp increment(presence, field), do: update_counter(presence, field, &(&1 + 1))

  defp update_counter(presence, field, fun) do
    %{presence | counters: Map.update!(presence.counters, field, fun)}
  end

  defp clamp(value, minimum, maximum), do: max(minimum, min(maximum, value))

  defp utf16_length(text) do
    text |> :unicode.characters_to_binary(:utf8, {:utf16, :big}) |> byte_size() |> div(2)
  end
end
