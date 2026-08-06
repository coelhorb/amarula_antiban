defmodule AmarulaAntiban.Core.HumanEntropyTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.HumanEntropy

  @now 1_700_000_000_000

  test "disabled core never rolls actions" do
    entropy = HumanEntropy.new()
    assert HumanEntropy.roll_cycle(entropy) == []
  end

  test "track_incoming dedups by jid and keeps the most recent last_message_at" do
    entropy = HumanEntropy.new(enabled: true)

    entropy =
      entropy
      |> HumanEntropy.track_incoming("a@s.whatsapp.net", @now)
      |> HumanEntropy.track_incoming("b@s.whatsapp.net", @now + 1)
      |> HumanEntropy.track_incoming("a@s.whatsapp.net", @now + 2)

    assert entropy.recent_contacts == [
             %{jid: "a@s.whatsapp.net", last_message_at: @now + 2},
             %{jid: "b@s.whatsapp.net", last_message_at: @now + 1}
           ]
  end

  test "track_incoming trims to max_recent_contacts, keeping the most recent" do
    entropy = HumanEntropy.new(enabled: true, max_recent_contacts: 2)

    entropy =
      Enum.reduce(1..3, entropy, fn i, entropy ->
        HumanEntropy.track_incoming(entropy, "#{i}@s.whatsapp.net", @now + i)
      end)

    assert entropy.recent_contacts == [
             %{jid: "3@s.whatsapp.net", last_message_at: @now + 3},
             %{jid: "2@s.whatsapp.net", last_message_at: @now + 2}
           ]
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
    entropy = HumanEntropy.new(enabled: true, typing_probability: 1.0, rand_fun: fn -> 0.0 end)
    assert HumanEntropy.roll_cycle(entropy) == [{:presence_toggle, 30_000}]
  end

  test "roll_cycle can fire both actions in the same cycle" do
    entropy =
      HumanEntropy.new(
        enabled: true,
        typing_probability: 1.0,
        presence_toggle_probability: 1.0,
        rand_fun: fn -> 0.0 end
      )

    entropy = HumanEntropy.track_incoming(entropy, "a@s.whatsapp.net", @now)

    assert HumanEntropy.roll_cycle(entropy) == [
             {:typing, "a@s.whatsapp.net", 3_000},
             {:presence_toggle, 30_000}
           ]
  end

  test "roll_cycle rolls neither action when both probabilities miss" do
    entropy =
      HumanEntropy.new(enabled: true, typing_probability: 0.1, presence_toggle_probability: 0.1)

    entropy =
      %{entropy | config: %{entropy.config | rand_fun: fn -> 0.5 end}}
      |> HumanEntropy.track_incoming("a@s.whatsapp.net", @now)

    assert HumanEntropy.roll_cycle(entropy) == []
  end

  test "typing picks a contact using the injected RNG" do
    entropy =
      HumanEntropy.new(enabled: true, typing_probability: 1.0, rand_fun: fn -> 0.5 end)

    entropy =
      Enum.reduce(["a", "b", "c"], entropy, fn jid, entropy ->
        HumanEntropy.track_incoming(entropy, "#{jid}@s.whatsapp.net", @now)
      end)

    assert [{:typing, jid, _duration}] = HumanEntropy.roll_cycle(entropy)
    assert jid == "b@s.whatsapp.net"
  end

  test "record_cycle counts actions and always bumps cycles_run" do
    entropy = HumanEntropy.new(enabled: true)
    entropy = HumanEntropy.record_cycle(entropy, [{:typing, "a@s.whatsapp.net", 3_000}])
    assert HumanEntropy.stats(entropy) == %{cycles_run: 1, typing_events: 1, presence_toggles: 0}

    entropy = HumanEntropy.record_cycle(entropy, [{:presence_toggle, 30_000}])
    assert HumanEntropy.stats(entropy) == %{cycles_run: 2, typing_events: 1, presence_toggles: 1}

    entropy = HumanEntropy.record_cycle(entropy, [])
    assert HumanEntropy.stats(entropy) == %{cycles_run: 3, typing_events: 1, presence_toggles: 1}
  end
end
