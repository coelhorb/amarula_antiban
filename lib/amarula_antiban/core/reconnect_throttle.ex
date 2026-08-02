defmodule AmarulaAntiban.Core.ReconnectThrottle do
  @moduledoc "Pure post-reconnect rate ramp and one-minute send gate."

  @window_ms 60_000

  defmodule Config do
    @moduledoc "Ramp duration, shape, and baseline send rate."
    defstruct enabled: false,
              ramp_duration_ms: 60_000,
              initial_rate_multiplier: 0.1,
              ramp_steps: 6,
              baseline_rate_per_minute: 8

    @type t :: %__MODULE__{}
  end

  defmodule Stats do
    @moduledoc "Current post-reconnect throttle state."
    defstruct is_throttled: false,
              current_multiplier: 1.0,
              throttled_since_ms: nil,
              remaining_ms: 0,
              throttled_send_count: 0,
              lifetime_reconnects: 0

    @type t :: %__MODULE__{}
  end

  @type t :: %__MODULE__{
          config: Config.t(),
          throttled_since: integer() | nil,
          throttled_send_count: non_neg_integer(),
          lifetime_reconnects: non_neg_integer(),
          sends_in_current_window: non_neg_integer(),
          current_window_start: integer()
        }

  defstruct config: nil,
            throttled_since: nil,
            throttled_send_count: 0,
            lifetime_reconnects: 0,
            sends_in_current_window: 0,
            current_window_start: 0

  @doc "Builds a reconnect throttle."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []), do: %__MODULE__{config: struct!(Config, Map.new(options))}

  @doc "Starts a new ramp at `now_ms`."
  @spec reconnect(t(), integer()) :: t()
  def reconnect(%__MODULE__{config: %{enabled: false}} = throttle, _now_ms), do: throttle

  def reconnect(throttle, now_ms) do
    %{
      throttle
      | throttled_since: now_ms,
        throttled_send_count: 0,
        lifetime_reconnects: throttle.lifetime_reconnects + 1,
        sends_in_current_window: 0,
        current_window_start: now_ms
    }
  end

  @doc "Returns the stepped ramp multiplier at the injected time."
  @spec multiplier(t(), integer()) :: float()
  def multiplier(%__MODULE__{config: %{enabled: false}}, _now_ms), do: 1.0
  def multiplier(%__MODULE__{throttled_since: nil}, _now_ms), do: 1.0

  def multiplier(throttle, now_ms) do
    elapsed = max(0, now_ms - throttle.throttled_since)

    if elapsed >= throttle.config.ramp_duration_ms do
      1.0
    else
      step =
        min(
          throttle.config.ramp_steps,
          floor(elapsed * throttle.config.ramp_steps / throttle.config.ramp_duration_ms)
        )

      progress = step / throttle.config.ramp_steps

      min(
        1.0,
        throttle.config.initial_rate_multiplier +
          (1.0 - throttle.config.initial_rate_multiplier) * progress
      )
    end
  end

  @doc "Checks and consumes the current one-minute send budget."
  @spec before_send(t(), integer()) :: {:allow, t()} | {:deny, String.t(), non_neg_integer(), t()}
  def before_send(throttle, now_ms) do
    current_multiplier = multiplier(throttle, now_ms)

    cond do
      not throttle.config.enabled or is_nil(throttle.throttled_since) ->
        {:allow, throttle}

      current_multiplier >= 1.0 ->
        {:allow, %{throttle | throttled_since: nil}}

      true ->
        throttle = reset_window(throttle, now_ms)
        allowed = max(1, floor(baseline_rate(throttle) * current_multiplier))

        if throttle.sends_in_current_window >= allowed do
          remaining = max(0, @window_ms - (now_ms - throttle.current_window_start))
          percent = floor(current_multiplier * 100)

          {:deny,
           "Post-reconnect throttle: #{percent}% rate (#{throttle.sends_in_current_window}/#{allowed} sends in window)",
           remaining, throttle}
        else
          {:allow,
           %{
             throttle
             | sends_in_current_window: throttle.sends_in_current_window + 1,
               throttled_send_count: throttle.throttled_send_count + 1
           }}
        end
    end
  end

  @doc "Returns throttle statistics at `now_ms`."
  @spec stats(t(), integer()) :: Stats.t()
  def stats(throttle, now_ms) do
    current = multiplier(throttle, now_ms)
    throttled? = not is_nil(throttle.throttled_since) and current < 1.0

    %Stats{
      is_throttled: throttled?,
      current_multiplier: current,
      throttled_since_ms: throttle.throttled_since,
      remaining_ms:
        if(throttled?,
          do: max(0, throttle.config.ramp_duration_ms - (now_ms - throttle.throttled_since)),
          else: 0
        ),
      throttled_send_count: throttle.throttled_send_count,
      lifetime_reconnects: throttle.lifetime_reconnects
    }
  end

  @doc "Ends the active ramp while retaining lifetime statistics."
  @spec stop(t()) :: t()
  def stop(throttle), do: %{throttle | throttled_since: nil}

  defp reset_window(throttle, now_ms) do
    if now_ms - throttle.current_window_start >= @window_ms do
      %{throttle | sends_in_current_window: 0, current_window_start: now_ms}
    else
      throttle
    end
  end

  defp baseline_rate(%{config: %{baseline_rate_per_minute: fun}}) when is_function(fun, 0),
    do: fun.()

  defp baseline_rate(throttle), do: throttle.config.baseline_rate_per_minute
end
