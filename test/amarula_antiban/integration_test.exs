defmodule AmarulaAntiban.IntegrationTest do
  @moduledoc """
  End-to-end coverage of `AmarulaAntiban.attach/2` wired to a real (offline
  sandbox) Amarula connection: attach, a real inbound message through the
  actual receive pipeline, a decision through the actual send pipeline, a
  presence effect executed for real against Amarula, and a `Queue` send
  result routed back through `EventBridge` into `Session`. This is the "we
  never tested the real attach flow end to end" gap from the parity audit.

  One honest limitation, not worked around: Amarula's offline/sandbox mode
  (what both `Amarula.Testing` and this test use — there is no live socket in
  test) intentionally short-circuits *outbound* sends before they ever reach
  `conn.send_steps` ("a send must not run the real pipeline... nothing to
  answer" per Amarula's own offline `deliver_async` clause), so
  `Amarula.send_text/3` cannot organically trigger the antiban decision here.
  The *inbound* path has no such restriction, so `Amarula.Testing.deliver_text/2`
  below runs the real receive pipeline unmodified. The send-side decision is
  exercised the same way `plugin_test.exs` already does: invoking the
  attached step function directly — the exact closure Amarula would call,
  just triggered by the test instead of a live send.
  """

  use ExUnit.Case, async: false

  alias Amarula.Protocol.Auth.AuthUtils
  alias Amarula.Protocol.Proto
  alias AmarulaAntiban.Queue
  alias AmarulaAntiban.Session
  alias AmarulaAntiban.SessionSupervisor

  setup_all do
    case Process.whereis(Amarula.Supervisor) do
      nil -> start_supervised!(Amarula.Supervisor)
      pid -> pid
    end

    :ok
  end

  test "attach -> real inbound -> decision -> presence effect -> queue event bridges back to Session" do
    test_pid = self()
    unique = System.unique_integer([:positive])
    profile = "antiban_integration_#{unique}"
    root = Path.join(System.tmp_dir!(), profile)

    auth =
      AuthUtils.init_auth_creds()
      |> Map.put(:me, %{
        id: "10000000004@s.whatsapp.net",
        lid: nil,
        name: "Antiban Integration Test"
      })

    conn =
      Amarula.new(%{
        profile: profile,
        storage: {Amarula.Storage.File, root: root},
        connection_state: :connected,
        frame_sink: test_pid,
        offline: true,
        auth: auth,
        max_retries: 1,
        retry_delay: 10
      })
      |> AmarulaAntiban.attach(
        rand_fun: fn -> 0.5 end,
        min_delay_ms: 0,
        max_delay_ms: 0,
        new_chat_delay_ms: 0,
        max_identical_messages: 10,
        auto_pause_at: :critical,
        reply_ratio: [enabled: true],
        presence: [enabled: true, enable_typing_model: true, typing_min_ms: 1, typing_max_ms: 1],
        sleep_fun: fn milliseconds -> send(test_pid, {:slept, milliseconds}) end
      )

    {:ok, pid} = Amarula.connect(conn, parent_pid: test_pid)
    session = AmarulaAntiban.whereis(profile)
    assert is_pid(session)

    on_exit(fn ->
      Amarula.stop(pid)
      SessionSupervisor.stop_session(profile)
      File.rm_rf(root)
    end)

    sender = "5511888888888@s.whatsapp.net"

    # 1. Real inbound, through the actual receive pipeline (on_recv) — not
    # invoked manually, proving attach/2's receive_step really runs.
    assert :ok = Amarula.Testing.deliver_text(pid, from: sender, text: "hello", id: "INBOUND1")
    assert_receive {:amarula, :messages_upsert, %{messages: [_message]}}, 1_000
    assert Session.stats(session).reply_ratio.global_received == 1

    # 2. Decision through the actual attached send_step closure. Presence
    # executes for real against Amarula (chatstate calls work offline; only
    # the wire frame is skipped).
    ctx = %{
      to: sender,
      profile: profile,
      msg_id: "OUTBOUND1",
      message: %Proto.Message{conversation: "hi there, how are you"}
    }

    antiban_step = List.last(conn.send_steps)
    assert {:cont, ^ctx} = antiban_step.(ctx)
    assert_receive {:slept, 1}, 1_000
    assert eventually(fn -> Session.stats(session).presence.typing_plans_executed == 1 end)

    # 3. A real Queue using the facade's public `queue_options/2` (not the
    # internal Session.queue_owner/1) — the same entry point a host app
    # uses — with its send outcome routed back through the real EventBridge
    # into Session's own accounting.
    queue_opts =
      AmarulaAntiban.queue_options(profile,
        now_fun: fn -> System.system_time(:millisecond) end,
        retry_base_delay_ms: 0
      )

    queue = start_supervised!({Queue, queue_opts})
    :ok = Queue.set_send_fun(queue, fn _recipient, _content -> {:ok, "OUTBOUND1"} end)
    assert {:ok, _queue_id} = Queue.add(queue, sender, "hi there, how are you")
    assert {:sent, "OUTBOUND1"} = Queue.drain(queue)

    assert eventually(fn -> Session.stats(session).delivery_tracker.sent_in_window == 1 end)
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
