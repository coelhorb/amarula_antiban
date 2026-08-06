defmodule AmarulaAntiban.Core.HumanEntropyTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.HumanEntropy

  @now 1_700_000_000_000

  test "disabled core never rolls actions" do
    entropy = HumanEntropy.new()
    assert HumanEntropy.roll_cycle(entropy, @now) == []
  end

  test "track_incoming dedups by jid and keeps the most recent last_message_at" do
    entropy = HumanEntropy.new(enabled: true)

    entropy =
      entropy
      |> HumanEntropy.track_incoming("a@s.whatsapp.net", nil, @now)
      |> HumanEntropy.track_incoming("b@s.whatsapp.net", nil, @now + 1)
      |> HumanEntropy.track_incoming("a@s.whatsapp.net", nil, @now + 2)

    assert entropy.recent_contacts == [
             %{jid: "a@s.whatsapp.net", last_message_at: @now + 2, pending_message_ids: []},
             %{jid: "b@s.whatsapp.net", last_message_at: @now + 1, pending_message_ids: []}
           ]
  end

  test "track_incoming trims to max_recent_contacts, keeping the most recent" do
    entropy = HumanEntropy.new(enabled: true, max_recent_contacts: 2)

    entropy =
      Enum.reduce(1..3, entropy, fn i, entropy ->
        HumanEntropy.track_incoming(entropy, "#{i}@s.whatsapp.net", nil, @now + i)
      end)

    assert entropy.recent_contacts == [
             %{jid: "3@s.whatsapp.net", last_message_at: @now + 3, pending_message_ids: []},
             %{jid: "2@s.whatsapp.net", last_message_at: @now + 2, pending_message_ids: []}
           ]
  end

  test "track_incoming queues pending message ids per contact, deduped and capped" do
    entropy = HumanEntropy.new(enabled: true, max_pending_reads_per_contact: 2)

    entropy =
      entropy
      |> HumanEntropy.track_incoming("a@s.whatsapp.net", "MSG1", @now)
      |> HumanEntropy.track_incoming("a@s.whatsapp.net", "MSG2", @now + 1)
      |> HumanEntropy.track_incoming("a@s.whatsapp.net", "MSG3", @now + 2)

    assert [%{pending_message_ids: ["MSG3", "MSG2"]}] = entropy.recent_contacts
  end

  test "next_delay_ms is uniform within the configured bounds" do
    entropy =
      HumanEntropy.new(
        enabled: true,
        min_interval_ms: 1_000,
        max_interval_ms: 2_000,
        rand_fun: fn -> 0.0 end
      )

    assert HumanEntropy.next_delay_ms(entropy) == 1_000

    entropy = %{entropy | config: %{entropy.config | rand_fun: fn -> 0.999_999 end}}
    assert HumanEntropy.next_delay_ms(entropy) == 2_000
  end

  test "roll_cycle never rolls typing without a tracked contact" do
    entropy =
      HumanEntropy.new(
        enabled: true,
        typing_probability: 1.0,
        read_receipt_probability: 0.0,
        rand_fun: fn -> 0.0 end
      )

    assert HumanEntropy.roll_cycle(entropy, @now) == [{:presence_toggle, 30_000}]
  end

  test "roll_cycle can fire all three actions in the same cycle" do
    entropy =
      HumanEntropy.new(
        [
          enabled: true,
          typing_probability: 1.0,
          presence_toggle_probability: 1.0,
          read_receipt_probability: 1.0,
          rand_fun: fn -> 0.0 end
        ],
        rand_fun: fn -> 0.0 end
      )

    entropy = HumanEntropy.track_incoming(entropy, "a@s.whatsapp.net", "MSG1", @now)

    assert [
             {:typing, "a@s.whatsapp.net", 3_000},
             {:presence_toggle, 30_000},
             {:read_receipt, "a@s.whatsapp.net", ["MSG1"], delay_ms}
           ] = HumanEntropy.roll_cycle(entropy, @now)

    assert delay_ms > 0
  end

  test "roll_cycle rolls no action when every probability misses" do
    entropy =
      HumanEntropy.new(
        enabled: true,
        typing_probability: 0.1,
        presence_toggle_probability: 0.1,
        read_receipt_probability: 0.1
      )

    entropy =
      %{entropy | config: %{entropy.config | rand_fun: fn -> 0.5 end}}
      |> HumanEntropy.track_incoming("a@s.whatsapp.net", "MSG1", @now)

    assert HumanEntropy.roll_cycle(entropy, @now) == []
  end

  test "typing picks a contact using the injected RNG" do
    entropy =
      HumanEntropy.new(enabled: true, typing_probability: 1.0, rand_fun: fn -> 0.5 end)

    entropy =
      Enum.reduce(["a", "b", "c"], entropy, fn jid, entropy ->
        HumanEntropy.track_incoming(entropy, "#{jid}@s.whatsapp.net", nil, @now)
      end)

    assert [{:typing, jid, _duration} | _rest] = HumanEntropy.roll_cycle(entropy, @now)
    assert jid == "b@s.whatsapp.net"
  end

  test "read_receipt has no candidates when no tracked contact has pending messages" do
    entropy =
      HumanEntropy.new(
        enabled: true,
        typing_probability: 0.0,
        presence_toggle_probability: 0.0,
        read_receipt_probability: 1.0,
        rand_fun: fn -> 0.0 end
      )

    entropy = HumanEntropy.track_incoming(entropy, "a@s.whatsapp.net", nil, @now)
    assert HumanEntropy.roll_cycle(entropy, @now) == []
  end

  test "read_receipt skips the artificial delay once the whole backlog is old" do
    entropy =
      HumanEntropy.new(
        [
          enabled: true,
          typing_probability: 0.0,
          presence_toggle_probability: 0.0,
          read_receipt_probability: 1.0,
          rand_fun: fn -> 0.0 end
        ],
        skip_if_older_than_ms: 60_000
      )

    entropy = HumanEntropy.track_incoming(entropy, "a@s.whatsapp.net", "MSG1", @now)

    assert [{:read_receipt, "a@s.whatsapp.net", ["MSG1"], 0}] =
             HumanEntropy.roll_cycle(entropy, @now + 120_000)
  end

  test "record_cycle counts actions, always bumps cycles_run, and clears a read contact's backlog" do
    entropy = HumanEntropy.new(enabled: true)
    entropy = HumanEntropy.track_incoming(entropy, "a@s.whatsapp.net", "MSG1", @now)

    entropy = HumanEntropy.record_cycle(entropy, [{:typing, "a@s.whatsapp.net", 3_000}])

    assert HumanEntropy.stats(entropy) ==
             %{cycles_run: 1, typing_events: 1, presence_toggles: 0, read_receipts_sent: 0}

    entropy = HumanEntropy.record_cycle(entropy, [{:presence_toggle, 30_000}])

    assert HumanEntropy.stats(entropy) ==
             %{cycles_run: 2, typing_events: 1, presence_toggles: 1, read_receipts_sent: 0}

    entropy =
      HumanEntropy.record_cycle(entropy, [
        {:read_receipt, "a@s.whatsapp.net", ["MSG1"], 500}
      ])

    assert HumanEntropy.stats(entropy) ==
             %{cycles_run: 3, typing_events: 1, presence_toggles: 1, read_receipts_sent: 1}

    assert [%{pending_message_ids: []}] = entropy.recent_contacts

    entropy = HumanEntropy.record_cycle(entropy, [])

    assert HumanEntropy.stats(entropy) ==
             %{cycles_run: 4, typing_events: 1, presence_toggles: 1, read_receipts_sent: 1}
  end

  test "export/restore round-trips recent_contacts (with pending reads) and stats" do
    entropy = HumanEntropy.new(enabled: true)

    entropy =
      entropy
      |> HumanEntropy.track_incoming("a@s.whatsapp.net", "MSG1", @now)
      |> HumanEntropy.record_cycle([{:typing, "a@s.whatsapp.net", 3_000}])

    exported = HumanEntropy.export(entropy)

    fresh = HumanEntropy.new(enabled: true)
    restored = HumanEntropy.restore(fresh, exported)

    assert restored.recent_contacts == entropy.recent_contacts
    assert HumanEntropy.stats(restored) == HumanEntropy.stats(entropy)
  end

  test "restore tolerates a missing or malformed payload" do
    entropy = HumanEntropy.new(enabled: true)
    assert HumanEntropy.restore(entropy, %{}) == entropy
    assert HumanEntropy.restore(entropy, %{recent_contacts: "garbage"}).recent_contacts == []
  end
end
