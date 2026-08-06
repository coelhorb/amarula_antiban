defmodule AmarulaAntiban.PluginTest do
  use ExUnit.Case, async: false

  alias Amarula.Protocol.Auth.AuthUtils
  alias Amarula.Protocol.Proto
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

  setup do
    unique = System.unique_integer([:positive])
    profile = "antiban_plugin_#{unique}"
    root = Path.join(System.tmp_dir!(), "antiban_plugin_#{unique}")
    test_pid = self()

    auth =
      AuthUtils.init_auth_creds()
      |> Map.put(:me, %{id: "10000000000@s.whatsapp.net", lid: nil, name: "Antiban Test"})

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
      |> Plugin.attach(
        rand_fun: fn -> 0.5 end,
        min_delay_ms: 0,
        max_delay_ms: 0,
        new_chat_delay_ms: 0,
        max_identical_messages: 1,
        auto_pause_at: :critical,
        reply_ratio: [enabled: true],
        contact_graph: [enabled: true, require_handshake_before_group_send: false],
        presence: [
          enabled: true,
          enable_typing_model: true,
          typing_min_ms: 1,
          typing_max_ms: 1,
          distraction_pause_probability: 1.0,
          distraction_pause_min_ms: 1,
          distraction_pause_max_ms: 1,
          offline_gap_probability: 1.0,
          offline_gap_min_ms: 1,
          offline_gap_max_ms: 1
        ],
        sleep_fun: fn milliseconds -> send(test_pid, {:slept, milliseconds}) end
      )

    {:ok, pid} = Amarula.connect(conn, parent_pid: test_pid)
    session = Plugin.session(profile)

    on_exit(fn ->
      Amarula.stop(pid)
      SessionSupervisor.stop_session(profile)
      File.rm_rf(root)
    end)

    %{conn: conn, pid: pid, profile: profile, session: session}
  end

  test "send step preserves ctx and uses Amarula's exact halt shape", context do
    ctx = send_ctx(context.conn, context.profile, "wamid.1", "same")
    antiban_step = List.last(context.conn.send_steps)

    assert {:cont, ^ctx} = antiban_step.(ctx)

    second = %{ctx | msg_id: "wamid.2"}
    assert {:halt, {:antiban, :identical_message_limit}} = antiban_step.(second)
  end

  test "timelock halt is expressed exactly as Amarula expects", context do
    assert :ok =
             Session.update_timelock(context.session, %{
               is_active: true,
               time_enforcement_ends: System.system_time(:millisecond) + 60_000,
               enforcement_type: "reachout"
             })

    ctx = send_ctx(context.conn, context.profile, "wamid.locked", "new")
    assert {:halt, {:antiban, :timelock}} = List.last(context.conn.send_steps).(ctx)
  end

  test "Amarula.Testing drives the real receive pipeline into Session", context do
    assert :ok =
             Amarula.Testing.deliver_text(context.pid,
               from: "5511888888888@s.whatsapp.net",
               text: "hello",
               id: "INCOMING1"
             )

    assert_receive {:amarula, :messages_upsert, %{messages: [_message]}}, 1_000

    stats = Session.stats(context.session)
    assert stats.reply_ratio.global_received == 1
    assert stats.contact_graph.known_contacts == 1
  end

  test "offline Amarula.Testing sends honestly bypass the send pipeline", context do
    assert {:ok, _msg_id} = Amarula.send_text(context.pid, jid(), "offline")
    assert Session.stats(context.session).messages_allowed == 0
  end

  test "caption extraction and an injected pause plan execute outside Session", context do
    message = %Proto.Message{
      imageMessage: %Proto.Message.ImageMessage{caption: "image caption"}
    }

    ctx = %{send_ctx(context.conn, context.profile, "wamid.image", "ignored") | message: message}
    assert {:cont, ^ctx} = List.last(context.conn.send_steps).(ctx)
    assert_receive {:slept, 1}

    assert eventually(fn ->
             Session.stats(context.session).presence.typing_plans_executed == 1
           end)
  end

  test "video, empty struct, and opaque payload content extraction remain total", context do
    step = List.last(context.conn.send_steps)

    messages = [
      %Proto.Message{videoMessage: %Proto.Message.VideoMessage{caption: "video caption"}},
      %Proto.Message{},
      :opaque
    ]

    Enum.with_index(messages, fn message, index ->
      ctx = %{
        send_ctx(context.conn, context.profile, "wamid.shape.#{index}", "ignored")
        | message: message
      }

      assert {:cont, ^ctx} = step.(ctx)
    end)
  end

  test "typo injection mutates ctx.message and schedules a correction after the delay" do
    test_pid = self()
    unique = System.unique_integer([:positive])
    profile = "antiban_plugin_typo_#{unique}"
    root = Path.join(System.tmp_dir!(), profile)

    auth =
      AuthUtils.init_auth_creds()
      |> Map.put(:me, %{id: "10000000001@s.whatsapp.net", lid: nil, name: "Antiban Typo Test"})

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
      |> Plugin.attach(
        rand_fun: fn -> 0.5 end,
        min_delay_ms: 0,
        max_delay_ms: 0,
        new_chat_delay_ms: 0,
        max_identical_messages: 10,
        auto_pause_at: :critical,
        legitimacy_signals: [
          enabled: true,
          typo_probability: 1.0,
          typo_correct_min_ms: 5,
          typo_correct_max_ms: 5
        ],
        sleep_fun: fn milliseconds -> send(test_pid, {:slept, milliseconds}) end
      )

    {:ok, pid} = Amarula.connect(conn, parent_pid: test_pid)

    on_exit(fn ->
      Amarula.stop(pid)
      SessionSupervisor.stop_session(profile)
      File.rm_rf(root)
    end)

    ctx = send_ctx(conn, profile, "wamid.typo", "hello there my friend")
    step = List.last(conn.send_steps)

    assert {:cont, mutated} = step.(ctx)
    assert %Proto.Message{conversation: typo_text} = mutated.message
    assert typo_text != "hello there my friend"
    refute mutated == ctx

    assert_receive {:slept, 5}, 1_000
  end

  test "receive step ignores bare sender-key and protocol control frames", context do
    step = List.last(context.conn.recv_steps)

    sender_key = %Proto.Message{
      senderKeyDistributionMessage: %Proto.Message.SenderKeyDistributionMessage{}
    }

    protocol = %Proto.Message{protocolMessage: %Proto.Message.ProtocolMessage{}}

    for {message, id} <- [{sender_key, "CONTROL1"}, {protocol, "CONTROL2"}] do
      ctx = %{message: message, from: jid(), id: id, profile: context.profile}
      assert {:cont, ^ctx} = step.(ctx)
    end

    stats = Session.stats(context.session)
    assert stats.reply_ratio.global_received == 0
    assert stats.contact_graph.known_contacts == 0

    revoke = %Proto.Message{
      protocolMessage: %Proto.Message.ProtocolMessage{
        type: :REVOKE,
        key: %Proto.MessageKey{id: "TARGET", remoteJid: jid()}
      }
    }

    ctx = %{message: revoke, from: jid(), id: "USER_PROTOCOL", profile: context.profile}
    assert {:cont, ^ctx} = step.(ctx)
    assert Session.stats(context.session).reply_ratio.global_received == 1
  end

  defp send_ctx(conn, profile, msg_id, text) do
    %{
      message: %Proto.Message{conversation: text},
      to: jid(),
      profile: profile,
      msg_id: msg_id,
      stanza_attrs: %{"category" => "peer"},
      retry_cache: conn.retry_cache
    }
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
