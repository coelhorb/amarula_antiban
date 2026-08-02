defmodule AmarulaAntiban.Core.ContactGraphTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.ContactGraph

  @now 1_700_000_000_000
  @jid "new@s.whatsapp.net"

  test "stranger quota resets on a new UTC day" do
    graph = ContactGraph.new([enabled: true, max_stranger_messages_per_day: 1], @now)
    assert {:allow, true, graph} = ContactGraph.can_message(graph, @jid, @now)

    assert {:deny, reason, true, ^graph} =
             ContactGraph.can_message(graph, "other@s.whatsapp.net", @now)

    assert reason =~ "Daily new-contact limit"

    assert {:allow, true, graph} =
             ContactGraph.can_message(graph, "other@s.whatsapp.net", @now + 86_400_000)

    assert graph.stranger_messages_today == 1
  end

  test "handshake state enforces exact minimum delay" do
    graph = ContactGraph.new([enabled: true, handshake_min_delay_ms: 60_000], @now)
    graph = ContactGraph.mark_handshake_sent(graph, @jid, @now)
    assert ContactGraph.contact_state(graph, @jid) == :handshake_sent
    assert {:deny, reason, false, ^graph} = ContactGraph.can_message(graph, @jid, @now + 1)
    assert reason =~ "wait 1 minutes"
    assert {:allow, false, ^graph} = ContactGraph.can_message(graph, @jid, @now + 60_000)

    graph = ContactGraph.mark_handshake_complete(graph, @jid)
    assert ContactGraph.contact_state(graph, @jid) == :handshake_complete
    graph = ContactGraph.register_known_contact(graph, @jid)
    assert ContactGraph.contact_state(graph, @jid) == :known
  end

  test "group lurk applies only to explicitly registered joins" do
    group = "new@g.us"
    graph = ContactGraph.new([enabled: true, group_lurk_period_ms: 120_000], @now)
    assert {:allow, false, ^graph} = ContactGraph.can_message(graph, group, @now)
    graph = ContactGraph.register_group_join(graph, group, @now)
    assert {:deny, reason, false, ^graph} = ContactGraph.can_message(graph, group, @now + 1)
    assert reason =~ "wait 2 minutes"
    assert {:allow, false, ^graph} = ContactGraph.can_message(graph, group, @now + 120_000)
    assert ContactGraph.contact_state(graph, group) == :known
  end

  test "incoming auto-registration, stats, export, restore and reset" do
    graph =
      ContactGraph.new([enabled: true], @now) |> ContactGraph.mark_handshake_sent(@jid, @now)

    graph = ContactGraph.incoming(graph, @jid) |> ContactGraph.register_group_join("g@g.us", @now)
    stats = ContactGraph.stats(graph)
    assert stats.known_contacts == 1
    assert stats.pending_handshakes == 0
    assert [%{first_send_unlocks_at: unlock}] = stats.groups_joined
    assert unlock == @now + 43_200_000

    restored =
      ContactGraph.restore(ContactGraph.new([enabled: true], @now), ContactGraph.export(graph))

    assert restored.contacts == graph.contacts
    reset = ContactGraph.reset(restored, @now + 86_400_000)
    assert reset.contacts == %{}
    assert reset.groups == %{}
  end

  test "restores the real JSON round-trip with enum and nested keys normalized" do
    graph =
      ContactGraph.new([enabled: true, max_stranger_messages_per_day: 1], @now)
      |> ContactGraph.mark_handshake_sent(@jid, @now)
      |> ContactGraph.register_known_contact("known@s.whatsapp.net")
      |> ContactGraph.register_group_join("fresh@g.us", @now)

    assert {:allow, true, graph} =
             ContactGraph.can_message(graph, "stranger@s.whatsapp.net", @now)

    persisted = graph |> ContactGraph.export() |> Jason.encode!() |> Jason.decode!()

    restored =
      ContactGraph.restore(
        ContactGraph.new([enabled: true, max_stranger_messages_per_day: 1], @now),
        persisted
      )

    assert restored.contacts[@jid] == %{state: :handshake_sent, handshake_sent_at: @now}
    assert restored.contacts["known@s.whatsapp.net"] == %{state: :known}
    assert restored.groups["fresh@g.us"] == %{joined_at: @now}
    assert restored.stranger_messages_today == 1

    assert {:deny, _reason, true, ^restored} =
             ContactGraph.can_message(restored, "another@s.whatsapp.net", @now)

    assert {:deny, _reason, false, ^restored} =
             ContactGraph.can_message(restored, "fresh@g.us", @now)
  end

  test "restore normalizes every persisted state and rejects malformed collections" do
    restored =
      ContactGraph.restore(ContactGraph.new([enabled: true], @now), %{
        "contacts" => %{
          "stranger@s.whatsapp.net" => %{"state" => "stranger"},
          "complete@s.whatsapp.net" => %{"state" => "handshake_complete"},
          "atom@s.whatsapp.net" => %{state: :handshake_sent, handshake_sent_at: @now},
          "invalid@s.whatsapp.net" => %{"state" => "invalid"}
        },
        "groups" => "malformed"
      })

    assert restored.contacts["stranger@s.whatsapp.net"].state == :stranger
    assert restored.contacts["complete@s.whatsapp.net"].state == :handshake_complete
    assert restored.contacts["atom@s.whatsapp.net"].state == :handshake_sent
    assert restored.contacts["invalid@s.whatsapp.net"].state == :stranger
    assert restored.groups == %{}

    malformed = ContactGraph.restore(restored, %{"contacts" => [], "groups" => %{}})
    assert malformed.contacts == %{}
  end
end
