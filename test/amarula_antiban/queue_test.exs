defmodule AmarulaAntiban.QueueTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias AmarulaAntiban.Queue

  test "prioritizes high messages and notifies owner" do
    queue = start_supervised!({Queue, owner: self(), now_fun: fn -> 1_000 end})

    owner = self()

    :ok =
      Queue.set_send_fun(queue, fn recipient, _ ->
        send(owner, {:sent_to, recipient})
        :ok
      end)

    {:ok, _} = Queue.add(queue, "low", %{}, priority: :low)
    {:ok, _} = Queue.add(queue, "high", %{}, priority: :high)
    assert :sent = Queue.drain(queue)
    assert_receive {:sent_to, "high"}
    assert :sent = Queue.drain(queue)
    assert_receive {:sent_to, "low"}
  end

  test "retries errors with exponential scheduling" do
    queue = start_supervised!({Queue, now_fun: fn -> 1_000 end, retry_base_delay_ms: 10})
    :ok = Queue.set_send_fun(queue, fn _, _ -> {:error, :offline} end)
    {:ok, _} = Queue.add(queue, "a", :payload)
    assert {:retry, 10} = Queue.drain(queue)
    assert Queue.stats(queue).scheduled == 1
  end

  test "handles full, delayed, failed, removal and lifecycle states" do
    queue =
      start_supervised!({Queue, now_fun: fn -> 1_000 end, max_queue_size: 1, max_attempts: 1})

    assert {:error, :send_fun_not_set} = Queue.drain(queue)
    {:ok, id} = Queue.add(queue, "a", :payload)
    assert {:error, :full} = Queue.add(queue, "b", :payload)
    assert Queue.remove(queue, id)
    refute Queue.remove(queue, id)
    {:ok, _} = Queue.add(queue, "a", :payload)
    :ok = Queue.set_send_fun(queue, fn _, _ -> {:error, {:antiban, :rate_limit}} end)
    assert :delayed = Queue.drain(queue)
    assert length(Queue.export(queue)) == 1
    :ok = Queue.set_send_fun(queue, fn _, _ -> {:error, :offline} end)
    assert {:failed, :offline} = Queue.drain(queue)
    assert :ok = Queue.start(queue)
    assert Queue.stats(queue).is_running
    assert :ok = Queue.stop(queue)
  end

  test "restores JSON-safe maps, keeps global FIFO, and delays Amarula halts" do
    owner = self()

    queue =
      start_supervised!({Queue, owner: owner, now_fun: fn -> 1_000 end, priority_order: false})

    :ok =
      Queue.restore(queue, [
        %{
          "id" => "msg_100_3",
          "recipient" => "late",
          "content" => %{},
          "priority" => "high",
          "added_at" => 200,
          "attempts" => 0,
          "max_attempts" => 3,
          "last_error" => nil,
          "scheduled_for" => nil,
          "metadata" => %{}
        },
        %{
          "id" => "msg_100_2",
          "recipient" => "first",
          "content" => %{},
          "priority" => "low",
          "added_at" => 100,
          "attempts" => 0,
          "max_attempts" => 3,
          "last_error" => nil,
          "scheduled_for" => nil,
          "metadata" => %{}
        }
      ])

    :ok =
      Queue.set_send_fun(queue, fn recipient, _ ->
        send(owner, {:restored, recipient})
        {:error, {:halted, {:antiban, :rate_limit}}}
      end)

    assert :delayed = Queue.drain(queue)
    assert_receive {:restored, "first"}
    [message | _] = Queue.export(queue)
    assert message["attempts"] == 0
    assert message["priority"] in ["high", "low"]
  end

  test "FIFO order survives equal timestamps, JSON export/restore, and legacy snapshots" do
    owner = self()
    queue = start_supervised!({Queue, now_fun: fn -> 1_000 end, priority_order: false})

    :ok =
      Queue.set_send_fun(queue, fn recipient, _ ->
        send(owner, {:sent_to, recipient})
        :ok
      end)

    {:ok, _} = Queue.add(queue, "low", :content, priority: :low)
    {:ok, _} = Queue.add(queue, "high", :content, priority: :high)
    snapshot = queue |> Queue.export() |> Jason.encode!() |> Jason.decode!()

    restored =
      start_supervised!(%{
        id: make_ref(),
        start: {Queue, :start_link, [[now_fun: fn -> 1_000 end, priority_order: false]]}
      })

    :ok = Queue.restore(restored, snapshot)

    :ok =
      Queue.set_send_fun(restored, fn recipient, _ ->
        send(owner, {:restored, recipient})
        :ok
      end)

    assert :sent = Queue.drain(restored)
    assert_receive {:restored, "low"}
    assert :sent = Queue.drain(restored)
    assert_receive {:restored, "high"}

    legacy_snapshot = Enum.map(snapshot, &Map.delete(&1, "sequence"))
    :ok = Queue.restore(restored, legacy_snapshot)
    assert :sent = Queue.drain(restored)
    assert_receive {:restored, "low"}
    assert :sent = Queue.drain(restored)
    assert_receive {:restored, "high"}
  end

  test "accepts Amarula success and publishes the transport correlation before removal" do
    owner = self()
    queue = start_supervised!({Queue, owner: owner, now_fun: fn -> 1_000 end})
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:amarula_antiban, :queue, :sent],
        fn _event, measurements, metadata, pid ->
          send(pid, {:telemetry_sent, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok = Queue.set_send_fun(queue, fn _, _ -> {:ok, "wamid.real"} end)
    {:ok, queue_id} = Queue.add(queue, "recipient", :payload)

    assert {:sent, "wamid.real"} = Queue.drain(queue)

    assert_receive {:amarula_antiban, :queue, :sent,
                    %{queue_id: ^queue_id, msg_id: "wamid.real", attempts: 1}}

    assert_receive {:telemetry_sent, %{attempts: 1}, %{queue_id: ^queue_id, msg_id: "wamid.real"}}

    assert Queue.export(queue) == []
  end

  test "stays responsive during a blocked send and defines mutations for processing" do
    owner = self()

    queue =
      start_supervised!({Queue, owner: owner, now_fun: fn -> 1_000 end, send_timeout_ms: 5_000})

    :ok =
      Queue.set_send_fun(queue, fn _, _ ->
        send(owner, {:send_started, self()})

        receive do
          :release -> :ok
        end
      end)

    {:ok, processing_id} = Queue.add(queue, "first", :payload)
    drain = Task.async(fn -> Queue.drain(queue) end)
    assert_receive {:send_started, send_pid}

    assert %{processing: true, processing_id: ^processing_id, total: 1} = Queue.stats(queue)
    assert [%{"processing" => true}] = Queue.export(queue)
    assert {:ok, _pending_id} = Queue.add(queue, "second", :payload)
    refute Queue.remove(queue, processing_id)
    assert Queue.clear(queue) == 1
    assert Queue.stats(queue).total == 1
    assert :ok = Queue.stop(queue)

    send(send_pid, :release)
    assert :sent = Task.await(drain, 1_000)
    assert Queue.stats(queue).processing == false
    assert Queue.stats(queue).total == 0
  end

  test "send timeout is handled once, kills the task, and requeues at least once" do
    owner = self()

    queue =
      start_supervised!(
        {Queue,
         owner: owner, now_fun: fn -> 1_000 end, send_timeout_ms: 25, retry_base_delay_ms: 10}
      )

    :ok =
      Queue.set_send_fun(queue, fn _, _ ->
        send(owner, {:blocked_task, self()})
        Process.sleep(:infinity)
      end)

    {:ok, queue_id} = Queue.add(queue, "recipient", :payload)
    drain = Task.async(fn -> Queue.drain(queue) end)
    assert_receive {:blocked_task, send_pid}
    monitor = Process.monitor(send_pid)

    assert {:retry, 10} = Task.await(drain, 1_000)
    assert_receive {:DOWN, ^monitor, :process, ^send_pid, :killed}
    assert Process.alive?(queue)
    assert %{processing: false, scheduled: 1, total: 1} = Queue.stats(queue)
    assert [%{"id" => ^queue_id, "attempts" => 1, "processing" => false}] = Queue.export(queue)

    send(queue, {:queue_send_result, make_ref(), {:ok, "stale"}})
    send(queue, {:queue_send_timeout, make_ref()})
    assert Queue.stats(queue).total == 1
  end

  test "a real periodic tick already in the mailbox cannot send after stop returns" do
    owner = self()

    queue =
      start_supervised!({Queue, owner: owner, now_fun: fn -> 1_000 end, interval_ms: 100})

    :ok =
      Queue.set_send_fun(queue, fn _, _ ->
        send(owner, :stale_tick_started_send)
        :ok
      end)

    {:ok, _id} = Queue.add(queue, "recipient", :payload)
    assert :ok = Queue.start(queue)
    assert :ok = :sys.suspend(queue)
    on_exit(fn -> safe_resume(queue) end)

    spawn(fn -> send(owner, {:stop_result, Queue.stop(queue)}) end)

    assert wait_until(fn -> mailbox_has?(queue, &match?({:"$gen_call", _from, :stop}, &1)) end)

    assert wait_until(fn ->
             mailbox_has?(queue, &match?({:drain, _generation}, &1))
           end)

    assert :ok = :sys.resume(queue)
    assert_receive {:stop_result, :ok}
    refute_receive :stale_tick_started_send, 100
    assert %{is_running: false, total: 1, processing: false} = Queue.stats(queue)
  end

  test "a linked send task dies with a brutally killed Queue and leaves no orphan" do
    owner = self()
    task_supervisor = start_supervised!({Task.Supervisor, []})
    queue_child_id = {:brutal_queue, make_ref()}

    queue =
      start_supervised!(%{
        id: queue_child_id,
        restart: :temporary,
        start:
          {Queue, :start_link,
           [
             [
               owner: owner,
               now_fun: fn -> 1_000 end,
               send_timeout_ms: 5_000,
               task_supervisor: task_supervisor
             ]
           ]}
      })

    :ok =
      Queue.set_send_fun(queue, fn _, _ ->
        send(owner, {:linked_send_started, self()})
        Process.sleep(:infinity)
      end)

    {:ok, _id} = Queue.add(queue, "recipient", :payload)

    spawn(fn ->
      result = catch_exit(Queue.drain(queue))
      send(owner, {:drain_caller_exit, result})
    end)

    assert_receive {:linked_send_started, send_pid}
    queue_monitor = Process.monitor(queue)
    send_monitor = Process.monitor(send_pid)
    assert [^send_pid] = Task.Supervisor.children(task_supervisor)

    Process.exit(queue, :kill)

    assert_receive {:DOWN, ^queue_monitor, :process, ^queue, :killed}
    assert_receive {:DOWN, ^send_monitor, :process, ^send_pid, :killed}
    assert_receive {:drain_caller_exit, _reason}
    assert wait_until(fn -> Task.Supervisor.children(task_supervisor) == [] end)
  end

  test "an abnormal linked task becomes one retry without crashing the Queue" do
    queue =
      start_supervised!(
        {Queue, now_fun: fn -> 1_000 end, retry_base_delay_ms: 10, max_attempts: 2}
      )

    :ok = Queue.set_send_fun(queue, fn _, _ -> exit(:transport_crashed) end)
    {:ok, _id} = Queue.add(queue, "recipient", :payload)

    capture_log(fn ->
      assert {:retry, 10} = Queue.drain(queue)
      assert Process.alive?(queue)
      assert %{processing: false, scheduled: 1, total: 1} = Queue.stats(queue)
    end)
  end

  test "processing snapshot restores pending after restart and round-trips arbitrary terms" do
    owner = self()
    child_id = {:queue_restart, make_ref()}

    queue =
      start_supervised!(%{
        id: child_id,
        start:
          {Queue, :start_link, [[owner: owner, now_fun: fn -> 1_000 end, send_timeout_ms: 5_000]]}
      })

    :ok =
      Queue.set_send_fun(queue, fn _, _ ->
        send(owner, {:restart_send_started, self()})
        Process.sleep(:infinity)
      end)

    content = {:message, %{kind: :text, body: <<0, 255>>}}
    {:ok, queue_id} = Queue.add(queue, "recipient", content, metadata: {:campaign, :one})
    caller = spawn(fn -> Queue.drain(queue) end)
    caller_monitor = Process.monitor(caller)
    assert_receive {:restart_send_started, _send_pid}

    snapshot = queue |> Queue.export() |> Jason.encode!() |> Jason.decode!()
    assert [%{"id" => ^queue_id, "processing" => true}] = snapshot
    stop_supervised!(child_id)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, _reason}

    restored = start_supervised!({Queue, now_fun: fn -> 1_000 end})
    assert :ok = Queue.restore(restored, snapshot)

    :ok =
      Queue.set_send_fun(restored, fn recipient, restored_content ->
        send(owner, {:restored_term, recipient, restored_content})
        :ok
      end)

    assert :sent = Queue.drain(restored)
    assert_receive {:restored_term, "recipient", ^content}
  end

  test "priority restore sorts an out-of-order snapshot by priority and added_at" do
    owner = self()
    queue = start_supervised!({Queue, now_fun: fn -> 1_000 end, priority_order: true})

    snapshot = [
      legacy_message("normal-late", "normal-late", "normal", 300),
      legacy_message("high-late", "high-late", "high", 200),
      legacy_message("high-first", "high-first", "high", 100),
      legacy_message("low-first", "low-first", "low", 50)
    ]

    assert :ok = Queue.restore(queue, snapshot)

    :ok =
      Queue.set_send_fun(queue, fn recipient, _ ->
        send(owner, {:priority_restored, recipient})
        :ok
      end)

    for expected <- ["high-first", "high-late", "normal-late", "low-first"] do
      assert :sent = Queue.drain(queue)
      assert_receive {:priority_restored, ^expected}
    end
  end

  defp legacy_message(id, recipient, priority, added_at) do
    %{
      "id" => id,
      "recipient" => recipient,
      "content" => %{},
      "priority" => priority,
      "added_at" => added_at,
      "attempts" => 0,
      "max_attempts" => 3,
      "last_error" => nil,
      "scheduled_for" => nil,
      "metadata" => %{}
    }
  end

  defp mailbox_has?(pid, matcher) do
    case Process.info(pid, :messages) do
      {:messages, messages} -> Enum.any?(messages, matcher)
      nil -> false
    end
  end

  defp wait_until(fun, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      true
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        false
      else
        receive do
        after
          min(remaining, 5) -> do_wait_until(fun, deadline)
        end
      end
    end
  end

  defp safe_resume(pid) do
    if Process.alive?(pid), do: :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end
end
