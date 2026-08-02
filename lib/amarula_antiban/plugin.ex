defmodule AmarulaAntiban.Plugin do
  @moduledoc """
  Amarula v0.5.6 send/receive pipeline integration.

  `attach/2` appends once per `session_id` (and never replaces existing steps),
  preserving Amarula's retry-cache-first ordering and every ctx key. Steps keep
  a stable logical handle, not a Session pid, so OTP restarts are transparent.
  Send halts use the host's exact `{:halt, {:antiban, reason}}` form.

  Amarula's receive hook precedes user-facing classification and has no
  `fromMe` bit. Known bare sender-key/protocol control frames are filtered; self
  messages cannot be distinguished at this hook and applications requiring that
  distinction should feed their post-classification event sink explicitly.

  Delays and best-effort presence plans execute in the caller running Amarula's
  pipeline, outside the antiban Session GenServer.
  """

  @behaviour Amarula.Plugin

  alias AmarulaAntiban.Session
  alias AmarulaAntiban.SessionHandle
  alias AmarulaAntiban.SessionSupervisor

  @attachment_key :amarula_antiban_attached_sessions

  @impl true
  def attach(%Amarula.Conn{} = conn, options \\ []) do
    session_id = Keyword.get(options, :session_id, conn.profile)
    {:ok, handle} = SessionSupervisor.handle(session_id, options)
    sleep_fun = Keyword.get(options, :sleep_fun, &Process.sleep/1)

    if attached?(conn, session_id) do
      conn
    else
      conn
      |> Amarula.Plugin.on_send(send_step(conn, handle, sleep_fun))
      |> Amarula.Plugin.on_recv(receive_step(handle))
      |> mark_attached(session_id)
    end
  end

  @doc "Returns the session started for an attached profile, if present."
  @spec session(term()) :: pid() | nil
  def session(session_id), do: SessionSupervisor.whereis(session_id)

  defp send_step(conn, %SessionHandle{} = handle, sleep_fun) do
    fn
      %{to: recipient, profile: _profile, msg_id: msg_id, message: message} = ctx ->
        content = message_content(message)

        case SessionSupervisor.with_session(
               handle,
               &Session.authorize_send(&1, recipient, content, msg_id)
             ) do
          {:allow, decision} ->
            sleep(delay(decision.delay_ms), sleep_fun)
            execute_presence(conn, recipient, decision.presence_plan, sleep_fun)
            record_presence(handle, decision.presence_plan)
            {:cont, ctx}

          {:deny, decision} ->
            {:halt, {:antiban, decision.reason}}

          {:error, _reason} ->
            {:halt, {:antiban, :session_unavailable}}
        end
    end
  end

  defp receive_step(%SessionHandle{} = handle) do
    fn
      %{from: sender, id: _id, profile: _profile, message: message} = ctx ->
        unless control_frame?(message) do
          _suggestion =
            SessionSupervisor.with_session(
              handle,
              &Session.record_incoming(&1, sender, message_content(message))
            )
        end

        {:cont, ctx}
    end
  end

  defp record_presence(_handle, []), do: :ok

  defp record_presence(handle, plan) do
    _ = SessionSupervisor.with_session(handle, &Session.presence_executed(&1, plan))
    :ok
  end

  defp attached?(conn, session_id) do
    conn.config
    |> Map.get(@attachment_key, [])
    |> Enum.member?(session_id)
  end

  defp mark_attached(conn, session_id) do
    attached = conn.config |> Map.get(@attachment_key, []) |> List.wrap()
    %{conn | config: Map.put(conn.config, @attachment_key, Enum.uniq([session_id | attached]))}
  end

  defp control_frame?(message) do
    not is_nil(field(message, :senderKeyDistributionMessage)) or
      protocol_control?(field(message, :protocolMessage), message)
  end

  defp protocol_control?(nil, _message), do: false

  defp protocol_control?(protocol, message) do
    user_facing? = field(protocol, :type) in [:MESSAGE_EDIT, :REVOKE, :GROUP_MEMBER_LABEL_CHANGE]
    not user_facing? and not user_content?(message)
  end

  defp user_content?(message) do
    Enum.any?([:conversation, :extendedTextMessage, :imageMessage, :videoMessage], fn key ->
      not is_nil(field(message, key))
    end)
  end

  defp execute_presence(_conn, _recipient, [], _sleep_fun), do: :ok

  defp execute_presence(conn, recipient, plan, sleep_fun) do
    pid = presence_pid(conn)
    Enum.each(plan, &execute_presence_step(pid, recipient, &1, sleep_fun))
  end

  defp presence_pid(conn) do
    Amarula.whereis(conn, conn.profile)
  rescue
    RuntimeError -> nil
  end

  defp execute_presence_step(pid, recipient, {:typing, duration_ms}, sleep_fun) do
    best_effort(pid, fn -> Amarula.send_chatstate(pid, recipient, :composing) end)
    sleep(duration_ms, sleep_fun)
    best_effort(pid, fn -> Amarula.send_chatstate(pid, recipient, :paused) end)
  end

  defp execute_presence_step(pid, recipient, {:pause, duration_ms}, sleep_fun) do
    best_effort(pid, fn -> Amarula.send_chatstate(pid, recipient, :paused) end)
    sleep(duration_ms, sleep_fun)
  end

  defp execute_presence_step(pid, _recipient, {:available, duration_ms}, sleep_fun) do
    best_effort(pid, fn -> Amarula.set_presence(pid, :unavailable) end)
    sleep(duration_ms, sleep_fun)
    best_effort(pid, fn -> Amarula.set_presence(pid, :available) end)
  end

  defp delay(value) when is_integer(value) and value > 0, do: value
  defp delay(_value), do: 0

  defp sleep(0, _sleep_fun), do: :ok
  defp sleep(milliseconds, sleep_fun), do: sleep_fun.(milliseconds)

  defp best_effort(nil, _fun), do: :ok

  defp best_effort(_pid, fun) do
    fun.()
  catch
    :exit, _reason -> :ok
  end

  defp message_content(message) do
    conversation = field(message, :conversation)
    extended = field(message, :extendedTextMessage)
    image = field(message, :imageMessage)
    video = field(message, :videoMessage)

    cond do
      is_binary(conversation) -> conversation
      is_binary(field(extended, :text)) -> field(extended, :text)
      is_binary(field(image, :caption)) -> field(image, :caption)
      is_binary(field(video, :caption)) -> field(video, :caption)
      true -> message_type_marker(message)
    end
  end

  defp field(nil, _key), do: nil
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_value, _key), do: nil

  defp message_type_marker(%{__struct__: module}), do: "<#{inspect(module)}>"
  defp message_type_marker(_message), do: "<message>"
end
