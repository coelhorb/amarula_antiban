defmodule AmarulaAntiban.Core.TimelockGuardTest do
  use ExUnit.Case, async: true

  alias AmarulaAntiban.Core.TimelockGuard

  @now 1_700_000_000_000
  @new_jid "new-contact@s.whatsapp.net"

  test "initial state is inactive and allows new contacts" do
    guard = TimelockGuard.new(resume_buffer_ms: 1_000)
    assert {false, ^guard, []} = TimelockGuard.timelocked?(guard, @now)
    assert {:allow, ^guard, []} = TimelockGuard.can_send(guard, @new_jid, @now)

    assert TimelockGuard.state(guard) == %{
             is_active: false,
             enforcement_type: nil,
             expires_at: nil,
             detected_at: nil,
             error_count: 0
           }
  end

  test "first 463 activates a 60-second lock and subsequent errors increment" do
    guard = TimelockGuard.new()
    {guard, effects} = TimelockGuard.record_463_error(guard, @now)

    assert guard.is_active
    assert guard.expires_at == @now + 60_000
    assert guard.error_count == 1

    assert [
             {:timelock_detected, %{is_active: true, error_count: 1}},
             {:schedule_resume, generation, 70_000}
           ] = effects

    assert generation == guard.scheduled_generation

    {guard, []} = TimelockGuard.record_463_error(guard, @now + 1)
    assert guard.error_count == 2
  end

  test "metadata activates, updates, and deactivates a lock" do
    guard = TimelockGuard.new(resume_buffer_ms: 1_000)

    {guard, effects} =
      TimelockGuard.update(
        guard,
        %{
          is_active: true,
          enforcement_type: "reachout",
          time_enforcement_ends: @now + 120_000
        },
        @now
      )

    assert guard.detected_at == @now
    assert guard.enforcement_type == "reachout"

    assert [{:timelock_detected, _state}, {:schedule_resume, first_generation, 121_000}] =
             effects

    {guard, [{:schedule_resume, second_generation, 201_000}]} =
      TimelockGuard.update(
        guard,
        %{is_active: true, time_enforcement_ends: @now + 201_000},
        @now + 1_000
      )

    assert second_generation > first_generation

    {guard, [{:timelock_lifted, %{is_active: false}}]} =
      TimelockGuard.update(guard, %{is_active: false}, @now + 2_000)

    refute guard.is_active
    assert guard.scheduled_generation == nil
  end

  test "a lock blocks only unknown one-to-one contacts" do
    {guard, _effects} = TimelockGuard.record_463_error(TimelockGuard.new(), @now)
    assert {:deny, reason, ^guard} = TimelockGuard.can_send(guard, @new_jid, @now)
    assert reason =~ "Reachout timelocked (unknown)"
    assert reason =~ "Expires in 60s"

    guard = TimelockGuard.register_known_chat(guard, "known@s.whatsapp.net")
    assert {:allow, ^guard, []} = TimelockGuard.can_send(guard, "known@s.whatsapp.net", @now)
    assert {:allow, ^guard, []} = TimelockGuard.can_send(guard, "group@g.us", @now)
    assert {:allow, ^guard, []} = TimelockGuard.can_send(guard, "channel@newsletter", @now)
  end

  test "bulk registration preserves all known chats" do
    guard =
      TimelockGuard.new()
      |> TimelockGuard.register_known_chats([
        "user1@s.whatsapp.net",
        "user2@s.whatsapp.net",
        "group@g.us"
      ])

    assert TimelockGuard.known_chats(guard) ==
             MapSet.new(["user1@s.whatsapp.net", "user2@s.whatsapp.net", "group@g.us"])
  end

  test "buffered expiry auto-lifts only at expiry plus buffer" do
    {guard, _effects} =
      TimelockGuard.update(
        TimelockGuard.new(resume_buffer_ms: 500),
        %{is_active: true, time_enforcement_ends: @now + 100},
        @now
      )

    assert {true, ^guard, []} = TimelockGuard.timelocked?(guard, @now + 599)
    assert {:deny, _reason, ^guard} = TimelockGuard.can_send(guard, @new_jid, @now + 599)

    assert {false, lifted, [{:timelock_lifted, %{is_active: false}}]} =
             TimelockGuard.timelocked?(guard, @now + 600)

    assert {:allow, ^lifted, []} = TimelockGuard.can_send(lifted, @new_jid, @now + 600)
  end

  test "can_send itself auto-lifts an expired lock" do
    {guard, _effects} =
      TimelockGuard.update(
        TimelockGuard.new(resume_buffer_ms: 0),
        %{is_active: true, time_enforcement_ends: @now + 100},
        @now
      )

    assert {:allow, guard, [{:timelock_lifted, _state}]} =
             TimelockGuard.can_send(guard, @new_jid, @now + 100)

    refute guard.is_active
  end

  test "stale timer generation cannot lift a newer lock" do
    {guard, [{:timelock_detected, _}, {:schedule_resume, old_generation, 100}]} =
      TimelockGuard.update(
        TimelockGuard.new(resume_buffer_ms: 0),
        %{is_active: true, time_enforcement_ends: @now + 100},
        @now
      )

    {guard, [{:schedule_resume, current_generation, 200}]} =
      TimelockGuard.update(
        guard,
        %{is_active: true, time_enforcement_ends: @now + 200},
        @now
      )

    assert current_generation > old_generation
    assert {^guard, []} = TimelockGuard.resume(guard, old_generation, @now + 150)
    assert guard.is_active

    assert {lifted, [{:timelock_lifted, %{is_active: false}}]} =
             TimelockGuard.resume(guard, current_generation, @now + 200)

    refute lifted.is_active
  end

  test "manual lift invalidates a scheduled generation" do
    {guard, _effects} = TimelockGuard.record_463_error(TimelockGuard.new(), @now)
    generation = guard.scheduled_generation

    assert {guard, [{:timelock_lifted, %{is_active: false}}]} = TimelockGuard.lift(guard)
    assert guard.scheduled_generation == nil
    assert {^guard, []} = TimelockGuard.resume(guard, generation, @now + 70_000)
    assert {^guard, []} = TimelockGuard.lift(guard)
  end

  test "reset clears lock, errors, chats, and invalidates generations" do
    {guard, _effects} = TimelockGuard.record_463_error(TimelockGuard.new(), @now)
    guard = TimelockGuard.register_known_chat(guard, "known@s.whatsapp.net")
    old_generation = guard.timer_generation
    reset = TimelockGuard.reset(guard)

    refute reset.is_active
    assert reset.error_count == 0
    assert TimelockGuard.known_chats(reset) == MapSet.new()
    assert reset.timer_generation > old_generation
  end

  test "active lock without an expiry uses the 60-second reason fallback" do
    {guard, [{:timelock_detected, _state}]} =
      TimelockGuard.update(TimelockGuard.new(), %{is_active: true}, @now)

    assert {:deny, reason, ^guard} = TimelockGuard.can_send(guard, @new_jid, @now)
    assert reason =~ "Expires in 60s"
  end
end
