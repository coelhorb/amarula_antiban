defmodule AmarulaAntiban.Core.Health do
  @moduledoc """
  Pure account-health scoring based on recent connection and delivery events.

  Risk-change callbacks from the TypeScript implementation are represented as
  `{:risk_changed, status}` effects. The OTP session can execute callbacks or
  telemetry without introducing I/O into this core module.
  """

  alias AmarulaAntiban.Presets

  @milliseconds_per_minute 60_000
  @milliseconds_per_hour 3_600_000
  @event_retention_ms 21_600_000
  @risk_order [:low, :medium, :high, :critical]

  defmodule Config do
    @moduledoc "Health thresholds and the risk tier that pauses sending."

    @type t :: %__MODULE__{
            disconnect_warning_threshold: pos_integer(),
            disconnect_critical_threshold: pos_integer(),
            failed_message_threshold: pos_integer(),
            auto_pause_at: :low | :medium | :high | :critical
          }

    defstruct disconnect_warning_threshold: 3,
              disconnect_critical_threshold: 5,
              failed_message_threshold: 5,
              auto_pause_at: :high
  end

  defmodule Stats do
    @moduledoc "Recent event counts and monitor uptime."

    @type t :: %__MODULE__{
            disconnects_last_hour: non_neg_integer(),
            failed_messages_last_hour: non_neg_integer(),
            forbidden_errors: non_neg_integer(),
            timelock_errors: non_neg_integer(),
            uptime_ms: non_neg_integer(),
            last_disconnect_reason: String.t() | nil
          }

    defstruct [
      :disconnects_last_hour,
      :failed_messages_last_hour,
      :forbidden_errors,
      :timelock_errors,
      :uptime_ms,
      :last_disconnect_reason
    ]
  end

  defmodule Status do
    @moduledoc "Computed ban-risk score, reasons, recommendation, and statistics."

    @type risk :: :low | :medium | :high | :critical
    @type t :: %__MODULE__{
            risk: risk(),
            score: 0..100,
            reasons: [String.t()],
            recommendation: String.t(),
            stats: AmarulaAntiban.Core.Health.Stats.t()
          }

    defstruct [:risk, :score, :reasons, :recommendation, :stats]
  end

  @type event_type ::
          :disconnect | :forbidden | :logged_out | :message_failed | :reconnect | :timelock
  @type event :: %{type: event_type(), timestamp: integer(), detail: String.t() | nil}
  @type effect :: {:risk_changed, Status.t()}
  @type t :: %__MODULE__{
          config: Config.t(),
          events: [event()],
          start_time: integer(),
          paused: boolean(),
          last_risk: Status.risk(),
          last_bad_event_time: integer(),
          last_event_was_severe: boolean()
        }

  defstruct config: nil,
            events: [],
            start_time: 0,
            paused: false,
            last_risk: :low,
            last_bad_event_time: 0,
            last_event_was_severe: false

  @doc "Builds a fresh monitor at `now_ms`."
  @spec new(keyword() | map() | Presets.Config.t(), integer()) :: t()
  def new(options \\ [], now_ms) do
    config = struct!(Config, config_options(options))

    %__MODULE__{
      config: config,
      start_time: now_ms,
      last_bad_event_time: now_ms
    }
  end

  @doc "Records a disconnect and returns any risk-change effect."
  @spec record_disconnect(t(), String.t() | integer() | atom(), integer()) :: {t(), [effect()]}
  def record_disconnect(health, reason, now_ms) do
    detail = to_string(reason)

    {type, severe} =
      cond do
        detail in ["403", "forbidden"] -> {:forbidden, true}
        detail in ["401", "loggedOut"] -> {:logged_out, true}
        true -> {:disconnect, false}
      end

    health
    |> add_event(type, detail, now_ms)
    |> Map.put(:last_bad_event_time, now_ms)
    |> Map.put(:last_event_was_severe, severe)
    |> check_risk_change(now_ms)
  end

  @doc "Records a successful reconnect without resetting score-decay time."
  @spec record_reconnect(t(), integer()) :: t()
  def record_reconnect(health, now_ms), do: add_event(health, :reconnect, nil, now_ms)

  @doc "Records a failed message and returns any risk-change effect."
  @spec record_message_failed(t(), String.t() | nil, integer()) :: {t(), [effect()]}
  def record_message_failed(health, detail \\ nil, now_ms) do
    health
    |> add_event(:message_failed, detail, now_ms)
    |> Map.put(:last_bad_event_time, now_ms)
    |> Map.put(:last_event_was_severe, false)
    |> check_risk_change(now_ms)
  end

  @doc "Records a reachout timelock error and returns any risk-change effect."
  @spec record_reachout_timelock(t(), String.t() | nil, integer()) :: {t(), [effect()]}
  def record_reachout_timelock(health, detail \\ nil, now_ms) do
    health
    |> add_event(:timelock, detail, now_ms)
    |> Map.put(:last_bad_event_time, now_ms)
    |> Map.put(:last_event_was_severe, false)
    |> check_risk_change(now_ms)
  end

  @doc "Computes current health and returns state after six-hour retention cleanup."
  @spec status(t(), integer()) :: {Status.t(), t()}
  def status(health, now_ms) do
    health = cleanup(health, now_ms)
    hour_events = Enum.filter(health.events, &(now_ms - &1.timestamp < @milliseconds_per_hour))
    disconnects = count_type(hour_events, :disconnect)
    forbidden = count_type(hour_events, :forbidden)
    logged_out = count_type(hour_events, :logged_out)
    failed_messages = count_type(hour_events, :message_failed)
    timelocked = count_type(hour_events, :timelock)

    {score, reasons} =
      {0, []}
      |> score_forbidden(forbidden)
      |> score_logged_out(logged_out)
      |> score_timelocked(timelocked)
      |> score_disconnects(disconnects, health.config)
      |> score_failures(failed_messages, health.config)

    score = min(100, score)
    minutes_since_last_bad = (now_ms - health.last_bad_event_time) / @milliseconds_per_minute
    decay_rate = if health.last_event_was_severe, do: 2, else: 5
    score = max(0, score - floor(minutes_since_last_bad * decay_rate))
    risk = risk_for_score(score)

    last_disconnect =
      health.events
      |> Enum.reverse()
      |> Enum.find(&(&1.type in [:disconnect, :forbidden, :logged_out]))

    result = %Status{
      risk: risk,
      score: score,
      reasons: if(reasons == [], do: ["No issues detected"], else: reasons),
      recommendation: recommendation(risk),
      stats: %Stats{
        disconnects_last_hour: disconnects,
        failed_messages_last_hour: failed_messages,
        forbidden_errors: forbidden,
        timelock_errors: timelocked,
        uptime_ms: now_ms - health.start_time,
        last_disconnect_reason: last_disconnect && last_disconnect.detail
      }
    }

    {result, health}
  end

  @doc "Returns whether manual state or configured risk requires a send pause."
  @spec paused?(t(), integer()) :: {boolean(), t()}
  def paused?(%__MODULE__{paused: true} = health, _now_ms), do: {true, health}

  def paused?(health, now_ms) do
    {current, health} = status(health, now_ms)
    paused = risk_index(current.risk) >= risk_index(health.config.auto_pause_at)
    {paused, health}
  end

  @doc "Sets or clears the manual pause flag."
  @spec set_paused(t(), boolean()) :: t()
  def set_paused(health, paused) when is_boolean(paused), do: %{health | paused: paused}

  @doc "Clears all events and timing state at `now_ms`."
  @spec reset(t(), integer()) :: t()
  def reset(health, now_ms) do
    %{
      health
      | events: [],
        start_time: now_ms,
        paused: false,
        last_risk: :low,
        last_bad_event_time: now_ms,
        last_event_was_severe: false
    }
  end

  defp config_options(%Presets.Config{} = config) do
    config
    |> Map.from_struct()
    |> Map.take(Map.keys(%Config{}))
  end

  defp config_options(options), do: Map.new(options)

  defp add_event(health, type, detail, now_ms) do
    event = %{type: type, timestamp: now_ms, detail: detail}
    %{health | events: health.events ++ [event]}
  end

  defp check_risk_change(health, now_ms) do
    {current, health} = status(health, now_ms)

    if current.risk == health.last_risk do
      {health, []}
    else
      {%{health | last_risk: current.risk}, [{:risk_changed, current}]}
    end
  end

  defp cleanup(health, now_ms) do
    %{health | events: Enum.filter(health.events, &(now_ms - &1.timestamp < @event_retention_ms))}
  end

  defp count_type(events, type), do: Enum.count(events, &(&1.type == type))

  defp score_forbidden({score, reasons}, 0), do: {score, reasons}

  defp score_forbidden({score, reasons}, count) do
    suffix = if count > 1, do: "s", else: ""
    {score + 40 * count, reasons ++ ["#{count} forbidden (403) error#{suffix} in last hour"]}
  end

  defp score_logged_out({score, reasons}, 0), do: {score, reasons}

  defp score_logged_out({score, reasons}, _count) do
    {score + 60, reasons ++ ["Logged out by WhatsApp — possible temporary ban"]}
  end

  defp score_timelocked({score, reasons}, 0), do: {score, reasons}

  defp score_timelocked({score, reasons}, count) do
    suffix = if count > 1, do: "s", else: ""

    {score + 25, reasons ++ ["#{count} reachout timelock (463) error#{suffix} in last hour"]}
  end

  defp score_disconnects({score, reasons}, count, config)
       when count >= config.disconnect_critical_threshold do
    {score + 30, reasons ++ ["#{count} disconnects in last hour (critical threshold)"]}
  end

  defp score_disconnects({score, reasons}, count, config)
       when count >= config.disconnect_warning_threshold do
    {score + 30, reasons ++ ["#{count} disconnects in last hour"]}
  end

  defp score_disconnects(accumulator, _count, _config), do: accumulator

  defp score_failures({score, reasons}, count, config)
       when count >= config.failed_message_threshold do
    {score + 20, reasons ++ ["#{count} failed messages in last hour"]}
  end

  defp score_failures(accumulator, _count, _config), do: accumulator

  defp risk_for_score(score) when score >= 80, do: :critical
  defp risk_for_score(score) when score >= 40, do: :high
  defp risk_for_score(score) when score >= 15, do: :medium
  defp risk_for_score(_score), do: :low

  defp recommendation(:critical),
    do: "STOP ALL MESSAGING IMMEDIATELY. Disconnect and wait 24-48 hours before reconnecting."

  defp recommendation(:high),
    do: "Reduce messaging rate by 80%. Consider pausing for 1-2 hours."

  defp recommendation(:medium),
    do: "Reduce messaging rate by 50%. Increase delays between messages."

  defp recommendation(:low), do: "Operating normally. Continue monitoring."

  defp risk_index(risk), do: Enum.find_index(@risk_order, &(&1 == risk))
end
