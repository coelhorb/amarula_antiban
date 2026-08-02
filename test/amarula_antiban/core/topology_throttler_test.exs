defmodule AmarulaAntiban.Core.TopologyThrottlerTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.TopologyThrottler

  @now 1_700_000_000_000
  @jid "new@s.whatsapp.net"

  test "disabled config always allows immediately and never tracks" do
    throttler = TopologyThrottler.new([enabled: false], @now)
    assert {:allow, :send, 0, throttler} = TopologyThrottler.before_send(throttler, @jid, @now)
    throttler = TopologyThrottler.record_sent(throttler, @jid, @now)
    assert throttler.contacts == %{}
  end

  test "first contact scores first-contact + no-mutual-groups penalties and recommends delay" do
    throttler = TopologyThrottler.new([enabled: true], @now)

    assert {:allow, :delay, 60_000, _throttler} =
             TopologyThrottler.before_send(throttler, @jid, @now)
  end

  test "recording a send registers the contact and increments hour/day counters" do
    throttler =
      TopologyThrottler.new([enabled: true], @now) |> TopologyThrottler.record_sent(@jid, @now)

    assert throttler.new_contacts_this_hour == 1
    assert throttler.new_contacts_today == 1
    assert %{send_timestamps: [@now]} = throttler.contacts[@jid]

    throttler = TopologyThrottler.record_sent(throttler, @jid, @now + 1)
    assert throttler.new_contacts_this_hour == 1
    assert %{send_timestamps: [_, _]} = throttler.contacts[@jid]
  end

  test "known contact with no reply scores the no-reply penalty and recommends send" do
    throttler =
      TopologyThrottler.new([enabled: true], @now) |> TopologyThrottler.record_sent(@jid, @now)

    assert {:allow, :send, 0, _throttler} = TopologyThrottler.before_send(throttler, @jid, @now)
  end

  test "known contact who replied clamps score to zero and recommends send" do
    throttler =
      TopologyThrottler.new([enabled: true], @now)
      |> TopologyThrottler.record_sent(@jid, @now)
      |> TopologyThrottler.record_replied(@jid, @now)

    assert {:allow, :send, 0, _throttler} = TopologyThrottler.before_send(throttler, @jid, @now)
  end

  test "recording a reply for an unknown contact is a no-op" do
    throttler = TopologyThrottler.new([enabled: true], @now)
    assert TopologyThrottler.record_replied(throttler, @jid, @now) == throttler
  end

  test "hourly new-contact limit denies and starts a cooldown" do
    throttler =
      TopologyThrottler.new([enabled: true, max_new_contacts_per_hour: 1], @now)
      |> TopologyThrottler.record_sent("a@s.whatsapp.net", @now)

    assert {:deny, reason, throttler} =
             TopologyThrottler.before_send(throttler, "b@s.whatsapp.net", @now)

    assert reason =~ "Hourly new contact limit"
    assert throttler.limit_hit_at == @now

    assert {:deny, reason, _throttler} =
             TopologyThrottler.before_send(throttler, "c@s.whatsapp.net", @now + 1)

    assert reason =~ "Cooldown active"
  end

  test "daily new-contact limit denies once the hourly limit is not the blocker" do
    throttler =
      TopologyThrottler.new(
        [enabled: true, max_new_contacts_per_hour: 100, max_new_contacts_per_day: 1],
        @now
      )
      |> TopologyThrottler.record_sent("a@s.whatsapp.net", @now)

    assert {:deny, reason, _throttler} =
             TopologyThrottler.before_send(throttler, "b@s.whatsapp.net", @now)

    assert reason =~ "Daily new contact limit"
  end

  test "low reply ratio blocks further cold outreach to new contacts only" do
    throttler =
      TopologyThrottler.new(
        [
          enabled: true,
          max_new_contacts_per_hour: 100,
          max_new_contacts_per_day: 100,
          min_reply_ratio_for_new_contacts: 0.5
        ],
        @now
      )
      |> TopologyThrottler.record_sent("known@s.whatsapp.net", @now)
      |> TopologyThrottler.record_sent("known@s.whatsapp.net", @now)

    assert {:deny, reason, _throttler} = TopologyThrottler.before_send(throttler, @jid, @now)
    assert reason =~ "Reply ratio too low"

    # Known contacts skip the gate entirely, even with a poor reply ratio.
    assert {:allow, _recommendation, _delay_ms, _throttler} =
             TopologyThrottler.before_send(throttler, "known@s.whatsapp.net", @now)
  end

  test "hourly counter and cooldown both clear once their windows elapse" do
    throttler =
      TopologyThrottler.new(
        [enabled: true, max_new_contacts_per_hour: 1, min_reply_ratio_for_new_contacts: 0],
        @now
      )
      |> TopologyThrottler.record_sent("a@s.whatsapp.net", @now)

    assert {:deny, _reason, throttler} =
             TopologyThrottler.before_send(throttler, "b@s.whatsapp.net", @now)

    assert {:allow, _recommendation, _delay_ms, _throttler} =
             TopologyThrottler.before_send(throttler, "b@s.whatsapp.net", @now + 3_600_001)
  end

  test "record_blocked marks a known contact and is a no-op for unknown ones" do
    throttler =
      TopologyThrottler.new([enabled: true], @now) |> TopologyThrottler.record_sent(@jid, @now)

    throttler = TopologyThrottler.record_blocked(throttler, @jid)
    assert throttler.contacts[@jid].blocked == true

    unknown = TopologyThrottler.new([enabled: true], @now)
    assert TopologyThrottler.record_blocked(unknown, @jid) == unknown
  end

  test "stats reports rolling counters, reply ratio, cooldown and tracked contacts" do
    throttler =
      TopologyThrottler.new([enabled: true, max_new_contacts_per_hour: 1], @now)
      |> TopologyThrottler.record_sent("a@s.whatsapp.net", @now)
      |> TopologyThrottler.record_replied("a@s.whatsapp.net", @now)

    {stats, throttler} = TopologyThrottler.stats(throttler, @now)
    assert stats.new_contacts_this_hour == 1
    assert stats.new_contacts_today == 1
    assert stats.reply_ratio == 1.0
    assert stats.cooldown_remaining_ms == nil
    assert stats.tracked_contacts == 1

    {:deny, _reason, throttler} =
      TopologyThrottler.before_send(throttler, "b@s.whatsapp.net", @now)

    {stats, _throttler} = TopologyThrottler.stats(throttler, @now + 1)
    assert stats.cooldown_remaining_ms == 3_600_000 - 1
  end

  test "restores the real JSON round-trip with contact records intact" do
    throttler =
      TopologyThrottler.new([enabled: true, max_new_contacts_per_hour: 1], @now)
      |> TopologyThrottler.record_sent(@jid, @now)
      |> TopologyThrottler.record_replied(@jid, @now)

    {:deny, _reason, throttler} =
      TopologyThrottler.before_send(throttler, "other@s.whatsapp.net", @now)

    persisted = throttler |> TopologyThrottler.export() |> Jason.encode!() |> Jason.decode!()
    restored = TopologyThrottler.restore(TopologyThrottler.new([enabled: true], @now), persisted)

    assert restored.contacts[@jid] == %{
             first_contact_at: @now,
             send_timestamps: [@now],
             reply_timestamps: [@now],
             blocked: false
           }

    assert restored.new_contacts_this_hour == 1
    assert restored.new_contacts_today == 1
    assert restored.limit_hit_at == @now
  end

  test "restore normalizes malformed persisted collections defensively" do
    restored =
      TopologyThrottler.restore(TopologyThrottler.new([enabled: true], @now), %{
        "contacts" => %{
          "ok@s.whatsapp.net" => %{
            "first_contact_at" => @now,
            "send_timestamps" => [@now, "garbage"],
            "reply_timestamps" => "not-a-list",
            "blocked" => "not-a-boolean"
          }
        },
        "limit_hit_at" => "not-an-integer"
      })

    assert restored.contacts["ok@s.whatsapp.net"] == %{
             first_contact_at: @now,
             send_timestamps: [@now],
             reply_timestamps: [],
             blocked: false
           }

    assert restored.limit_hit_at == nil

    malformed = TopologyThrottler.restore(restored, %{"contacts" => "not-a-map"})
    assert malformed.contacts == %{}
  end
end
