defmodule AmarulaAntiban.Core.BanRecoveryTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.BanRecovery

  @now 1_700_000_000_000
  @day 86_400_000
  @week 7 * @day

  test "no active recovery reports graduated at full rate" do
    assert BanRecovery.status(BanRecovery.new(), @now) == %BanRecovery.Status{}
  end

  test "recording a timelock ban pauses at 10% for 24h" do
    {recovery, effects} = BanRecovery.record_ban_event(BanRecovery.new(), :timelock, @now)
    assert [{:recovery_started, status}] = effects
    assert status.phase == :paused
    assert status.rate_multiplier == 0.10
    assert status.pause_remaining_ms == @day
    assert BanRecovery.status(recovery, @now) == status
  end

  test "gives up and goes dead after max_recovery_weeks without graduating" do
    {recovery, _effects} = BanRecovery.record_ban_event(BanRecovery.new(), :timelock, @now)
    pause_end = @now + @day

    recovering = BanRecovery.status(recovery, pause_end)
    assert recovering.phase == :recovering
    assert_in_delta recovering.rate_multiplier, 0.10, 0.0001

    dead = BanRecovery.status(recovery, pause_end + 8 * @week)
    assert dead.phase == :dead
    assert dead.rate_multiplier == 0.0
    assert dead.should_replace_number == true
  end

  test "graduates once the weekly ramp reaches full rate before giving up" do
    {recovery, _effects} = BanRecovery.record_ban_event(BanRecovery.new(), :rate_overlimit, @now)
    pause_end = @now + 14_400_000

    still_recovering = BanRecovery.status(recovery, pause_end + 6 * @week)
    assert still_recovering.phase == :recovering
    assert_in_delta still_recovering.rate_multiplier, 0.9537, 0.001
    assert still_recovering.estimated_full_recovery_at != nil

    graduated = BanRecovery.status(recovery, pause_end + 7 * @week)
    assert graduated.phase == :graduated
    assert graduated.rate_multiplier == 1.0
  end

  test "escalates to hard_ban on the third ban within the window and notifies via effects" do
    recovery = BanRecovery.new()
    {recovery, _} = BanRecovery.record_ban_event(recovery, :timelock, @now)
    {recovery, _} = BanRecovery.record_ban_event(recovery, :timelock, @now + 1)
    {recovery, effects} = BanRecovery.record_ban_event(recovery, :timelock, @now + 2)

    assert recovery.event_type == :hard_ban
    assert recovery.ban_count_30d == 3

    assert [
             {:recovery_started, started_status},
             {:recovery_escalated, %{from: :timelock, to: :hard_ban}},
             {:hard_ban_detected, hard_ban_status}
           ] = effects

    assert started_status == hard_ban_status
    assert started_status.phase == :dead
    assert BanRecovery.status(recovery, @now + 2).should_replace_number == true
  end

  test "hard_ban is permanent regardless of elapsed time" do
    {recovery, _} = BanRecovery.record_ban_event(BanRecovery.new(), :hard_ban, @now)
    status = BanRecovery.status(recovery, @now + 1_000 * @week)
    assert status.phase == :dead
    assert status.rate_multiplier == 0.0
  end

  test "ban count resets after the ban window elapses, but not before" do
    {recovery, _} = BanRecovery.record_ban_event(BanRecovery.new(), :timelock, @now)
    assert recovery.ban_count_30d == 1

    {within_window, _} = BanRecovery.record_ban_event(recovery, :timelock, @now + 1)
    assert within_window.ban_count_30d == 2

    {after_window, _} = BanRecovery.record_ban_event(recovery, :timelock, @now + 31 * @day)
    assert after_window.ban_count_30d == 1
  end

  test "classify_error maps known WA codes and reasons" do
    assert BanRecovery.classify_error(463) == :timelock
    assert BanRecovery.classify_error(429) == :rate_overlimit
    assert BanRecovery.classify_error(401) == :hard_ban
    assert BanRecovery.classify_error(:logged_out) == :hard_ban
    assert BanRecovery.classify_error(500) == nil
    assert BanRecovery.classify_error(:unknown) == nil
  end

  test "rate_multiplier/2 mirrors status/2's rate_multiplier" do
    {recovery, _} = BanRecovery.record_ban_event(BanRecovery.new(), :soft_ban, @now)
    assert BanRecovery.rate_multiplier(recovery, @now) == 0.05
  end
end
