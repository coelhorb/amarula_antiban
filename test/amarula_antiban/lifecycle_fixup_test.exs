defmodule AmarulaAntiban.LifecycleFixupTest do
  use ExUnit.Case, async: false

  alias Amarula.Protocol.Proto
  alias AmarulaAntiban.Plugin
  alias AmarulaAntiban.Queue
  alias AmarulaAntiban.Session
  alias AmarulaAntiban.SessionSupervisor

  test "attach is idempotent and msg_id reservation is defensively idempotent" do
    {id, conn, options} = connection()
    attached = Plugin.attach(conn, options)
    attached_twice = Plugin.attach(attached, options)

    assert length(attached_twice.send_steps) == length(attached.send_steps)
    assert length(attached_twice.recv_steps) == length(attached.recv_steps)

    step = List.last(attached_twice.send_steps)
    ctx = send_ctx(attached_twice, id, "wamid.same")
    assert {:cont, ^ctx} = step.(ctx)
    assert {:cont, ^ctx} = step.(ctx)
    assert Session.stats(SessionSupervisor.whereis(id)).messages_allowed == 1
    assert :ok = SessionSupervisor.stop_session(id)

    unknown = {:supervisor_unknown, System.unique_integer([:positive])}
    unknown_pid = SessionSupervisor.with_session(unknown, fn current -> current end)
    assert is_pid(unknown_pid)
    assert :ok = SessionSupervisor.stop_session(unknown)
  end

  test "already attached steps rehydrate after Session and SessionSupervisor crashes" do
    {id, conn, options} = connection()
    attached = Plugin.attach(conn, options)
    step = List.last(attached.send_steps)
    first = SessionSupervisor.whereis(id)

    Process.exit(first, :kill)
    second = eventually_new_session(id, first)
    ctx1 = send_ctx(attached, id, "wamid.after-session")
    assert {:cont, ^ctx1} = step.(ctx1)

    old_supervisor = Process.whereis(SessionSupervisor)
    Process.exit(old_supervisor, :kill)

    _new_supervisor =
      eventually_new_pid(fn -> Process.whereis(SessionSupervisor) end, old_supervisor)

    third = eventually_new_session(id, second)
    ctx2 = send_ctx(attached, id, "wamid.after-supervisor")
    assert {:cont, ^ctx2} = step.(ctx2)
    assert Process.alive?(third)
    assert :ok = SessionSupervisor.stop_session(id)
  end

  test "stable Queue bridge delivers msg_id after SessionSupervisor restart" do
    {id, _conn, options} = connection()
    {:ok, session} = SessionSupervisor.start_session(id, options)

    queue =
      start_supervised!(
        {Queue,
         AmarulaAntiban.queue_options(id,
           now_fun: fn -> 1_000 end,
           retry_base_delay_ms: 0
         )}
      )

    old_owner = Queue |> then(fn _ -> AmarulaAntiban.queue_options(id)[:owner] end)
    old_supervisor = Process.whereis(SessionSupervisor)
    Process.exit(old_supervisor, :kill)

    _new_supervisor =
      eventually_new_pid(fn -> Process.whereis(SessionSupervisor) end, old_supervisor)

    restarted = eventually_new_session(id, session)
    assert AmarulaAntiban.queue_options(id)[:owner] == old_owner

    :ok = Queue.set_send_fun(queue, fn _recipient, _content -> {:ok, "wamid.restart"} end)
    assert {:ok, _queue_id} = Queue.add(queue, jid(), "queued")
    assert {:sent, "wamid.restart"} = Queue.drain(queue)

    assert eventually(fn -> Session.stats(restarted).delivery_tracker.sent_in_window == 1 end)
    assert :ok = SessionSupervisor.stop_session(id)
  end

  test "stop and start for the same ID are serialized across a slow flush" do
    test_pid = self()

    {:ok, agent} =
      start_supervised({Agent, fn -> %{test_pid: test_pid, snapshot: nil} end})

    id = {:stop_start, System.unique_integer([:positive])}
    store = {AmarulaAntiban.TestControlledStore, agent}
    options = options(id, state_store: store, persistence_debounce_ms: 60_000)
    {:ok, old} = SessionSupervisor.start_session(id, options)

    stopper = Task.async(fn -> SessionSupervisor.stop_session(id) end)
    assert_receive {:controlled_store_save, writer, 1, _snapshot}
    starter = Task.async(fn -> SessionSupervisor.start_session(id, options) end)
    refute Task.yield(starter, 30)

    send(writer, {:controlled_store_release, 1})
    assert :ok = Task.await(stopper)
    assert {:ok, fresh} = Task.await(starter)
    refute fresh == old
    assert Process.alive?(fresh)

    stop_again = Task.async(fn -> SessionSupervisor.stop_session(id) end)
    assert_receive {:controlled_store_save, writer2, generation, _snapshot}
    send(writer2, {:controlled_store_release, generation})
    assert :ok = Task.await(stop_again)
  end

  test "SessionSupervisor direct helpers cover stable lookup and retry paths" do
    id = {:supervisor_helpers, System.unique_integer([:positive])}
    assert {:ok, pid} = SessionSupervisor.start_session(id)
    assert {:ok, ^pid} = SessionSupervisor.start_child(id, session_id: id)

    assert ^pid = SessionSupervisor.with_session(id, fn current -> current end)

    marker = :atomics.new(1, signed: false)

    assert ^pid =
             SessionSupervisor.with_session(id, fn current ->
               if :atomics.add_get(marker, 1, 1) == 1,
                 do: exit({:noproc, {GenServer, :call, [current, :test]}}),
                 else: current
             end)

    assert :ok = SessionSupervisor.stop_session(id)
  end

  defp connection do
    id = "lifecycle_#{System.unique_integer([:positive])}"

    conn =
      Amarula.new(%{
        profile: id,
        storage: {Amarula.Storage.File, root: System.tmp_dir!()},
        offline: true
      })

    {id, conn, options(id)}
  end

  defp options(id, overrides \\ []) do
    Keyword.merge(
      [
        session_id: id,
        now_fun: fn -> 1_000 end,
        rand_fun: fn -> 0.5 end,
        min_delay_ms: 0,
        max_delay_ms: 0,
        new_chat_delay_ms: 0,
        max_identical_messages: 1,
        presence: [enabled: false],
        persistence_debounce_ms: 0,
        sleep_fun: fn _milliseconds -> :ok end
      ],
      overrides
    )
  end

  defp send_ctx(conn, profile, msg_id) do
    %{
      message: %Proto.Message{conversation: "message #{msg_id}"},
      to: jid(),
      profile: profile,
      msg_id: msg_id,
      stanza_attrs: %{},
      retry_cache: conn.retry_cache
    }
  end

  defp jid, do: "5511999999999@s.whatsapp.net"

  defp eventually_new_session(id, previous),
    do: eventually_new_pid(fn -> SessionSupervisor.whereis(id) end, previous)

  defp eventually_new_pid(fun, previous, attempts \\ 200) do
    case fun.() do
      pid when is_pid(pid) and pid != previous ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        eventually_new_pid(fun, previous, attempts - 1)
    end
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
