defmodule AmarulaAntiban.Core.ReconnectThrottleTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.ReconnectThrottle

  @now 1_700_000_000_000

  test "starts inactive and disabled throttle stays inert" do
    throttle = ReconnectThrottle.new(enabled: true)
    assert ReconnectThrottle.multiplier(throttle, @now) == 1.0
    assert {:allow, ^throttle} = ReconnectThrottle.before_send(throttle, @now)
    disabled = ReconnectThrottle.new() |> ReconnectThrottle.reconnect(@now)
    assert ReconnectThrottle.stats(disabled, @now).lifetime_reconnects == 0
  end

  test "ramps in exact discrete steps from 10 to 100 percent" do
    throttle =
      ReconnectThrottle.new(enabled: true, ramp_duration_ms: 6_000, ramp_steps: 6)
      |> ReconnectThrottle.reconnect(@now)

    assert ReconnectThrottle.multiplier(throttle, @now) == 0.1
    assert_in_delta ReconnectThrottle.multiplier(throttle, @now + 1_000), 0.25, 1.0e-12
    assert_in_delta ReconnectThrottle.multiplier(throttle, @now + 3_000), 0.55, 1.0e-12
    assert ReconnectThrottle.multiplier(throttle, @now + 6_000) == 1.0
  end

  test "gates over-budget sends and resets the minute window without sleeps" do
    throttle =
      ReconnectThrottle.new(
        enabled: true,
        ramp_duration_ms: 120_000,
        initial_rate_multiplier: 0.125,
        baseline_rate_per_minute: 8
      )
      |> ReconnectThrottle.reconnect(@now)

    assert {:allow, throttle} = ReconnectThrottle.before_send(throttle, @now)
    assert {:deny, reason, 60_000, ^throttle} = ReconnectThrottle.before_send(throttle, @now)
    assert reason =~ "12% rate (1/1 sends"
    assert {:allow, throttle} = ReconnectThrottle.before_send(throttle, @now + 60_000)
    assert throttle.sends_in_current_window == 1
    assert throttle.current_window_start == @now + 60_000
  end

  test "stats and stop report lifetime values" do
    throttle =
      ReconnectThrottle.new(enabled: true, ramp_duration_ms: 1_000)
      |> ReconnectThrottle.reconnect(@now)

    {:allow, throttle} = ReconnectThrottle.before_send(throttle, @now)
    stats = ReconnectThrottle.stats(throttle, @now)
    assert stats.is_throttled
    assert stats.remaining_ms == 1_000
    assert stats.throttled_send_count == 1
    assert stats.lifetime_reconnects == 1
    refute ReconnectThrottle.stats(ReconnectThrottle.stop(throttle), @now).is_throttled
  end
end
