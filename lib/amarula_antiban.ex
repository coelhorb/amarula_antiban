defmodule AmarulaAntiban do
  @moduledoc """
  OTP-native anti-ban middleware for Amarula WhatsApp clients.

  The plugin surface intentionally covers only hooks Amarula v0.5.6 actually
  exposes. Feed delivery receipts and lifecycle events from the application's
  normal Amarula event sink through `handle_event/2`; 515 is treated as the
  protocol's normal restart-required flow.
  """

  alias AmarulaAntiban.Core.GroupOperationGuard
  alias AmarulaAntiban.Core.MessageTypeRegistry
  alias AmarulaAntiban.EventBridgeSupervisor
  alias AmarulaAntiban.Plugin
  alias AmarulaAntiban.Session
  alias AmarulaAntiban.SessionHandle
  alias AmarulaAntiban.SessionLifecycle
  alias AmarulaAntiban.SessionSupervisor

  @doc "Attaches the antiban plugin to an Amarula connection description."
  @spec attach(Amarula.Conn.t(), keyword()) :: Amarula.Conn.t()
  defdelegate attach(conn, options \\ []), to: Plugin

  @doc "Starts or finds a standalone antiban session."
  @spec start_session(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  defdelegate start_session(session_id, options \\ []), to: SessionSupervisor

  @doc "Ensures a session and returns a stable logical handle."
  @spec session_handle(term(), keyword()) :: {:ok, SessionHandle.t()} | {:error, term()}
  defdelegate session_handle(session_id, options \\ []), to: SessionSupervisor, as: :handle

  @doc "Looks up a registered antiban session."
  @spec whereis(term()) :: pid() | nil
  defdelegate whereis(session_id), to: SessionSupervisor

  @doc "Flushes and stops a registered antiban session."
  @spec stop_session(term()) :: :ok | {:error, term()}
  defdelegate stop_session(session_id), to: SessionSupervisor

  @doc "Returns Queue options that correlate real `msg_id` success to DeliveryTracker."
  @spec queue_options(Session.server() | SessionHandle.t() | term(), keyword()) :: keyword()
  def queue_options(session, options \\ []) do
    {session_id, session_options} = session_identity(session)
    {:ok, owner} = EventBridgeSupervisor.ensure_bridge(session_id, session_options)

    options
    |> Keyword.put(:owner, owner)
    |> Keyword.put_new(:profile, session_id)
  end

  @doc """
  Checks and reserves a group-operation rate-limit slot ahead of an
  `Amarula.Group.*` call — group operations don't flow through the `on_send`
  plugin pipeline, so the host calls this explicitly:

      case AmarulaAntiban.check_group_operation(session, :add, group_jid) do
        {:allow, :ok} -> Amarula.Group.participants(conn, group_jid, participants, :add)
        {:deny, decision} -> {:error, decision.detail}
      end
  """
  @spec check_group_operation(
          Session.server() | SessionHandle.t() | term(),
          GroupOperationGuard.operation(),
          String.t()
        ) ::
          {:allow, :ok} | {:deny, map()}
  def check_group_operation(session, op, key),
    do: with_session(session, &Session.check_group_operation(&1, op, key))

  @doc "Registers a named message-type definition. See `Session.register_message_type/3`."
  @spec register_message_type(
          Session.server() | SessionHandle.t() | term(),
          String.t(),
          MessageTypeRegistry.Definition.t() | keyword() | map()
        ) :: :ok | {:error, :type_locked | :invalid_definition}
  def register_message_type(session, name, definition),
    do: with_session(session, &Session.register_message_type(&1, name, definition))

  @doc """
  Validates a typed send and reserves its rate-limit pool slot ahead of an
  Amarula transport call:

      :ok = AmarulaAntiban.register_message_type(session, "otp", priority: :critical)

      case AmarulaAntiban.prepare_typed_send(session, jid, content, "otp") do
        {:ok, prepared} ->
          {:ok, msg_id} = Amarula.send_text(conn, jid, content)
          AmarulaAntiban.record_typed_send(session, prepared, msg_id)

        {:error, reason} ->
          {:error, reason}
      end

  See `Session.prepare_typed_send/5`.
  """
  @spec prepare_typed_send(
          Session.server() | SessionHandle.t() | term(),
          String.t(),
          term(),
          String.t(),
          keyword()
        ) ::
          {:ok, MessageTypeRegistry.PreparedSend.t()}
          | {:error, MessageTypeRegistry.error_reason()}
  def prepare_typed_send(session, recipient, content, type, opts \\ []),
    do: with_session(session, &Session.prepare_typed_send(&1, recipient, content, type, opts))

  @doc "Records a successful typed send. See `Session.record_typed_send/3`."
  @spec record_typed_send(
          Session.server() | SessionHandle.t() | term(),
          MessageTypeRegistry.PreparedSend.t(),
          String.t() | nil
        ) :: :ok
  def record_typed_send(session, prepared, message_id \\ nil),
    do: with_session(session, &Session.record_typed_send(&1, prepared, message_id))

  @doc """
  Feeds public Amarula events into a session.

  Delivery/read receipts are exact. Connection updates without a public reason
  are not classified; explicit `:error` stream codes may be recorded. Retry
  receipts and ack correlation remain delegated to Amarula because their public
  events do not carry the required message ID/reason pair.
  """
  @spec handle_event(Session.server(), term()) :: :ok
  def handle_event(session, {:amarula, :receipt_update, receipt}),
    do: with_session(session, &Session.record_receipt(&1, receipt))

  def handle_event(session, {:amarula, :connection_update, %{connection: :connected}}),
    do: with_session(session, &Session.connection_update(&1, :connected))

  def handle_event(session, {:amarula, :connection_update, %{connection: :open}}),
    do: with_session(session, &Session.connection_update(&1, :open))

  def handle_event(session, {:amarula, :connection_update, %{connection: connection}})
      when connection in [:disconnected, :closed],
      do: with_session(session, &Session.connection_update(&1, connection))

  def handle_event(session, {:amarula, :error, {:stream_error, code, reason}}),
    do: with_session(session, &Session.record_disconnect(&1, {:stream_error, code, reason}))

  def handle_event(_session, _event), do: :ok

  defp session_identity(%SessionHandle{session_id: session_id, options: options}),
    do: {session_id, options}

  defp session_identity(pid) when is_pid(pid), do: Session.identity(pid)

  defp session_identity(session_id) do
    options =
      case SessionLifecycle.options(session_id) do
        {:ok, stored} -> stored
        :error -> []
      end

    {session_id, options}
  end

  defp with_session(%SessionHandle{} = handle, fun),
    do: SessionSupervisor.with_session(handle, fun)

  defp with_session(pid, fun) when is_pid(pid), do: fun.(pid)
  defp with_session(session_id, fun), do: SessionSupervisor.with_session(session_id, fun)
end
