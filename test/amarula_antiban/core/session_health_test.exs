defmodule AmarulaAntiban.Core.SessionHealthTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.SessionHealth

  @now 1_700_000_000_000

  test "tracks successes and ordinary failures" do
    health = SessionHealth.new()
    {health, []} = SessionHealth.record_success(health, @now)
    {health, []} = SessionHealth.record_failure(health, @now)
    assert %{decrypt_success: 1, decrypt_fail: 1, bad_mac_count: 0} = SessionHealth.stats(health)
  end

  test "degrades at threshold and recovers after the explicit window" do
    health = SessionHealth.new(bad_mac_threshold: 2, bad_mac_window_ms: 100)
    {health, []} = SessionHealth.record_failure(health, true, @now)
    {health, [{:session_degraded, stats}]} = SessionHealth.record_failure(health, true, @now + 1)
    assert stats.is_degraded
    assert stats.last_bad_mac == @now + 1

    {health, [{:session_recovered, stats}]} = SessionHealth.record_success(health, @now + 102)
    refute stats.is_degraded
    assert stats.degraded_since == nil
    assert SessionHealth.reset(health).stats.decrypt_success == 0
  end

  test "old Bad MACs do not combine across the window" do
    health = SessionHealth.new(bad_mac_threshold: 2, bad_mac_window_ms: 50)
    {health, []} = SessionHealth.record_failure(health, true, @now)
    {health, []} = SessionHealth.record_failure(health, true, @now + 51)
    refute SessionHealth.stats(health).is_degraded
    assert health.bad_mac_timestamps == [@now + 51]
  end
end
