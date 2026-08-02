defmodule AmarulaAntiban.SessionTest do
  use ExUnit.Case, async: false

  alias AmarulaAntiban.Queue
  alias AmarulaAntiban.Session
  alias AmarulaAntiban.SessionSupervisor

  @now 1_000_000

  setup do
    id = {:session_test, System.unique_integer([:positive])}
    options = deterministic_options(id)
    {:ok, session} = SessionSupervisor.start_session(id, options)

    on_exit(fn -> SessionSupervisor.stop_session(id) end)
    %{id: id, session: session}
  end

  test "allow followed by successful accounting enforces the identical-message limit", %{
    session: session
  } do
    assert {:allow, decision} = Session.before_send(session, jid(), "same")
    assert decision.allowed
    assert :ok = Session.after_send(session, jid(), "same")

    assert {:deny, denied} = Session.before_send(session, jid(), "same")
    assert denied.reason == :identical_message_limit

    stats = Session.stats(session)
    assert stats.messages_allowed == 1
    assert stats.messages_blocked == 1
  end

  test "active timelock blocks new contacts but not a previously successful chat", %{
    session: session
  } do
    assert :ok = Session.after_send(session, jid(), "known")

    assert :ok =
             Session.update_timelock(session, %{
               is_active: true,
               time_enforcement_ends: @now + 60_000,
               enforcement_type: "reachout"
             })

    assert {:allow, _decision} = Session.before_send(session, jid(), "known again")
    assert {:deny, decision} = Session.before_send(session, "new@s.whatsapp.net", "new")
    assert decision.reason == :timelock
  end

  test "critical health risk auto-pauses before lower guards consume quotas", %{session: session} do
    assert :ok = Session.record_disconnect(session, 403)
    assert :ok = Session.record_disconnect(session, 403)

    assert {:deny, decision} = Session.before_send(session, jid(), "blocked")
    assert decision.reason == :health_paused
    assert decision.health.risk == :critical

    stats = Session.stats(session)
    assert stats.rate_limiter.last_day == 0
    assert stats.warm_up.today_sent == 0
  end

  test "515 is treated as protocol restart rather than a fatal health signal", %{session: session} do
    assert :ok = Session.record_disconnect(session, 515)
    assert Session.stats(session).health.risk == :low
  end

  test "File persistence survives a graceful session restart", %{id: id} do
    directory =
      Path.join(System.tmp_dir!(), "antiban_session_#{System.unique_integer([:positive])}")

    path = Path.join(directory, "state.json")
    on_exit(fn -> File.rm_rf(directory) end)

    assert :ok = SessionSupervisor.stop_session(id)
    {:ok, session} = SessionSupervisor.start_session(id, deterministic_options(id, persist: path))
    assert :ok = Session.after_send(session, jid(), "persisted", "wamid.persisted")
    assert :ok = Session.flush(session)
    assert :ok = SessionSupervisor.stop_session(id)

    {:ok, restarted} =
      SessionSupervisor.start_session(id, deterministic_options(id, persist: path))

    stats = Session.stats(restarted)
    assert stats.messages_allowed == 1
    assert stats.rate_limiter.last_day == 1
    assert stats.delivery_tracker.sent_in_window == 1
  end

  test "Queue owner success with msg_id feeds DeliveryTracker", %{session: session} do
    queue =
      start_supervised!(
        {Queue,
         owner: Session.queue_owner(session), now_fun: fn -> @now end, retry_base_delay_ms: 0}
      )

    :ok = Queue.set_send_fun(queue, fn _recipient, _content -> {:ok, "wamid.queue"} end)
    assert {:ok, _queue_id} = Queue.add(queue, jid(), "queued")
    assert {:sent, "wamid.queue"} = Queue.drain(queue)

    assert eventually(fn -> Session.stats(session).delivery_tracker.sent_in_window == 1 end)
  end

  test "manual lifecycle, receipts, reconnect, 463, and failure APIs are explicit", %{
    session: session
  } do
    assert :ok = Session.pause(session, :operator)
    assert {:deny, %{reason: :health_paused}} = Session.before_send(session, jid(), "paused")
    assert :ok = Session.resume(session)
    assert {:allow, _decision} = Session.before_send(session, jid(), "resumed")

    assert :ok = Session.record_reconnect(session)
    assert :ok = Session.record_send_failed(session, :timeout)
    assert :ok = Session.after_send(session, jid(), "tracked", "wamid.receipt")
    assert :ok = Session.record_receipt(session, "wamid.receipt")

    assert :ok =
             Session.record_receipt(session, %{
               message_ids: ["wamid.receipt"],
               status: :read
             })

    assert :ok = Session.record_463_error(session)

    assert {:deny, %{reason: :timelock}} =
             Session.before_send(session, "fresh@s.whatsapp.net", "fresh")

    assert :none = Session.record_incoming(session, jid())
    assert Session.stats(session).delivery_tracker.delivered_in_window == 1
  end

  test "remaining upstream guards keep their significant order" do
    warm = start_custom(day1_limit: 1, max_identical_messages: 10)
    assert :ok = Session.after_send(warm, jid(), "one")
    assert {:deny, %{reason: :warmup_limit}} = Session.before_send(warm, jid(), "two")

    contact =
      start_custom(
        contact_graph: [enabled: true, max_stranger_messages_per_day: 0],
        max_identical_messages: 10
      )

    assert {:deny, %{reason: :contact_graph}} =
             Session.before_send(contact, "stranger@s.whatsapp.net", "contact")

    reply =
      start_custom(
        reply_ratio: [enabled: true, min_messages_before_enforce: 1, min_ratio: 0.5],
        max_identical_messages: 10
      )

    assert :ok = Session.after_send(reply, jid(), "outbound")
    assert {:deny, %{reason: :reply_ratio}} = Session.before_send(reply, jid(), "second")

    reconnect =
      start_custom(
        reconnect_throttle: [
          enabled: true,
          baseline_rate_per_minute: 1,
          initial_rate_multiplier: 0.1,
          ramp_duration_ms: 60_000
        ],
        max_identical_messages: 10
      )

    assert :ok = Session.record_reconnect(reconnect)
    assert {:allow, _decision} = Session.before_send(reconnect, jid(), "first")

    assert {:deny, %{reason: :reconnect_throttle}} =
             Session.before_send(reconnect, jid(), "second")

    group =
      start_custom(
        max_per_minute: 2,
        group_multiplier: 0.5,
        max_identical_messages: 10
      )

    assert :ok = Session.after_send(group, jid(), "direct")

    assert {:deny, %{reason: :group_rate_limit}} =
             Session.before_send(group, "12345@g.us", "group")
  end

  test "persistence I/O is supervised, coalesced, and outside Session" do
    session =
      start_custom(
        state_store: {AmarulaAntiban.TestSlowStore, self()},
        max_identical_messages: 10
      )

    assert :ok = Session.after_send(session, jid(), "first")
    assert_receive {:slow_store_save, first_worker, first_snapshot}, 1_000
    assert first_snapshot["schema_version"] == 1
    assert Process.alive?(session)

    assert :ok = Session.after_send(session, jid(), "second")
    send(first_worker, :finish_slow_store_save)

    assert_receive {:slow_store_save, second_worker, second_snapshot}, 1_000
    assert second_snapshot["exported_at"] == @now
    send(second_worker, :finish_slow_store_save)
    assert eventually(fn -> Process.alive?(session) end)
  end

  test "a scheduled timelock lift is handled without sleeping in Session" do
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, @now)
    id = {:timelock_timer, System.unique_integer([:positive])}

    {:ok, session} =
      SessionSupervisor.start_session(
        id,
        deterministic_options(id,
          now_fun: fn -> :atomics.get(clock, 1) end,
          timelock: [resume_buffer_ms: 0]
        )
      )

    on_exit(fn -> SessionSupervisor.stop_session(id) end)

    assert :ok =
             Session.update_timelock(session, %{
               is_active: true,
               time_enforcement_ends: @now + 1,
               enforcement_type: "timer"
             })

    :atomics.put(clock, 1, @now + 2)
    send(session, {:timelock_resume, 1})

    assert eventually(fn ->
             match?(
               {:allow, _decision},
               Session.before_send(session, "timer@s.whatsapp.net", "after lift")
             )
           end)
  end

  test "later denial rolls back ContactGraph and ReconnectThrottle admission", %{session: session} do
    assert :ok = Session.after_send(session, jid(), "duplicate")

    assert {:deny, %{reason: :identical_message_limit}} =
             Session.before_send(session, "stranger@s.whatsapp.net", "duplicate")

    assert Session.stats(session).contact_graph.strangers_today == 0

    throttled =
      start_custom(
        max_per_minute: 2,
        group_multiplier: 0.5,
        max_identical_messages: 10,
        reconnect_throttle: [
          enabled: true,
          baseline_rate_per_minute: 1,
          initial_rate_multiplier: 0.1,
          ramp_duration_ms: 60_000
        ]
      )

    assert :ok = Session.after_send(throttled, jid(), "direct")
    assert :ok = Session.record_reconnect(throttled)

    assert {:deny, %{reason: :group_rate_limit}} =
             Session.before_send(throttled, "12345@g.us", "group")

    assert Session.stats(throttled).reconnect_throttle.throttled_send_count == 0
    assert {:allow, _decision} = Session.before_send(throttled, jid(), "still available")
  end

  test "incoming contact is known to an active timelock", %{session: session} do
    known = "known-inbound@s.whatsapp.net"
    assert :none = Session.record_incoming(session, known)

    assert :ok =
             Session.update_timelock(session, %{
               is_active: true,
               time_enforcement_ends: @now + 60_000,
               enforcement_type: "reachout"
             })

    assert {:allow, _decision} = Session.before_send(session, known, "reply")

    assert {:deny, %{reason: :timelock}} =
             Session.before_send(session, "never-seen@s.whatsapp.net", "reachout")
  end

  test "disabled presence is empty and offline gap is executed exactly once" do
    disabled = start_custom(presence: [enabled: false], max_identical_messages: 10)
    assert {:allow, decision} = Session.before_send(disabled, jid(), "disabled")
    assert decision.presence_plan == []
    assert Session.stats(disabled).total_delay_ms == decision.delay_ms

    offline =
      start_custom(
        presence: [
          enabled: true,
          enable_typing_model: false,
          distraction_pause_probability: 0.0,
          offline_gap_probability: 1.0,
          offline_gap_min_ms: 200,
          offline_gap_max_ms: 200
        ],
        max_identical_messages: 10
      )

    assert {:allow, decision} = Session.before_send(offline, jid(), "offline")
    assert decision.presence_plan == [{:available, 200}]
    assert Session.stats(offline).total_delay_ms == decision.delay_ms + 200
  end

  test "first open is not reconnect and tuple 515 remains protocol restart" do
    session =
      start_custom(
        reconnect_throttle: [
          enabled: true,
          baseline_rate_per_minute: 1,
          initial_rate_multiplier: 0.1,
          ramp_duration_ms: 60_000
        ],
        max_identical_messages: 10
      )

    assert :ok = Session.connection_update(session, :open)
    assert Session.stats(session).reconnect_throttle.lifetime_reconnects == 0

    assert :ok = Session.record_disconnect(session, {:stream_error, 515, "restart required"})
    assert Session.stats(session).health.risk == :low
    assert :ok = Session.connection_update(session, :open)
    assert Session.stats(session).reconnect_throttle.lifetime_reconnects == 1
  end

  test "decide_topology denies a new contact once the hourly cap is exceeded" do
    session =
      start_custom(
        topology_throttler: [
          enabled: true,
          max_new_contacts_per_hour: 1,
          min_reply_ratio_for_new_contacts: 0
        ],
        max_identical_messages: 10
      )

    assert :ok = Session.after_send(session, jid(), "first")

    assert {:deny, %{reason: :topology_throttle}} =
             Session.before_send(session, "stranger@s.whatsapp.net", "second")
  end

  test "decide_topology's suggested delay for a first-time contact reaches the final decision" do
    session = start_custom(topology_throttler: [enabled: true], max_identical_messages: 10)

    assert {:allow, decision} = Session.before_send(session, jid(), "")
    assert decision.delay_ms == 60_000
    assert Session.stats(session).total_delay_ms == 60_000
  end

  test "critical health risk auto-starts a soft_ban recovery pause" do
    session = start_custom([])
    assert :ok = Session.record_disconnect(session, 403)
    assert :ok = Session.record_disconnect(session, 403)

    ban_status = Session.stats(session).ban_recovery
    assert ban_status.phase == :paused
    assert ban_status.rate_multiplier == 0.05
  end

  test "a 401 disconnect starts an immediate hard-ban pause ahead of health's own threshold" do
    session = start_custom([])
    assert :ok = Session.record_disconnect(session, 401)

    assert Session.stats(session).health.risk == :high
    assert {:deny, %{reason: :ban_recovery}} = Session.before_send(session, jid(), "after 401")
  end

  test "ban_recovery gate blocks during its pause and applies the scaled rate once recovering" do
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, @now)
    id = {:ban_recovery_test, System.unique_integer([:positive])}

    {:ok, session} =
      SessionSupervisor.start_session(
        id,
        deterministic_options(id, now_fun: fn -> :atomics.get(clock, 1) end)
      )

    on_exit(fn -> SessionSupervisor.stop_session(id) end)

    assert :ok = Session.record_ban_event(session, :rate_overlimit)
    assert {:deny, %{reason: :ban_recovery}} = Session.before_send(session, jid(), "")

    :atomics.put(clock, 1, @now + 14_400_000)
    assert {:allow, decision} = Session.before_send(session, jid(), "")
    assert decision.delay_ms == 0
    assert Session.stats(session).rate_limiter.limits.per_minute == 1
  end

  defp deterministic_options(id, overrides \\ []) do
    Keyword.merge(
      [
        session_id: id,
        now_fun: fn -> @now end,
        rand_fun: fn -> 0.5 end,
        min_delay_ms: 0,
        max_delay_ms: 0,
        new_chat_delay_ms: 0,
        max_identical_messages: 1,
        auto_pause_at: :critical,
        presence: [typing_min_ms: 0],
        persistence_debounce_ms: 0
      ],
      overrides
    )
  end

  defp jid, do: "5511999999999@s.whatsapp.net"

  defp start_custom(overrides) do
    id = {:custom_session, System.unique_integer([:positive])}
    {:ok, session} = SessionSupervisor.start_session(id, deterministic_options(id, overrides))
    on_exit(fn -> SessionSupervisor.stop_session(id) end)
    session
  end

  defp eventually(fun, attempts \\ 20) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
