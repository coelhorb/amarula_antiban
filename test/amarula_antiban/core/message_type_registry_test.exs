defmodule AmarulaAntiban.Core.MessageTypeRegistryTest do
  use ExUnit.Case, async: true

  alias AmarulaAntiban.Core.MessageTypeRegistry
  alias AmarulaAntiban.Core.MessageTypeRegistry.{Definition, PreparedSend}

  @now 1_700_000_000_000
  @day 86_400_000

  defp registry do
    MessageTypeRegistry.new(rand_fun: fn -> 0.5 end)
  end

  defp register!(registry, name, definition) do
    assert {:ok, registry} =
             MessageTypeRegistry.register_message_type(registry, name, definition)

    registry
  end

  defp prepare!(registry, jid, content, options, now_ms \\ @now) do
    assert {:ok, %PreparedSend{} = prepared, registry} =
             MessageTypeRegistry.prepare_send(registry, jid, content, options, now_ms)

    {prepared, registry}
  end

  test "overview counts registered types, locked types, and pending messages" do
    registry = registry() |> register!("otp", priority: :critical)

    assert MessageTypeRegistry.overview(registry) == %{
             registered_types: 1,
             locked_types: 0,
             pending_messages: 0
           }

    {prepared, registry} = prepare!(registry, "1@s.whatsapp.net", %{}, type: "otp")
    registry = MessageTypeRegistry.record_sent(registry, prepared, "wamid.1", @now)

    assert MessageTypeRegistry.overview(registry) == %{
             registered_types: 1,
             locked_types: 1,
             pending_messages: 1
           }
  end

  test "default RNG and injected endpoints honor the upstream [0, 1) domain" do
    assert :erlang.fun_info(%MessageTypeRegistry{}.rand_fun, :name) ==
             {:name, :uniform_real}

    assert :erlang.fun_info(MessageTypeRegistry.new().rand_fun, :name) ==
             {:name, :uniform_real}

    for endpoint <- [0.0, 1.0] do
      registry =
        MessageTypeRegistry.new(rand_fun: fn -> endpoint end)
        |> register!("bulk", priority: :bulk, rate_limit_pool: "bulk")

      {prepared, _registry} =
        prepare!(registry, "new@s.whatsapp.net", %{text: ""}, %{type: "bulk"})

      # Bulk first-send heuristic is unchanged: burst 500..1_000 plus
      # new-chat jitter 1_500..3_000. RateLimiter clamps the injected sample.
      assert prepared.delay_ms in 2_000..4_000
    end
  end

  test "registration initializes optimistic stats and becomes immutable after prepare" do
    registry = register!(registry(), "receipt", priority: :critical)
    assert MessageTypeRegistry.get_stats(registry, "receipt").engagement_score == 100

    {_prepared, registry} =
      prepare!(registry, "1@s.whatsapp.net", %{text: "ok"}, %{type: "receipt"})

    assert {:error, :type_locked, ^registry} =
             MessageTypeRegistry.register_message_type(registry, "receipt", priority: :bulk)
  end

  test "unlocked re-registration resets stats exactly as upstream" do
    registry = register!(registry(), "notice", priority: :normal)
    registry = register!(registry, "notice", priority: :bulk)

    assert registry.types["notice"].priority == :bulk
    assert MessageTypeRegistry.get_stats(registry, "notice").sent == 0
  end

  test "critical provenance fields and legitimacy signals are enforced" do
    definition =
      Definition.new(
        priority: :critical,
        requires_provenance: [:user_action_id, :action_timestamp],
        legitimacy_signals: %{
          max_action_delta_ms: 5_000,
          min_engagement_score: 60,
          min_subscription_age_days: 2
        }
      )

    registry = register!(registry(), "critical", definition)

    assert {:error, {:provenance_required, "critical", _fields}, registry} =
             MessageTypeRegistry.prepare_send(
               registry,
               "1@s.whatsapp.net",
               %{text: "x"},
               %{type: "critical"},
               @now
             )

    assert MapSet.member?(registry.locked, "critical")

    assert {:error, {:provenance_field_required, "critical", :action_timestamp}, _registry} =
             MessageTypeRegistry.prepare_send(
               registry,
               "1@s.whatsapp.net",
               %{text: "x"},
               %{type: "critical", provenance: %{user_action_id: "a"}},
               @now
             )

    old = %{
      user_action_id: "a",
      action_timestamp: @now - 5_001,
      subscription_verified_at: @now - 3 * @day
    }

    assert {:error, {:max_action_delta_exceeded, "critical", 5_001, 5_000}, _registry} =
             MessageTypeRegistry.prepare_send(
               registry,
               "1@s.whatsapp.net",
               %{text: "x"},
               %{type: "critical", provenance: old, engagement_score: 80},
               @now
             )

    recent = %{old | action_timestamp: @now - 100}

    assert {:error, {:min_engagement_score_not_met, "critical", 59, 60}, _registry} =
             MessageTypeRegistry.prepare_send(
               registry,
               "1@s.whatsapp.net",
               %{text: "x"},
               %{type: "critical", provenance: recent, engagement_score: 59},
               @now
             )

    young = %{recent | subscription_verified_at: @now - @day}

    assert {:error, {:min_subscription_age_not_met, "critical", 1.0, 2}, _registry} =
             MessageTypeRegistry.prepare_send(
               registry,
               "1@s.whatsapp.net",
               %{text: "x"},
               %{type: "critical", provenance: young, engagement_score: 80},
               @now
             )

    assert {:ok, %PreparedSend{}, _registry} =
             MessageTypeRegistry.prepare_send(
               registry,
               "1@s.whatsapp.net",
               %{text: "x"},
               %{type: "critical", provenance: recent, engagement_score: 80},
               @now
             )
  end

  test "pool configs mirror upstream priority presets and first registration owns a shared pool" do
    registry = register!(registry(), "critical", priority: :critical, rate_limit_pool: "shared")
    registry = register!(registry, "bulk", priority: :bulk, rate_limit_pool: "shared")

    config = registry.pools["shared"].config
    assert config.max_per_minute == 5
    assert config.max_per_hour == 100
    assert config.max_per_day == 500
    assert config.min_delay_ms == 1_500
    assert config.max_delay_ms == 5_000

    bulk_only = register!(registry(), "bulk", priority: :bulk, rate_limit_pool: "bulk")
    bulk_config = bulk_only.pools["bulk"].config
    assert bulk_config.max_per_minute == 15
    assert bulk_config.max_per_hour == 300
    assert bulk_config.max_per_day == 2_000
    assert bulk_config.min_delay_ms == 1_000
    assert bulk_config.max_delay_ms == 3_000
  end

  test "pool delay is planned purely and identical content eventually hard-blocks" do
    registry = register!(registry(), "bulk", priority: :bulk, rate_limit_pool: "broadcasts")

    registry =
      Enum.reduce(1..3, registry, fn index, registry ->
        {prepared, registry} =
          prepare!(
            registry,
            "1@s.whatsapp.net",
            %{text: "same text"},
            %{type: "bulk"},
            @now + index
          )

        assert prepared.delay_ms >= 0
        MessageTypeRegistry.record_sent(registry, prepared, "m#{index}", @now + index)
      end)

    assert {:error, {:rate_limit_exceeded, "broadcasts", :identical_message_limit}, _registry} =
             MessageTypeRegistry.prepare_send(
               registry,
               "1@s.whatsapp.net",
               %{text: "same text"},
               %{type: "bulk"},
               @now + 4
             )
  end

  test "successful sends, delivery, read, reply, and unknown IDs update exact counters" do
    registry = register!(registry(), "chat", priority: :normal)
    provenance = %{action_timestamp: @now - 200}

    {prepared, registry} =
      prepare!(
        registry,
        "1@s.whatsapp.net",
        %{text: "hello"},
        %{type: "chat", provenance: provenance}
      )

    registry = MessageTypeRegistry.record_sent(registry, prepared, "m1", @now)
    stats = MessageTypeRegistry.get_stats(registry, "chat")
    assert stats.sent == 1
    assert stats.avg_action_delta_ms == 200

    registry = MessageTypeRegistry.record_delivered(registry, "m1")
    registry = MessageTypeRegistry.record_delivered(registry, "m1")
    assert MessageTypeRegistry.get_stats(registry, "chat").delivered == 1
    assert MessageTypeRegistry.get_stats(registry, "chat").engagement_score == 20

    registry = MessageTypeRegistry.record_read(registry, "m1")
    registry = MessageTypeRegistry.record_read(registry, "m1")
    assert MessageTypeRegistry.get_stats(registry, "chat").read == 1
    assert MessageTypeRegistry.get_stats(registry, "chat").engagement_score == 50

    registry = MessageTypeRegistry.record_replied(registry, "m1")
    stats = MessageTypeRegistry.get_stats(registry, "chat")
    assert %{sent: 1, delivered: 1, read: 1, replied: 1, engagement_score: 100} = stats
    refute Map.has_key?(registry.pending_messages, "m1")
    assert MessageTypeRegistry.record_read(registry, "unknown") == registry
  end

  test "blocked tracking uses only the strict five-minute pending window" do
    registry = register!(registry(), "notice", priority: :normal)
    {prepared, registry} = prepare!(registry, "1@s.whatsapp.net", %{}, %{type: "notice"})

    registry = MessageTypeRegistry.record_sent(registry, prepared, "recent", @now - 299_999)
    registry = MessageTypeRegistry.record_sent(registry, prepared, "boundary", @now - 300_000)
    registry = MessageTypeRegistry.record_blocked(registry, "1@s.whatsapp.net", @now)

    assert MessageTypeRegistry.get_stats(registry, "notice").blocked == 1
  end

  test "a block affects recent pending messages for only the reported recipient" do
    registry = register!(registry(), "notice", priority: :normal)

    {to_a, registry} =
      prepare!(registry, "a@s.whatsapp.net", %{}, %{type: "notice"})

    {to_b, registry} =
      prepare!(registry, "b@s.whatsapp.net", %{}, %{type: "notice"})

    registry = MessageTypeRegistry.record_sent(registry, to_a, "to-a", @now)
    registry = MessageTypeRegistry.record_sent(registry, to_b, "to-b", @now)

    assert registry.pending_messages["to-a"].jid == "a@s.whatsapp.net"
    assert registry.pending_messages["to-b"].jid == "b@s.whatsapp.net"

    registry = MessageTypeRegistry.record_blocked(registry, "a@s.whatsapp.net", @now)

    assert MessageTypeRegistry.get_stats(registry, "notice").blocked == 1
  end

  test "warnings reproduce engagement, delivery, blocked, and critical action thresholds" do
    registry = register!(registry(), "critical", priority: :critical)

    registry =
      Enum.reduce(1..20, registry, fn index, registry ->
        provenance = %{action_timestamp: @now - 6_000}

        {prepared, registry} =
          prepare!(
            registry,
            "target@s.whatsapp.net",
            %{text: "#{index}"},
            %{type: "critical", provenance: provenance}
          )

        MessageTypeRegistry.record_sent(registry, prepared, "m#{index}", @now)
      end)

    registry = MessageTypeRegistry.record_blocked(registry, "target@s.whatsapp.net", @now)
    {warnings, registry} = MessageTypeRegistry.warnings(registry, @now)

    assert MapSet.new(Enum.map(warnings, & &1.metric)) ==
             MapSet.new([:engagement, :delivery_rate, :blocked_rate, :action_delta])

    assert MessageTypeRegistry.get_stats(registry, "critical").last_warning_at == @now
  end

  test "warning generation never changes pool limits" do
    registry = register!(registry(), "bulk", priority: :bulk, rate_limit_pool: "bulk")
    config = registry.pools["bulk"].config
    {_warnings, registry} = MessageTypeRegistry.warnings(registry, @now)
    assert registry.pools["bulk"].config == config
  end

  test "cleanup expires pending only after 24 hours" do
    registry = register!(registry(), "notice", priority: :normal)
    {prepared, registry} = prepare!(registry, "1@s.whatsapp.net", %{}, %{type: "notice"})
    registry = MessageTypeRegistry.record_sent(registry, prepared, "old", @now - @day - 1)
    registry = MessageTypeRegistry.record_sent(registry, prepared, "boundary", @now - @day)
    registry = MessageTypeRegistry.cleanup(registry, @now)

    refute Map.has_key?(registry.pending_messages, "old")
    assert Map.has_key?(registry.pending_messages, "boundary")
  end

  test "export/import survives JSON and recreates definitions, stats, pending, locks, and pools" do
    registry =
      register!(registry(), "critical",
        priority: :critical,
        rate_limit_pool: "critical",
        requires_provenance: [:user_action_id],
        legitimacy_signals: %{max_action_delta_ms: 5_000},
        delivery_guarantee: :at_least_once,
        engagement_tracking: %{expect_reply: true}
      )

    {prepared, registry} =
      prepare!(
        registry,
        "1@s.whatsapp.net",
        %{text: "ok"},
        %{type: "critical", provenance: %{user_action_id: "a"}}
      )

    registry = MessageTypeRegistry.record_sent(registry, prepared, "m1", @now)
    registry = MessageTypeRegistry.record_delivered(registry, "m1")
    registry = MessageTypeRegistry.record_read(registry, "m1")

    imported =
      registry
      |> MessageTypeRegistry.export_state()
      |> Jason.encode!()
      |> Jason.decode!()
      |> MessageTypeRegistry.import_state(rand_fun: fn -> 0.5 end)

    assert imported.types["critical"].priority == :critical
    assert imported.types["critical"].delivery_guarantee == :at_least_once
    assert imported.types["critical"].legitimacy_signals.max_action_delta_ms == 5_000
    assert imported.types["critical"].engagement_tracking.expect_reply
    assert MessageTypeRegistry.get_stats(imported, "critical").sent == 1
    assert MessageTypeRegistry.get_stats(imported, "critical").delivered == 1
    assert MessageTypeRegistry.get_stats(imported, "critical").read == 1
    assert imported.pending_messages["m1"].type == "critical"
    assert imported.pending_messages["m1"].jid == "1@s.whatsapp.net"
    assert imported.pending_messages["m1"].delivered
    assert imported.pending_messages["m1"].read
    assert MapSet.member?(imported.locked, "critical")
    assert imported.pools["critical"].config.max_per_minute == 5

    imported = MessageTypeRegistry.record_delivered(imported, "m1")
    imported = MessageTypeRegistry.record_read(imported, "m1")
    assert MessageTypeRegistry.get_stats(imported, "critical").delivered == 1
    assert MessageTypeRegistry.get_stats(imported, "critical").read == 1
  end

  test "legacy JSON snapshots without jid or receipt flags remain importable" do
    registry = register!(registry(), "notice", priority: :normal)
    {prepared, registry} = prepare!(registry, "1@s.whatsapp.net", %{}, %{type: "notice"})
    registry = MessageTypeRegistry.record_sent(registry, prepared, "legacy", @now)

    legacy_state =
      registry
      |> MessageTypeRegistry.export_state()
      |> Jason.encode!()
      |> Jason.decode!()
      |> update_in(["pending_messages", "legacy"], fn pending ->
        Map.drop(pending, ["jid", "delivered", "read"])
      end)

    imported = MessageTypeRegistry.import_state(legacy_state)
    assert imported.pending_messages["legacy"].jid == nil
    refute imported.pending_messages["legacy"].delivered
    refute imported.pending_messages["legacy"].read

    imported = MessageTypeRegistry.record_blocked(imported, "1@s.whatsapp.net", @now)
    assert MessageTypeRegistry.get_stats(imported, "notice").blocked == 0

    imported = MessageTypeRegistry.record_delivered(imported, "legacy")
    imported = MessageTypeRegistry.record_delivered(imported, "legacy")
    assert MessageTypeRegistry.get_stats(imported, "notice").delivered == 1
  end
end
