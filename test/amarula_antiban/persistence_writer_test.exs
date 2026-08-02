defmodule AmarulaAntiban.PersistenceWriterTest do
  use ExUnit.Case, async: false

  alias AmarulaAntiban.PersistenceSupervisor
  alias AmarulaAntiban.PersistenceWriter
  alias AmarulaAntiban.Session
  alias AmarulaAntiban.SessionSupervisor

  setup do
    test_pid = self()

    {:ok, agent} =
      start_supervised({Agent, fn -> %{test_pid: test_pid, snapshot: nil} end})

    id = {:writer_test, System.unique_integer([:positive])}
    store = {AmarulaAntiban.TestControlledStore, agent}
    {:ok, writer} = PersistenceSupervisor.ensure_writer(id, store)
    on_exit(fn -> PersistenceSupervisor.stop_writer(id) end)
    %{agent: agent, id: id, store: store, writer: writer}
  end

  test "serializes old and new generations and refuses late regression", context do
    old = Task.async(fn -> PersistenceWriter.flush(context.writer, 1, snapshot("old")) end)
    assert_receive {:controlled_store_save, writer, 1, _snapshot}

    new = Task.async(fn -> PersistenceWriter.flush(context.writer, 2, snapshot("new")) end)
    refute_receive {:controlled_store_save, ^writer, 2, _snapshot}, 30

    send(writer, {:controlled_store_release, 1})
    assert :ok = Task.await(old)
    assert_receive {:controlled_store_save, ^writer, 2, _snapshot}
    send(writer, {:controlled_store_release, 2})
    assert :ok = Task.await(new)

    assert Agent.get(context.agent, & &1.snapshot)["value"] == "new"

    assert :ok = PersistenceWriter.flush(context.writer, 1, snapshot("late-old"))
    refute_receive {:controlled_store_save, ^writer, 1, _snapshot}, 30
    assert Agent.get(context.agent, & &1.snapshot)["value"] == "new"
  end

  test "adapter raise and exit are tagged and later saves remain usable", context do
    raised = Task.async(fn -> PersistenceWriter.flush(context.writer, 1, snapshot("raise")) end)
    assert_receive {:controlled_store_save, writer, 1, _snapshot}
    send(writer, {:controlled_store_raise, 1})
    assert {:error, {:adapter_exception, _message}} = Task.await(raised)
    assert Process.alive?(context.writer)

    exited = Task.async(fn -> PersistenceWriter.flush(context.writer, 2, snapshot("exit")) end)
    assert_receive {:controlled_store_save, ^writer, 2, _snapshot}
    send(writer, {:controlled_store_exit, 2})
    assert {:error, {:adapter_exit, :exit, :controlled_adapter_exit}} = Task.await(exited)
    assert Process.alive?(context.writer)

    recovered =
      Task.async(fn -> PersistenceWriter.flush(context.writer, 3, snapshot("recovered")) end)

    assert_receive {:controlled_store_save, ^writer, 3, _snapshot}
    send(writer, {:controlled_store_release, 3})
    assert :ok = Task.await(recovered)
    assert Agent.get(context.agent, & &1.snapshot)["value"] == "recovered"
  end

  test "killing a blocked writer leaves no task and its stable name accepts later saves",
       context do
    blocked =
      Task.async(fn -> PersistenceWriter.flush(context.writer, 1, snapshot("blocked")) end)

    assert_receive {:controlled_store_save, writer, 1, _snapshot}
    Process.exit(writer, :kill)
    assert {:error, {:writer_exit, _reason}} = Task.await(blocked)

    restarted =
      eventually_value(fn ->
        case PersistenceWriter.whereis(context.id) do
          pid when is_pid(pid) and pid != writer -> pid
          _missing -> nil
        end
      end)

    refute restarted == writer
    refute restarted in Task.Supervisor.children(AmarulaAntiban.Session.TaskSupervisor)

    recovered =
      Task.async(fn ->
        PersistenceWriter.flush(PersistenceWriter.via(context.id), 2, snapshot("after-kill"))
      end)

    assert_receive {:controlled_store_save, ^restarted, 2, _snapshot}
    send(restarted, {:controlled_store_release, 2})
    assert :ok = Task.await(recovered)
    assert Agent.get(context.agent, & &1.snapshot)["value"] == "after-kill"
  end

  test "concurrent Session flushes are monotonic barriers", context do
    {:ok, session} =
      SessionSupervisor.start_session(
        context.id,
        session_options(context.id, state_store: context.store, persistence_debounce_ms: 60_000)
      )

    assert :ok = Session.after_send(session, jid(), "one")
    flush1 = Task.async(fn -> Session.flush(session) end)
    flush2 = Task.async(fn -> Session.flush(session) end)

    assert_receive {:controlled_store_save, writer, first_generation, _snapshot}
    assert first_generation in [2, 3]
    send(writer, {:controlled_store_release, first_generation})

    if first_generation == 2 do
      assert_receive {:controlled_store_save, ^writer, 3, _snapshot}
      send(writer, {:controlled_store_release, 3})
    end

    assert :ok = Task.await(flush1)
    assert :ok = Task.await(flush2)
    assert Agent.get(context.agent, & &1.snapshot)["generation"] == 3
    assert :ok = stop_session_releasing(context.id)
  end

  test "Session kill waits behind its writer and restart restores the confirmed generation",
       context do
    {:ok, session} =
      SessionSupervisor.start_session(
        context.id,
        session_options(context.id, state_store: context.store, persistence_debounce_ms: 0)
      )

    assert :ok = Session.after_send(session, jid(), "before-kill")
    assert_receive {:controlled_store_save, writer, 1, _snapshot}
    Process.exit(session, :kill)
    refute Process.alive?(session)
    refute Task.Supervisor.children(AmarulaAntiban.Session.TaskSupervisor) |> Enum.member?(writer)

    send(writer, {:controlled_store_release, 1})

    restarted = eventually_value(fn -> SessionSupervisor.whereis(context.id) end)
    refute restarted == session
    assert Session.stats(restarted).messages_allowed == 1

    assert :ok = Session.after_send(restarted, jid(), "after-kill")
    assert_receive {:controlled_store_save, ^writer, 2, _snapshot}
    send(writer, {:controlled_store_release, 2})
    flush = Task.async(fn -> Session.flush(restarted) end)
    assert_receive {:controlled_store_save, ^writer, flush_generation, _snapshot}
    send(writer, {:controlled_store_release, flush_generation})
    assert :ok = Task.await(flush)
    assert Agent.get(context.agent, & &1.snapshot)["generation"] >= 2
    assert Agent.get(context.agent, & &1.snapshot)["state"]
    assert :ok = stop_session_releasing(context.id)
  end

  defp snapshot(value),
    do: %{"schema_version" => 1, "state" => %{}, "value" => value}

  defp session_options(id, overrides) do
    Keyword.merge(
      [
        session_id: id,
        now_fun: fn -> 1_000 end,
        rand_fun: fn -> 0.5 end,
        min_delay_ms: 0,
        max_delay_ms: 0,
        new_chat_delay_ms: 0,
        max_identical_messages: 10,
        presence: [enabled: false]
      ],
      overrides
    )
  end

  defp jid, do: "5511999999999@s.whatsapp.net"

  defp stop_session_releasing(id) do
    task = Task.async(fn -> SessionSupervisor.stop_session(id) end)

    receive do
      {:controlled_store_save, writer, generation, _snapshot} ->
        send(writer, {:controlled_store_release, generation})
    after
      100 -> :ok
    end

    Task.await(task)
  end

  defp eventually_value(fun, attempts \\ 100) do
    case fun.() do
      pid when is_pid(pid) ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        eventually_value(fun, attempts - 1)
    end
  end
end
