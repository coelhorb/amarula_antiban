defmodule AmarulaAntiban.Core.HealthTest do
  use ExUnit.Case, async: true

  alias AmarulaAntiban.Core.Health

  @now 1_700_000_000_000
  @minute 60_000
  @hour 3_600_000

  defp health(options \\ []) do
    Health.new(
      Keyword.merge(
        [
          disconnect_warning_threshold: 3,
          disconnect_critical_threshold: 5,
          failed_message_threshold: 5,
          auto_pause_at: :high
        ],
        options
      ),
      @now
    )
  end

  defp disconnect_many(health, count, reason \\ "timeout") do
    Enum.reduce(1..count, health, fn _, health ->
      {health, _effects} = Health.record_disconnect(health, reason, @now)
      health
    end)
  end

  test "starts healthy with exact low-risk recommendation" do
    {status, _health} = Health.status(health(), @now)

    assert status.risk == :low
    assert status.score == 0
    assert status.reasons == ["No issues detected"]
    assert status.recommendation == "Operating normally. Continue monitoring."
    assert status.stats.uptime_ms == 0
  end

  test "regular disconnects escalate at warning and critical thresholds" do
    health = disconnect_many(health(), 2)
    {status, _health} = Health.status(health, @now)
    assert status.risk == :low
    assert status.stats.disconnects_last_hour == 2

    {health, effects} = Health.record_disconnect(health, "timeout", @now)
    assert [{:risk_changed, %{risk: :medium}}] = effects
    {status, _health} = Health.status(health, @now)
    assert status.score == 30
    assert "3 disconnects in last hour" in status.reasons

    health = disconnect_many(health, 2)
    {status, _health} = Health.status(health, @now)
    assert "5 disconnects in last hour (critical threshold)" in status.reasons
  end

  test "403 and 401 have exact severe scores and reasons" do
    {forbidden, effects} = Health.record_disconnect(health(), 403, @now)
    assert [{:risk_changed, %{risk: :high, score: 40}}] = effects
    {status, _forbidden} = Health.status(forbidden, @now)
    assert status.stats.forbidden_errors == 1
    assert status.reasons == ["1 forbidden (403) error in last hour"]

    assert status.recommendation ==
             "Reduce messaging rate by 80%. Consider pausing for 1-2 hours."

    {logged_out, _effects} = Health.record_disconnect(health(), 401, @now)
    {status, _logged_out} = Health.status(logged_out, @now)
    assert status.risk == :high
    assert status.score == 60
    assert status.reasons == ["Logged out by WhatsApp — possible temporary ban"]
    assert status.stats.last_disconnect_reason == "401"
  end

  test "multiple forbidden errors cap at 100 and become critical" do
    health = disconnect_many(health(), 3, "forbidden")
    {status, _health} = Health.status(health, @now)

    assert status.risk == :critical
    assert status.score == 100
    assert status.reasons == ["3 forbidden (403) errors in last hour"]

    assert status.recommendation ==
             "STOP ALL MESSAGING IMMEDIATELY. Disconnect and wait 24-48 hours before reconnecting."
  end

  test "failed messages and timelocks use exact thresholds" do
    health =
      Enum.reduce(1..5, health(), fn index, health ->
        {health, _effects} = Health.record_message_failed(health, "error #{index}", @now)
        health
      end)

    {status, _health} = Health.status(health, @now)
    assert status.risk == :medium
    assert status.score == 20
    assert status.stats.failed_messages_last_hour == 5
    assert status.reasons == ["5 failed messages in last hour"]

    {timelocked, _effects} = Health.record_reachout_timelock(health(), "soft", @now)
    {timelock_status, _timelocked} = Health.status(timelocked, @now)
    assert timelock_status.score == 25
    assert timelock_status.stats.timelock_errors == 1
    assert timelock_status.reasons == ["1 reachout timelock (463) error in last hour"]
  end

  test "risk changes emit once per tier while reconnect does not alter decay origin" do
    {health, first_effect} = Health.record_reachout_timelock(health(), "soft", @now)
    assert [{:risk_changed, %{risk: :medium}}] = first_effect

    {health, second_effect} = Health.record_reachout_timelock(health, "soft", @now)
    assert second_effect == []
    last_bad = health.last_bad_event_time

    health = Health.record_reconnect(health, @now + @minute)
    assert health.last_bad_event_time == last_bad
  end

  test "normal and severe scores decay at five and two points per minute" do
    {normal, _effects} = Health.record_reachout_timelock(health(), "soft", @now)
    {status, _normal} = Health.status(normal, @now + 5 * @minute)
    assert status.score == 0
    assert status.risk == :low

    {severe, _effects} = Health.record_disconnect(health(), 403, @now)
    {status, _severe} = Health.status(severe, @now + 10 * @minute)
    assert status.score == 20
    assert status.risk == :medium

    {status, _severe} = Health.status(severe, @now + 20 * @minute)
    assert status.score == 0
  end

  test "auto pause follows configured risk order and manual pause overrides it" do
    {healthy_paused, _health} = Health.paused?(health(), @now)
    refute healthy_paused

    {risky, _effects} = Health.record_disconnect(health(), 403, @now)
    {auto_paused, _risky} = Health.paused?(risky, @now)
    assert auto_paused

    manual = health() |> Health.set_paused(true)
    assert {true, ^manual} = Health.paused?(manual, @now)

    resumed = Health.set_paused(manual, false)
    assert {false, _resumed} = Health.paused?(resumed, @now)
  end

  test "status retains six hours but only scores the latest hour" do
    {health, _effects} = Health.record_disconnect(health(), "old", @now)
    health = Health.record_reconnect(health, @now + 2 * @hour)

    {status, health} = Health.status(health, @now + 2 * @hour)
    assert status.stats.disconnects_last_hour == 0
    assert length(health.events) == 2

    {_status, health} = Health.status(health, @now + 8 * @hour + 1)
    assert health.events == []
  end

  test "reset clears tracking and restarts uptime" do
    health = disconnect_many(health(), 3) |> Health.set_paused(true)
    reset = Health.reset(health, @now + 999)
    {status, reset} = Health.status(reset, @now + 999)

    assert status.risk == :low
    assert status.stats.disconnects_last_hour == 0
    assert status.stats.failed_messages_last_hour == 0
    assert status.stats.uptime_ms == 0
    refute reset.paused
  end
end
