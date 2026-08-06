defmodule AmarulaAntiban.Core.GroupOperationGuardTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.GroupOperationGuard

  @now 1_700_000_000_000
  @group "120000000000000000@g.us"

  test "disabled guard is inert" do
    guard = GroupOperationGuard.new()
    assert {:allow, ^guard} = GroupOperationGuard.check(guard, :add, @group, @now)
  end

  test "fixed window: first call always allows and starts the window at count 1" do
    guard =
      GroupOperationGuard.new(enabled: true, limits: %{add: %{max: 1, window_ms: 600_000}})

    assert {:allow, guard} = GroupOperationGuard.check(guard, :add, @group, @now)
    assert guard.windows["add:#{@group}"] == %{count: 1, reset_at: @now + 600_000}
  end

  test "denies once the window's max is reached, without mutating the counter further" do
    guard =
      GroupOperationGuard.new(enabled: true, limits: %{add: %{max: 2, window_ms: 600_000}})

    assert {:allow, guard} = GroupOperationGuard.check(guard, :add, @group, @now)
    assert {:allow, guard} = GroupOperationGuard.check(guard, :add, @group, @now + 1)

    assert {:deny, reason, retry_after_sec, ^guard} =
             GroupOperationGuard.check(guard, :add, @group, @now + 2)

    assert reason ==
             "Too many add attempts. WhatsApp rate-limits group operations — " <>
               "wait 10 min before trying again."

    assert retry_after_sec == 600
  end

  test "reset is exact at the window boundary" do
    guard =
      GroupOperationGuard.new(enabled: true, limits: %{add: %{max: 1, window_ms: 600_000}})

    {:allow, guard} = GroupOperationGuard.check(guard, :add, @group, @now)
    reset_at = @now + 600_000

    assert {:deny, _reason, _retry, ^guard} =
             GroupOperationGuard.check(guard, :add, @group, reset_at)

    assert {:allow, next_guard} = GroupOperationGuard.check(guard, :add, @group, reset_at + 1)
    assert next_guard.windows["add:#{@group}"] == %{count: 1, reset_at: reset_at + 1 + 600_000}
  end

  test "each {op, key} pair has an isolated window" do
    guard =
      GroupOperationGuard.new(
        enabled: true,
        limits: %{
          add: %{max: 1, window_ms: 600_000},
          remove: %{max: 1, window_ms: 600_000}
        }
      )

    {:allow, guard} = GroupOperationGuard.check(guard, :add, @group, @now)
    assert {:deny, _reason, _retry, ^guard} = GroupOperationGuard.check(guard, :add, @group, @now)

    assert {:allow, guard} = GroupOperationGuard.check(guard, :remove, @group, @now)
    assert {:allow, _guard} = GroupOperationGuard.check(guard, :add, "other@g.us", @now)
  end

  test "reset/3 clears a window, allowing immediate reuse" do
    guard =
      GroupOperationGuard.new(enabled: true, limits: %{add: %{max: 1, window_ms: 600_000}})

    {:allow, guard} = GroupOperationGuard.check(guard, :add, @group, @now)
    assert {:deny, _reason, _retry, ^guard} = GroupOperationGuard.check(guard, :add, @group, @now)

    guard = GroupOperationGuard.reset(guard, :add, @group)
    refute Map.has_key?(guard.windows, "add:#{@group}")
    assert {:allow, _guard} = GroupOperationGuard.check(guard, :add, @group, @now)
  end

  describe "classify_error/1" do
    test "maps confirmed WhatsApp error tokens to ban-adjacent signals" do
      assert GroupOperationGuard.classify_error({:group_op_failed, "429", "rate-overlimit"}) ==
               :rate_overlimit

      assert GroupOperationGuard.classify_error({:group_op_failed, "403", "locked"}) ==
               :group_locked

      assert GroupOperationGuard.classify_error({:group_op_failed, "403", "forbidden"}) ==
               :reachout_restricted

      assert GroupOperationGuard.classify_error({:group_op_failed, "404", "item-not-found"}) ==
               :invite_expired
    end

    test "unknown errors classify as nil" do
      assert GroupOperationGuard.classify_error(
               {:group_op_failed, "500", "internal-server-error"}
             ) ==
               nil

      assert GroupOperationGuard.classify_error(:unknown) == nil
      assert GroupOperationGuard.classify_error({:error, :timeout}) == nil
    end
  end

  test "export/restore round-trips populated windows" do
    guard =
      GroupOperationGuard.new(enabled: true, limits: %{add: %{max: 1, window_ms: 600_000}})

    {:allow, guard} = GroupOperationGuard.check(guard, :add, @group, @now)
    exported = GroupOperationGuard.export(guard)

    fresh = GroupOperationGuard.new(enabled: true, limits: %{add: %{max: 1, window_ms: 600_000}})
    restored = GroupOperationGuard.restore(fresh, exported)

    assert restored.windows == guard.windows

    assert {:deny, _reason, _retry, ^restored} =
             GroupOperationGuard.check(restored, :add, @group, @now)
  end

  test "restore tolerates a missing or malformed windows payload" do
    guard = GroupOperationGuard.new(enabled: true)
    assert GroupOperationGuard.restore(guard, %{}) == guard
    assert GroupOperationGuard.restore(guard, %{windows: "not a map"}) == guard

    restored = GroupOperationGuard.restore(guard, %{windows: %{"add:x" => "garbage"}})
    assert restored.windows == %{"add:x" => %{count: 0, reset_at: 0}}
  end

  test "stats reports the number of tracked windows" do
    guard =
      GroupOperationGuard.new(enabled: true, limits: %{add: %{max: 5, window_ms: 600_000}})

    assert GroupOperationGuard.stats(guard) == %{tracked_windows: 0}
    {:allow, guard} = GroupOperationGuard.check(guard, :add, @group, @now)
    assert GroupOperationGuard.stats(guard) == %{tracked_windows: 1}
  end
end
