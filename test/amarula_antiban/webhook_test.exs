defmodule AmarulaAntiban.WebhookTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Webhook

  test "attaches a telemetry handler when Req is available" do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    id = {Webhook, make_ref()}

    assert :ok =
             Webhook.attach("http://localhost:1", [:amarula_antiban, :queue, :sent],
               handler_id: id
             )

    assert :ok = Webhook.detach(id)
  end

  test "reports failed asynchronous posts through telemetry" do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:amarula_antiban, :webhook, :failed],
        fn event, _, _, pid -> send(pid, event) end,
        self()
      )

    assert :ok =
             Webhook.handle_event([:amarula_antiban, :queue, :sent], %{}, %{}, %{
               url: "http://localhost:1",
               headers: []
             })

    assert_receive [:amarula_antiban, :webhook, :failed], 2_000
    :ok = :telemetry.detach(id)
  end

  test "atomically reserves one POST for concurrent events in the same cooldown" do
    parent = self()
    gate = make_ref()
    task_supervisor = start_supervised!({Task.Supervisor, []})

    config = %{
      url: "http://example.test/webhook",
      headers: [],
      cooldown_ms: 60_000,
      last_alert: :atomics.new(1, signed: false),
      now_fun: fn -> 1_000_000 end,
      task_supervisor: task_supervisor,
      post_fun: fn _url, _headers, _body ->
        send(parent, {:post_started, self()})

        receive do
          {:release_post, ^gate} -> {:ok, %{status: 204}}
        end
      end
    }

    tasks =
      for _ <- 1..32 do
        Task.async(fn ->
          receive do
            {:start, ^gate} ->
              Webhook.handle_event([:amarula_antiban, :queue, :sent], %{}, %{}, config)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, {:start, gate}))
    assert_receive {:post_started, received_pid}
    post_pid = received_pid
    Enum.each(tasks, &Task.await(&1, 1_000))

    assert [^post_pid] = Task.Supervisor.children(task_supervisor)
    refute_receive {:post_started, _duplicate_pid}, 50
    monitor = Process.monitor(post_pid)
    send(post_pid, {:release_post, gate})
    assert_receive {:DOWN, ^monitor, :process, ^post_pid, :normal}, 1_000
  end
end
