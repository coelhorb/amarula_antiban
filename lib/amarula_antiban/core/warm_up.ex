defmodule AmarulaAntiban.Core.WarmUp do
  @moduledoc """
  Pure warm-up schedule for new or long-inactive accounts.

  The daily curve is `round(day1_limit * growth_factor ^ day_index)`, exactly
  matching baileys-antiban. Time and the default randomized growth factor are
  injected, keeping tests and restored sessions deterministic.
  """

  alias AmarulaAntiban.Presets

  @milliseconds_per_day 86_400_000
  @milliseconds_per_hour 3_600_000

  defmodule Config do
    @moduledoc "Warm-up curve, inactivity threshold, and random-number source."

    @type t :: %__MODULE__{
            warmup_days: pos_integer(),
            day1_limit: pos_integer(),
            growth_factor: number() | nil,
            inactivity_threshold_hours: pos_integer(),
            rand_fun: (-> float())
          }

    defstruct warmup_days: 7,
              day1_limit: 20,
              growth_factor: nil,
              inactivity_threshold_hours: 72,
              rand_fun: &:rand.uniform/0
  end

  defmodule Status do
    @moduledoc "Current warm-up phase and daily utilization."

    @type t :: %__MODULE__{
            phase: :warming | :graduated,
            day: pos_integer(),
            total_days: pos_integer(),
            today_limit: integer(),
            today_sent: non_neg_integer(),
            progress: 0..100
          }

    defstruct [:phase, :day, :total_days, :today_limit, :today_sent, :progress]
  end

  @type persisted_state :: %{
          required(:started_at) => integer(),
          required(:last_active_at) => integer(),
          required(:daily_counts) => [non_neg_integer()],
          required(:graduated) => boolean(),
          optional(:today_sent_count) => non_neg_integer(),
          optional(:today_date) => String.t()
        }
  @type t :: %__MODULE__{
          config: Config.t(),
          started_at: integer(),
          last_active_at: integer(),
          daily_counts: [non_neg_integer()],
          graduated: boolean()
        }

  defstruct config: nil,
            started_at: 0,
            last_active_at: 0,
            daily_counts: [],
            graduated: false

  @doc "Builds a fresh warm-up state at `now_ms`."
  @spec new(keyword() | map() | Presets.Config.t(), integer()) :: t()
  def new(options \\ [], now_ms) do
    config = build_config(options)
    fresh(config, now_ms)
  end

  @doc "Builds a warm-up state from persisted state and validates today's count."
  @spec restore(keyword() | map() | Presets.Config.t(), persisted_state(), integer()) :: t()
  def restore(options \\ [], persisted, now_ms) do
    config = build_config(options)

    warmup = %__MODULE__{
      config: config,
      started_at: Map.fetch!(persisted, :started_at),
      last_active_at: Map.fetch!(persisted, :last_active_at),
      daily_counts: Map.fetch!(persisted, :daily_counts),
      graduated: Map.fetch!(persisted, :graduated)
    }

    restore_today_count(warmup, persisted, now_ms)
  end

  @doc "Returns today's limit and updates graduation when the schedule is complete."
  @spec daily_limit(t(), integer()) :: {:infinity | pos_integer(), t()}
  def daily_limit(%__MODULE__{graduated: true} = warmup, _now_ms), do: {:infinity, warmup}

  def daily_limit(warmup, now_ms) do
    day = current_day(warmup, now_ms)

    if day >= warmup.config.warmup_days do
      {:infinity, %{warmup | graduated: true}}
    else
      limit = round(warmup.config.day1_limit * :math.pow(warmup.config.growth_factor, day))
      {limit, warmup}
    end
  end

  @doc "Checks the current day allowance after applying inactivity detection."
  @spec can_send(t(), integer()) :: {boolean(), t()}
  def can_send(warmup, now_ms) do
    warmup = check_inactivity(warmup, now_ms)

    if warmup.graduated do
      {true, warmup}
    else
      day = current_day(warmup, now_ms)
      today_count = Enum.at(warmup.daily_counts, day, 0)
      {limit, warmup} = daily_limit(warmup, now_ms)
      {limit == :infinity or today_count < limit, warmup}
    end
  end

  @doc "Records one sent message in the current warm-up day."
  @spec record(t(), integer()) :: t()
  def record(warmup, now_ms) do
    day = current_day(warmup, now_ms)
    counts = put_count(warmup.daily_counts, day, Enum.at(warmup.daily_counts, day, 0) + 1)
    %{warmup | daily_counts: counts, last_active_at: now_ms}
  end

  @doc "Returns the current warm-up status and any graduation state change."
  @spec status(t(), integer()) :: {Status.t(), t()}
  def status(warmup, now_ms) do
    day = current_day(warmup, now_ms)
    today_sent = Enum.at(warmup.daily_counts, day, 0)
    {limit, warmup} = daily_limit(warmup, now_ms)

    status = %Status{
      phase: if(warmup.graduated, do: :graduated, else: :warming),
      day: min(day + 1, warmup.config.warmup_days),
      total_days: warmup.config.warmup_days,
      today_limit: if(limit == :infinity, do: -1, else: limit),
      today_sent: today_sent,
      progress:
        if(warmup.graduated,
          do: 100,
          else: round(day / warmup.config.warmup_days * 100)
        )
    }

    {status, warmup}
  end

  @doc "Exports persistence fields, including a crash-safe count for today's UTC date."
  @spec export(t(), integer()) :: persisted_state()
  def export(warmup, now_ms) do
    day = current_day(warmup, now_ms)

    %{
      started_at: warmup.started_at,
      last_active_at: warmup.last_active_at,
      daily_counts: warmup.daily_counts,
      graduated: warmup.graduated,
      today_sent_count: Enum.at(warmup.daily_counts, day, 0),
      today_date: utc_date(now_ms)
    }
  end

  @doc "Resets the schedule while retaining its configuration."
  @spec reset(t(), integer()) :: t()
  def reset(warmup, now_ms), do: fresh(warmup.config, now_ms)

  defp build_config(options) do
    options = config_options(options)
    config = struct!(Config, options)

    if is_nil(config.growth_factor) do
      %{config | growth_factor: round((1.5 + config.rand_fun.() * 0.7) * 100) / 100}
    else
      config
    end
  end

  defp config_options(%Presets.Config{} = config) do
    config
    |> Map.from_struct()
    |> Map.take(Map.keys(%Config{}))
  end

  defp config_options(options), do: Map.new(options)

  defp fresh(config, now_ms) do
    %__MODULE__{config: config, started_at: now_ms, last_active_at: now_ms}
  end

  defp current_day(warmup, now_ms),
    do: floor((now_ms - warmup.started_at) / @milliseconds_per_day)

  defp check_inactivity(%__MODULE__{graduated: true} = warmup, now_ms) do
    hours_since_active = (now_ms - warmup.last_active_at) / @milliseconds_per_hour

    if hours_since_active > warmup.config.inactivity_threshold_hours do
      fresh(warmup.config, now_ms)
    else
      warmup
    end
  end

  defp check_inactivity(warmup, _now_ms), do: warmup

  defp restore_today_count(warmup, persisted, now_ms) do
    with date when is_binary(date) <- Map.get(persisted, :today_date),
         count when is_integer(count) <- Map.get(persisted, :today_sent_count),
         true <- date == utc_date(now_ms) do
      day = current_day(warmup, now_ms)
      current = Enum.at(warmup.daily_counts, day, 0)
      %{warmup | daily_counts: put_count(warmup.daily_counts, day, max(current, count))}
    else
      _missing_or_stale -> warmup
    end
  end

  defp put_count(counts, day, count) do
    counts = counts ++ List.duplicate(0, max(0, day - length(counts) + 1))
    List.replace_at(counts, day, count)
  end

  defp utc_date(now_ms) do
    now_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end
end
