defmodule AmarulaAntiban.Core.RateLimiterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AmarulaAntiban.Core.RateLimiter

  @now 1_700_000_000_000
  @jid "test@s.whatsapp.net"

  defp limiter(overrides \\ []) do
    defaults = [
      max_per_minute: 5,
      max_per_hour: 50,
      max_per_day: 500,
      min_delay_ms: 100,
      max_delay_ms: 500,
      new_chat_delay_ms: 200,
      max_identical_messages: 3,
      burst_allowance: 2,
      identical_message_window_ms: 3_600_000,
      rand_fun: fn -> 0.5 end
    ]

    RateLimiter.new(Keyword.merge(defaults, overrides))
  end

  defp record_many(limiter, count, now_ms, content_prefix \\ "Message") do
    Enum.reduce(0..(count - 1), limiter, fn index, acc ->
      RateLimiter.record(acc, @jid, "#{content_prefix} #{index}", now_ms)
    end)
  end

  test "allows and counts messages within the minute limit" do
    limiter =
      Enum.reduce(0..4, limiter(), fn index, limiter ->
        content = "Message #{index}"
        assert {:allow, delay, limiter} = RateLimiter.get_delay(limiter, @jid, content, @now)
        assert delay >= 0
        RateLimiter.record(limiter, @jid, content, @now)
      end)

    {stats, _limiter} = RateLimiter.stats(limiter, @now)
    assert stats.last_minute == 5
  end

  test "minute limit delays until the oldest record expires" do
    limiter = limiter() |> record_many(5, @now - 1_000)

    assert {:allow, 59_000, _limiter} =
             RateLimiter.get_delay(limiter, @jid, "Overflow", @now)
  end

  test "hour limit uses the oldest timestamp even when records arrive out of order" do
    limiter =
      limiter(max_per_minute: 100, max_per_hour: 2)
      |> RateLimiter.inject_timestamps([@now - 1_000, @now - 2_000], @now)

    assert {:allow, 3_598_000, _limiter} =
             RateLimiter.get_delay(limiter, @jid, "Overflow", @now)
  end

  test "daily limit is a hard denial" do
    limiter = limiter(max_per_minute: 1_000, max_per_hour: 1_000, max_per_day: 3)
    limiter = record_many(limiter, 3, @now)

    assert {:deny, :rate_limit_day, _limiter} =
             RateLimiter.get_delay(limiter, @jid, "Overflow", @now)
  end

  test "burst messages use reduced delay and later messages use the full range" do
    limiter = limiter(new_chat_delay_ms: 0) |> RateLimiter.restore_known_chats([@jid])

    assert {:allow, burst_delay, limiter} = RateLimiter.get_delay(limiter, @jid, "", @now)
    assert burst_delay in 50..100
    limiter = RateLimiter.record(limiter, @jid, "one", @now)

    assert {:allow, second_delay, limiter} =
             RateLimiter.get_delay(limiter, @jid, "", @now + 100)

    assert second_delay in 50..100
    limiter = RateLimiter.record(limiter, @jid, "two", @now + 100)

    assert {:allow, third_burst_delay, limiter} =
             RateLimiter.get_delay(limiter, @jid, "", @now + 200)

    assert third_burst_delay in 50..100
    limiter = RateLimiter.record(limiter, @jid, "three", @now + 200)

    assert {:allow, normal_delay, _limiter} =
             RateLimiter.get_delay(limiter, @jid, "", @now + 300)

    assert normal_delay in 100..500
  end

  test "record resets burst accounting after more than 30 seconds of inactivity" do
    limiter = limiter(new_chat_delay_ms: 0) |> RateLimiter.restore_known_chats([@jid])
    {:allow, _delay, limiter} = RateLimiter.get_delay(limiter, @jid, "one", @now)
    limiter = RateLimiter.record(limiter, @jid, "one", @now)
    {:allow, _delay, limiter} = RateLimiter.get_delay(limiter, @jid, "two", @now + 1)
    limiter = RateLimiter.record(limiter, @jid, "two", @now + 1)
    {:allow, _delay, limiter} = RateLimiter.get_delay(limiter, @jid, "three", @now + 2)
    limiter = RateLimiter.record(limiter, @jid, "three", @now + 2)
    assert limiter.burst_count == 2

    limiter = RateLimiter.record(limiter, @jid, "after idle", @now + 31_002)
    assert limiter.burst_count == 0

    assert {:allow, _delay, limiter} =
             RateLimiter.get_delay(limiter, @jid, "next", @now + 31_003)

    assert limiter.burst_count == 1
  end

  test "a new chat receives the extra delay" do
    known = limiter() |> RateLimiter.restore_known_chats([@jid])
    fresh = limiter()

    {:allow, known_delay, _known} = RateLimiter.get_delay(known, @jid, "hello", @now)
    {:allow, fresh_delay, _fresh} = RateLimiter.get_delay(fresh, @jid, "hello", @now)
    assert fresh_delay > known_delay
  end

  test "minimum spacing is enforced relative to the last recorded message" do
    limiter = limiter(new_chat_delay_ms: 0) |> RateLimiter.restore_known_chats([@jid])
    limiter = RateLimiter.record(limiter, @jid, "one", @now)

    assert {:allow, delay, _limiter} =
             RateLimiter.get_delay(limiter, @jid, "", @now + 10)

    assert delay >= 90
  end

  test "identical messages block within the window and reset at its boundary" do
    limiter =
      Enum.reduce(1..3, limiter(max_per_minute: 100), fn _, limiter ->
        RateLimiter.record(limiter, @jid, "identical", @now)
      end)

    assert {:deny, :identical_message_limit, _limiter} =
             RateLimiter.get_delay(limiter, @jid, "identical", @now)

    assert {:allow, _delay, limiter} =
             RateLimiter.get_delay(limiter, @jid, "identical", @now + 3_600_000)

    limiter = RateLimiter.record(limiter, @jid, "identical", @now + 3_600_000)
    assert Enum.any?(limiter.identical_count, fn {_hash, tracker} -> tracker.count == 1 end)
  end

  test "cleanup expires day records and stale identical trackers" do
    limiter = RateLimiter.record(limiter(), @jid, "old", @now)
    {stats, limiter} = RateLimiter.stats(limiter, @now + 86_400_001)

    assert stats.last_day == 0
    assert limiter.messages == []
    assert limiter.identical_count == %{}
  end

  test "stats report counts, limits, known chats, and factor" do
    limiter =
      limiter()
      |> RateLimiter.record(@jid, "Message 1", @now)
      |> RateLimiter.record("chat2@s.whatsapp.net", "Message 2", @now)

    {stats, _limiter} = RateLimiter.stats(limiter, @now)
    assert stats.last_minute == 2
    assert stats.last_hour == 2
    assert stats.last_day == 2
    assert stats.known_chats == 2
    assert stats.limits == %{per_minute: 5, per_hour: 50, per_day: 500}
    assert stats.current_factor == 1.0
  end

  test "limit adaptation clamps factor, applies floors, and scales delay inversely" do
    throttled = limiter() |> RateLimiter.adapt_limits(0.01)
    assert throttled.config.max_per_minute == 1
    assert throttled.config.max_per_hour == 5
    assert throttled.config.max_per_day == 50
    assert throttled.config.min_delay_ms == 280
    assert throttled.config.max_delay_ms == 1_400
    assert RateLimiter.current_factor(throttled) == 0.2

    restored = RateLimiter.adapt_limits(throttled, 2.0)
    assert restored.config.max_per_minute == 5
    assert restored.config.min_delay_ms == 100
  end

  test "timestamp injection filters old values, deduplicates, sorts, and updates last time" do
    limiter = RateLimiter.record(limiter(), @jid, "existing", @now - 3_000)

    limiter =
      RateLimiter.inject_timestamps(
        limiter,
        [@now - 1_000, @now - 2_000, @now - 2_000, @now - 86_400_000],
        @now
      )

    assert Enum.map(limiter.messages, & &1.timestamp) ==
             [@now - 3_000, @now - 2_000, @now - 1_000]

    assert limiter.last_message_time == @now - 1_000
  end

  test "known chats restore without replacing existing entries" do
    limiter =
      limiter()
      |> RateLimiter.record(@jid, "one", @now)
      |> RateLimiter.restore_known_chats(["other@s.whatsapp.net", @jid])

    assert RateLimiter.known_chats(limiter) ==
             MapSet.new([@jid, "other@s.whatsapp.net"])
  end

  property "normal delay for an existing chat stays inside configured bounds" do
    check all(
            minimum <- integer(1..2_000),
            maximum <- integer(minimum..5_000),
            rand <- float(min: 0.01, max: 0.99)
          ) do
      limiter =
        RateLimiter.new(
          min_delay_ms: minimum,
          max_delay_ms: maximum,
          new_chat_delay_ms: 0,
          burst_allowance: 0,
          rand_fun: fn -> rand end
        )
        |> RateLimiter.restore_known_chats([@jid])

      assert {:allow, delay, _limiter} = RateLimiter.get_delay(limiter, @jid, "", @now)
      assert delay in minimum..maximum
    end
  end
end
