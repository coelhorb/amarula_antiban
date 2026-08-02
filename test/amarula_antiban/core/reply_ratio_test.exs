defmodule AmarulaAntiban.Core.ReplyRatioTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.ReplyRatio

  @now 1_700_000_000_000
  @jid "contact@s.whatsapp.net"

  test "disabled guard is inert" do
    ratio = ReplyRatio.new()
    assert {:allow, ^ratio} = ReplyRatio.before_send(ratio, @jid, @now)
    assert ReplyRatio.record_sent(ratio, @jid) == ratio
    assert {:none, ^ratio} = ReplyRatio.suggest_reply(ratio, @jid)
  end

  test "enforces the exact ratio floor and cooldown" do
    ratio =
      ReplyRatio.new(
        enabled: true,
        min_messages_before_enforce: 2,
        cooldown_hours_on_violation: 2
      )

    ratio = ratio |> ReplyRatio.record_sent(@jid) |> ReplyRatio.record_sent(@jid)

    assert {:deny, reason, ratio} = ReplyRatio.before_send(ratio, @jid, @now)
    assert reason =~ "0.0% < 10.0%"
    assert ratio.contacts[@jid].cooled_until == @now + 7_200_000
    assert {:deny, cooldown, ^ratio} = ReplyRatio.before_send(ratio, @jid, @now + 1)
    assert cooldown =~ "Retry in 2h"

    ratio = ReplyRatio.record_received(ratio, @jid)
    refute Map.has_key?(ratio.contacts[@jid], :cooled_until)
    assert {:allow, ^ratio} = ReplyRatio.before_send(ratio, @jid, @now + 1)
  end

  test "individual scope skips groups" do
    ratio = ReplyRatio.new(enabled: true, min_messages_before_enforce: 1)
    ratio = ReplyRatio.record_sent(ratio, "group@g.us")
    assert {:allow, ^ratio} = ReplyRatio.before_send(ratio, "group@g.us", @now)
    assert {:none, ^ratio} = ReplyRatio.suggest_reply(ratio, "group@g.us")
  end

  test "suggestion probability and template selection use injected RNG" do
    ratio =
      ReplyRatio.new(
        enabled: true,
        inbound_auto_reply_probability: 0.5,
        auto_reply_templates: ["a", "b"],
        rand_fun: fn -> 0.25 end
      )

    assert {{:reply, "a"}, ^ratio} = ReplyRatio.suggest_reply(ratio, @jid)

    assert {:none, _ratio} =
             ReplyRatio.suggest_reply(
               %{ratio | config: %{ratio.config | rand_fun: fn -> 0.8 end}},
               @jid
             )
  end

  test "stats, persistence, and reset preserve exact counts" do
    ratio =
      ReplyRatio.new(enabled: true)
      |> ReplyRatio.record_sent(@jid)
      |> ReplyRatio.record_received(@jid)
      |> ReplyRatio.record_received("inbound-only@s.whatsapp.net")

    stats = ReplyRatio.stats(ratio, @now)
    assert stats.global_sent == 1
    assert stats.global_received == 2
    assert stats.global_ratio == 2.0

    restored = ReplyRatio.restore(ReplyRatio.new(enabled: true), ReplyRatio.export(ratio))
    assert restored.contacts == ratio.contacts
    assert ReplyRatio.reset(restored).contacts == %{}
  end

  test "restores cooldowns and counters after a real JSON round-trip" do
    ratio = ReplyRatio.new(enabled: true, min_messages_before_enforce: 1)
    ratio = ReplyRatio.record_sent(ratio, @jid)
    assert {:deny, _reason, ratio} = ReplyRatio.before_send(ratio, @jid, @now)

    persisted = ratio |> ReplyRatio.export() |> Jason.encode!() |> Jason.decode!()
    restored = ReplyRatio.restore(ReplyRatio.new(enabled: true), persisted)

    assert restored.contacts[@jid] == ratio.contacts[@jid]
    assert {:deny, reason, ^restored} = ReplyRatio.before_send(restored, @jid, @now + 1)
    assert reason =~ "Reply ratio cooldown"
  end

  test "normalizes injected RNG endpoints to Math.random domain" do
    assert :erlang.fun_info(ReplyRatio.new().config.rand_fun, :name) ==
             {:name, :uniform_real}

    options = [
      enabled: true,
      inbound_auto_reply_probability: 1.0,
      auto_reply_templates: ["first", "last"]
    ]

    first = ReplyRatio.new(Keyword.put(options, :rand_fun, fn -> 0.0 end))
    last = ReplyRatio.new(Keyword.put(options, :rand_fun, fn -> 1.0 end))

    assert {{:reply, "first"}, ^first} = ReplyRatio.suggest_reply(first, @jid)
    assert {{:reply, "last"}, ^last} = ReplyRatio.suggest_reply(last, @jid)
  end
end
