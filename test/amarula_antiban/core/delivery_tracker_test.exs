defmodule AmarulaAntiban.Core.DeliveryTrackerTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.DeliveryTracker

  test "tracks delivery rate and rate-limits low-rate effects" do
    tracker = DeliveryTracker.new(min_sample_size: 2, low_rate_threshold: 0.6)

    tracker =
      tracker |> DeliveryTracker.sent("a", 3_600_000) |> DeliveryTracker.sent("b", 3_600_001)

    {tracker, [{:low_delivery_rate, rate}]} =
      DeliveryTracker.receipt(tracker, "missing", 3_600_002)

    assert rate == 0.0

    {stats, _} = DeliveryTracker.stats(tracker, 3_600_003)
    assert stats.delivery_rate == 0.0
    assert {_tracker, []} = DeliveryTracker.receipt(tracker, "a", 3_600_004)
  end

  test "prunes records outside the explicit window" do
    tracker = DeliveryTracker.new(window_ms: 10) |> DeliveryTracker.sent("a", 0)
    assert {%DeliveryTracker.Stats{sent_in_window: 0}, _} = DeliveryTracker.stats(tracker, 11)
  end
end
