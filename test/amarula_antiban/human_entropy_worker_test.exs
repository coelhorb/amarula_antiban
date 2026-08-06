defmodule AmarulaAntiban.HumanEntropyWorkerTest do
  use ExUnit.Case, async: false

  alias Amarula.Protocol.Auth.AuthUtils
  alias AmarulaAntiban.HumanEntropyWorker
  alias AmarulaAntiban.Plugin
  alias AmarulaAntiban.Session
  alias AmarulaAntiban.SessionSupervisor

  setup_all do
    case Process.whereis(Amarula.Supervisor) do
      nil -> start_supervised!(Amarula.Supervisor)
      pid -> pid
    end

    :ok
  end

  test "runs an immediate cycle on attach, executes actions, and reschedules on demand" do
    test_pid = self()
    unique = System.unique_integer([:positive])
    profile = "antiban_human_entropy_#{unique}"
    root = Path.join(System.tmp_dir!(), profile)

    auth =
      AuthUtils.init_auth_creds()
      |> Map.put(:me, %{
        id: "10000000002@s.whatsapp.net",
        lid: nil,
        name: "Antiban Entropy Test"
      })

    options = [
      rand_fun: fn -> 0.0 end,
      auto_pause_at: :critical,
      # Deterministic and far outside the test's real runtime, so the
      # worker's own auto-reschedule never races the manual :run_cycle send
      # below — the second cycle is driven explicitly, matching the
      # `{:timelock_resume, generation}` testing pattern in session_test.exs.
      human_entropy: [
        enabled: true,
        typing_probability: 1.0,
        presence_toggle_probability: 1.0,
        typing_min_ms: 1,
        typing_max_ms: 1,
        presence_toggle_min_ms: 2,
        presence_toggle_max_ms: 2,
        min_interval_ms: 300_000,
        max_interval_ms: 300_000
      ],
      sleep_fun: fn milliseconds -> send(test_pid, {:human_sleep, milliseconds}) end
    ]

    {:ok, session} = SessionSupervisor.start_session(profile, options)
    assert :none = Session.record_incoming(session, jid())

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
      |> Plugin.attach(options)

    {:ok, pid} = Amarula.connect(conn, parent_pid: test_pid)

    on_exit(fn ->
      Amarula.stop(pid)
      SessionSupervisor.stop_session(profile)
      File.rm_rf(root)
    end)

    worker = HumanEntropyWorker.whereis(profile)
    assert is_pid(worker)

    assert_receive {:human_sleep, 1}, 1_000
    assert_receive {:human_sleep, 2}, 1_000

    assert eventually(fn ->
             Session.stats(session).human_entropy ==
               %{cycles_run: 1, typing_events: 1, presence_toggles: 1}
           end)

    send(worker, :run_cycle)

    assert_receive {:human_sleep, 1}, 1_000
    assert_receive {:human_sleep, 2}, 1_000

    assert eventually(fn ->
             Session.stats(session).human_entropy ==
               %{cycles_run: 2, typing_events: 2, presence_toggles: 2}
           end)
  end

  test "no worker is started when human_entropy is disabled" do
    test_pid = self()
    unique = System.unique_integer([:positive])
    profile = "antiban_human_entropy_off_#{unique}"
    root = Path.join(System.tmp_dir!(), profile)

    auth =
      AuthUtils.init_auth_creds()
      |> Map.put(:me, %{
        id: "10000000003@s.whatsapp.net",
        lid: nil,
        name: "Antiban Entropy Off Test"
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
      |> Plugin.attach(rand_fun: fn -> 0.5 end)

    {:ok, pid} = Amarula.connect(conn, parent_pid: test_pid)

    on_exit(fn ->
      Amarula.stop(pid)
      SessionSupervisor.stop_session(profile)
      File.rm_rf(root)
    end)

    refute HumanEntropyWorker.whereis(profile)
  end

  defp jid, do: "5511999999999@s.whatsapp.net"

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
