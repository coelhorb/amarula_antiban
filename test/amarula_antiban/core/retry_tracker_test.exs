defmodule AmarulaAntiban.Core.RetryTrackerTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.RetryTracker

  @now 1_700_000_000_000

  test "classifies status codes and all upstream text reasons" do
    assert RetryTracker.classify(%{output: %{statusCode: 463}}) == :server_error_463
    assert RetryTracker.classify(%{"statusCode" => 429}) == :server_error_429
    assert RetryTracker.classify(%{message: "bad mac verification failed"}) == :bad_mac
    assert RetryTracker.classify(%{message: "no session found"}) == :no_session
    assert RetryTracker.classify(%{message: "invalid key"}) == :invalid_key
    assert RetryTracker.classify(%{message: "decryption failed"}) == :decryption_failure
    assert RetryTracker.classify(%{message: "request timed out"}) == :timeout
    assert RetryTracker.classify(%{message: "peer unreachable"}) == :no_route
    assert RetryTracker.classify(%{message: "malformed node"}) == :node_malformed
    assert RetryTracker.classify(nil) == :unknown
    assert RetryTracker.classify("other") == :unknown
  end

  test "manual updates track reasons and emit spiral effects at the threshold" do
    tracker = RetryTracker.new(enabled: true, spiral_threshold: 3)
    update = %{key: %{id: "msg"}, status: 0, error: %{message: "timeout"}}
    {tracker, []} = RetryTracker.on_message_update(tracker, update, @now)
    {tracker, []} = RetryTracker.on_message_update(tracker, update, @now + 1)

    {tracker, [{:retry_spiral, effect}]} =
      RetryTracker.on_message_update(tracker, update, @now + 2)

    assert effect == %{msg_id: "msg", reason: :timeout, count: 3}
    assert RetryTracker.spiraling?(tracker, "msg")
    assert RetryTracker.stats(tracker).by_reason.timeout == 3
    assert RetryTracker.stats(tracker).spirals_detected == 1
  end

  test "ignores unavailable/non-error updates and disabled tracking" do
    tracker = RetryTracker.new(enabled: true)
    assert {^tracker, []} = RetryTracker.on_message_update(tracker, %{key: %{}, status: 0}, @now)

    assert {^tracker, []} =
             RetryTracker.on_message_update(tracker, %{key: %{id: "x"}, status: 1}, @now)

    disabled = RetryTracker.new()
    assert {^disabled, []} = RetryTracker.record(disabled, "x", :timeout, @now)
  end

  test "clear, expiry cleanup, stats and reset are pure" do
    tracker = RetryTracker.new(enabled: true)
    {tracker, []} = RetryTracker.record(tracker, "old", :bad_mac, @now)
    {tracker, []} = RetryTracker.record(tracker, "new", :timeout, @now + 300_001)
    tracker = RetryTracker.cleanup(tracker, @now + 300_001)
    refute RetryTracker.spiraling?(tracker, "old")
    assert RetryTracker.stats(tracker).active_retries == 1
    tracker = RetryTracker.clear(tracker, "new")
    assert RetryTracker.stats(tracker).active_retries == 0
    assert RetryTracker.reset(tracker).total_retries == 0
  end

  test "max_retries signals the analytical boundary without controlling transport" do
    tracker = RetryTracker.new(enabled: true, max_retries: 1, spiral_threshold: 3)

    assert {tracker, [{:retry_limit_reached, reached}]} =
             RetryTracker.record(tracker, "msg", :timeout, @now)

    assert reached == %{msg_id: "msg", reason: :timeout, count: 1, max_retries: 1}
    assert RetryTracker.retry_limit_reached?(tracker, "msg")

    assert {tracker, [{:retry_limit_exceeded, exceeded}]} =
             RetryTracker.record(tracker, "msg", :bad_mac, @now + 1)

    assert exceeded == %{msg_id: "msg", reason: :bad_mac, count: 2, max_retries: 1}
    assert tracker.retries["msg"].count == 2
    assert tracker.retries["msg"].reasons == [:timeout, :bad_mac]

    assert %{
             total_retries: 2,
             retry_limits_reached: 1,
             retries_over_limit: 1,
             active_at_retry_limit: 1
           } = RetryTracker.stats(tracker)

    tracker = RetryTracker.clear(tracker, "msg")
    refute RetryTracker.retry_limit_reached?(tracker, "msg")
    assert RetryTracker.stats(tracker).active_at_retry_limit == 0
    assert RetryTracker.stats(tracker).retry_limits_reached == 1
  end
end
