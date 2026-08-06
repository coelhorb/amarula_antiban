defmodule AmarulaAntiban.Session do
  @moduledoc """
  The single mutable state owner for one Amarula profile/session.

  Core decisions run synchronously in memory. Sleeping, presence I/O,
  persistence I/O, telemetry handlers, and user callbacks never run in this
  GenServer. Persistence is serialized by a generation-aware OTP writer;
  `flush/1` is an ordered barrier for graceful shutdowns.

  Amarula has no post-send plugin hook. `authorize_send/4`, used by `Plugin`,
  therefore reserves successful-attempt quotas after every guard passes. It
  does not claim delivery or ack success. Exact transport success is recorded
  by `after_send/4` or by configuring a `Queue` with this session as `:owner`.
  """

  use GenServer

  alias AmarulaAntiban.Core
  alias AmarulaAntiban.Decision
  alias AmarulaAntiban.EventBridgeSupervisor
  alias AmarulaAntiban.Jid
  alias AmarulaAntiban.PersistenceSupervisor
  alias AmarulaAntiban.PersistenceWriter
  alias AmarulaAntiban.Snapshot
  alias AmarulaAntiban.State
  alias AmarulaAntiban.StateStore

  @reservation_retention_ms 86_400_000

  @type server :: GenServer.server()

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    session_id = Keyword.fetch!(options, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [options]},
      restart: :permanent,
      shutdown: 10_000
    }
  end

  @doc "Starts one registered session."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    session_id = Keyword.fetch!(options, :session_id)
    GenServer.start_link(__MODULE__, options, name: via(session_id))
  end

  @doc "Returns the Registry-backed server name for a session ID."
  @spec via(term()) :: {:via, Registry, {atom(), term()}}
  def via(session_id), do: {:via, Registry, {AmarulaAntiban.Registry, session_id}}

  @doc "Runs the upstream-ordered decision chain without committing send success."
  @spec before_send(server(), String.t(), String.t()) ::
          {:allow, Decision.t()} | {:deny, Decision.t()}
  def before_send(server, recipient, content) do
    GenServer.call(server, {:before_send, recipient, content, nil, false}, :infinity)
  end

  @doc """
  Runs the decision chain and reserves admitted-attempt quotas atomically.

  This is the conservative plugin path used when the host offers no post-send
  callback. The reservation is keyed by Amarula's pre-generated `msg_id`.
  """
  @spec authorize_send(server(), String.t(), String.t(), String.t()) ::
          {:allow, Decision.t()} | {:deny, Decision.t()}
  def authorize_send(server, recipient, content, msg_id) do
    GenServer.call(server, {:before_send, recipient, content, msg_id, true}, :infinity)
  end

  @doc "Records a successful send when no transport message ID is available."
  @spec after_send(server(), String.t(), String.t()) :: :ok
  def after_send(server, recipient, content),
    do: GenServer.call(server, {:after_send, recipient, content, nil})

  @doc "Records a successful send and starts exact delivery tracking by `msg_id`."
  @spec after_send(server(), String.t(), String.t(), String.t()) :: :ok
  def after_send(server, recipient, content, msg_id),
    do: GenServer.call(server, {:after_send, recipient, content, msg_id})

  @doc "Records an Amarula `:receipt_update` payload or one message ID."
  @spec record_receipt(server(), map() | String.t()) :: :ok
  def record_receipt(server, receipt), do: GenServer.call(server, {:receipt, receipt})

  @doc "Records an observed disconnect. Code 515 remains a normal protocol restart."
  @spec record_disconnect(server(), term()) :: :ok
  def record_disconnect(server, reason), do: GenServer.call(server, {:disconnect, reason})

  @doc "Records a successful reconnect and begins the configured reconnect ramp."
  @spec record_reconnect(server()) :: :ok
  def record_reconnect(server), do: GenServer.call(server, :reconnect)

  @doc "Records a public connection lifecycle transition."
  @spec connection_update(server(), :open | :connected | :disconnected | :closed) :: :ok
  def connection_update(server, connection),
    do: GenServer.call(server, {:connection_update, connection})

  @doc "Applies an explicit reachout-timelock update from the host application."
  @spec update_timelock(server(), map()) :: :ok
  def update_timelock(server, update), do: GenServer.call(server, {:timelock, update})

  @doc "Records an explicitly observed 463 reachout error."
  @spec record_463_error(server()) :: :ok
  def record_463_error(server), do: GenServer.call(server, :timelock_463)

  @doc """
  Records a ban/restriction event the host detected but this session cannot
  infer on its own (e.g. an HTTP 429 rate-overlimit signal from the host's
  transport layer, or a repeated-463 pattern the host wants to escalate).
  Soft-ban and hard-ban (401) events are wired automatically from existing
  session effects; a single 463 stays `TimelockGuard`'s own timed block and
  does not by itself start `BanRecovery`'s longer pause.
  """
  @spec record_ban_event(server(), Core.BanRecovery.ban_event_type()) :: :ok
  def record_ban_event(server, event_type), do: GenServer.call(server, {:ban_event, event_type})

  @doc """
  Records an incoming message from Amarula's receive plugin context.

  `id`, when given, queues the message as owed a `HumanEntropy` background
  read receipt (see `Core.HumanEntropy.track_incoming/4`).
  """
  @spec record_incoming(server(), String.t(), String.t(), String.t() | nil) ::
          :none | {:reply, String.t()}
  def record_incoming(server, jid, text \\ "", id \\ nil),
    do: GenServer.call(server, {:incoming, jid, text, id})

  @doc "Records a failed outbound send exposed by the calling application."
  @spec record_send_failed(server(), term()) :: :ok
  def record_send_failed(server, error), do: GenServer.call(server, {:send_failed, error})

  @doc """
  Checks and, on success, reserves a group-operation rate-limit slot ahead of
  an `Amarula.Group.*` call. Group operations don't flow through the
  `on_send` plugin pipeline (it only wraps message sends), so hosts call this
  explicitly instead of going through `before_send`/`authorize_send`.
  """
  @spec check_group_operation(server(), Core.GroupOperationGuard.operation(), String.t()) ::
          {:allow, :ok}
          | {:deny,
             %{
               reason: :group_operation_limit,
               detail: String.t(),
               retry_after_sec: non_neg_integer()
             }}
  def check_group_operation(server, op, key),
    do: GenServer.call(server, {:group_operation, op, key})

  @doc """
  Registers (or replaces, if unlocked) a named message-type definition —
  priority, rate-limit pool, provenance/legitimacy requirements — ahead of
  `prepare_typed_send/5`. As upstream, registering an unlocked name resets
  that type's statistics; once a send has been prepared for it, the
  definition is immutable.
  """
  @spec register_message_type(
          server(),
          String.t(),
          Core.MessageTypeRegistry.Definition.t() | keyword() | map()
        ) :: :ok | {:error, :type_locked | :invalid_definition}
  def register_message_type(server, name, definition),
    do: GenServer.call(server, {:register_message_type, name, definition})

  @doc """
  Validates a typed send and reserves its rate-limit pool slot, without
  performing I/O. `type` must already be registered via
  `register_message_type/3`. Like `GroupOperationGuard`, this doesn't flow
  through `before_send`/`authorize_send` — a `type` is a per-message opt-in
  the host chooses, not every send has one, so it can't be a mandatory step
  in the main decision chain. `opts` accepts `:provenance` and
  `:engagement_score`. On success, transport the message yourself, then call
  `record_typed_send/3` with the returned `PreparedSend`.
  """
  @spec prepare_typed_send(server(), String.t(), term(), String.t(), keyword()) ::
          {:ok, Core.MessageTypeRegistry.PreparedSend.t()}
          | {:error, Core.MessageTypeRegistry.error_reason()}
  def prepare_typed_send(server, recipient, content, type, opts \\ []),
    do: GenServer.call(server, {:prepare_typed_send, recipient, content, type, opts})

  @doc "Records a successful typed send after transport succeeds, from a `prepare_typed_send/5` result."
  @spec record_typed_send(server(), Core.MessageTypeRegistry.PreparedSend.t(), String.t() | nil) ::
          :ok
  def record_typed_send(server, prepared, message_id \\ nil),
    do: GenServer.call(server, {:record_typed_send, prepared, message_id})

  @doc "Returns registry-wide warning signals for degraded message-type metrics and marks them observed."
  @spec message_type_warnings(server()) :: [Core.MessageTypeRegistry.Warning.t()]
  def message_type_warnings(server), do: GenServer.call(server, :message_type_warnings)

  @doc "Returns a single type's delivery/engagement stats snapshot, or `nil` when unregistered."
  @spec message_type_stats(server(), String.t()) :: Core.MessageTypeRegistry.Stats.t() | nil
  def message_type_stats(server, type), do: GenServer.call(server, {:message_type_stats, type})

  @doc "Accounts for a presence plan after the plugin executes it."
  @spec presence_executed(server(), [Core.Presence.step()]) :: :ok
  def presence_executed(server, plan), do: GenServer.cast(server, {:presence_executed, plan})

  @doc """
  Returns a read-only snapshot of the human-entropy core state for
  `HumanEntropyWorker` to roll a cycle against, outside this GenServer.
  """
  @spec human_entropy_snapshot(server()) :: Core.HumanEntropy.t()
  def human_entropy_snapshot(server), do: GenServer.call(server, :human_entropy_snapshot)

  @doc "Records the actions a human-entropy cycle executed, for accounting."
  @spec human_entropy_executed(server(), [Core.HumanEntropy.action()]) :: :ok
  def human_entropy_executed(server, actions),
    do: GenServer.cast(server, {:human_entropy_executed, actions})

  @doc "Returns a comprehensive immutable statistics snapshot."
  @spec stats(server()) :: map()
  def stats(server), do: GenServer.call(server, :stats)

  @doc "Manually pauses all sending with an optional operator reason."
  @spec pause(server(), term()) :: :ok
  def pause(server, reason \\ :manual), do: GenServer.call(server, {:pause, reason})

  @doc "Clears the manual pause flag; risk-based auto-pause still applies."
  @spec resume(server()) :: :ok
  def resume(server), do: GenServer.call(server, :resume)

  @doc """
  Persists the latest state outside the GenServer and waits for the store.

  Use this before a graceful stop when durability of the most recent mutation
  is required.
  """
  @spec flush(server()) :: :ok | {:error, term()}
  def flush(server) do
    case GenServer.call(server, :flush_snapshot, :infinity) do
      :disabled -> :ok
      {writer, generation, snapshot} -> PersistenceWriter.flush(writer, generation, snapshot)
    end
  end

  @doc "Returns a stable bridge pid suitable for `Queue`'s `:owner` option."
  @spec queue_owner(server()) :: pid()
  def queue_owner(server) do
    {session_id, options} = GenServer.call(server, :identity)
    {:ok, owner} = EventBridgeSupervisor.ensure_bridge(session_id, options)
    owner
  end

  @doc false
  @spec identity(server()) :: {term(), keyword()}
  def identity(server), do: GenServer.call(server, :identity)

  @impl true
  def init(options) do
    now_fun = Keyword.get(options, :now_fun, fn -> System.system_time(:millisecond) end)
    now_ms = now_fun.()
    fresh = State.new(options, now_ms)
    store = store_from(options, fresh)
    {writer, writer_error} = ensure_writer(Keyword.fetch!(options, :session_id), store)
    {core, generation, restore_error} = restore(writer, fresh, now_ms)

    state = %{
      session_id: Keyword.fetch!(options, :session_id),
      core: core,
      now_fun: now_fun,
      options: options,
      store: store,
      writer: writer,
      generation: generation,
      persistence_debounce_ms: Keyword.get(options, :persistence_debounce_ms, 0),
      persistence_timer: nil,
      pause_reason: nil,
      connection_state: :never_opened
    }

    if restore_error || writer_error,
      do: send(self(), {:restore_error, restore_error || writer_error})

    {:ok, state}
  end

  @impl true
  def handle_call({:before_send, recipient, content, msg_id, reserve?}, _from, state) do
    now_ms = state.now_fun.()
    core = %{state.core | reservations: prune_reservations(state.core.reservations, now_ms)}

    case existing_reservation(core, msg_id, reserve?) do
      {:ok, decision} ->
        result = {:allow, decision}
        dispatch_decision(state, result)
        {:reply, result, %{state | core: core}}

      :none ->
        {result, candidate, effects} = decide(core, recipient, content, now_ms)
        candidate = rollback_transactional_guards(result, core, candidate)
        core = maybe_reserve(result, candidate, recipient, content, msg_id, reserve?, now_ms)
        state = %{state | core: core}
        dispatch_decision(state, result)
        state = apply_effects(state, effects) |> schedule_persistence()
        {:reply, result, state}
    end
  end

  def handle_call({:after_send, recipient, content, msg_id}, _from, state) do
    now_ms = state.now_fun.()
    reserved? = is_binary(msg_id) and Map.has_key?(state.core.reservations, msg_id)
    core = if reserved?, do: state.core, else: commit_send(state.core, recipient, content, now_ms)
    core = if is_binary(msg_id), do: track_sent(core, msg_id, now_ms), else: core

    core =
      if is_binary(msg_id),
        do: %{core | reservations: Map.delete(core.reservations, msg_id)},
        else: core

    {:reply, :ok, schedule_persistence(%{state | core: core})}
  end

  def handle_call({:receipt, receipt}, _from, state) do
    now_ms = state.now_fun.()
    {ids, status} = receipt_fields(receipt)
    {core, effects} = record_receipts(state.core, ids, status, now_ms)
    state = apply_effects(%{state | core: core}, effects) |> schedule_persistence()
    {:reply, :ok, state}
  end

  def handle_call({:disconnect, reason}, _from, state) do
    now_ms = state.now_fun.()
    {core, effects} = disconnect(state.core, normalize_disconnect(reason), now_ms)

    state =
      apply_effects(%{state | core: core, connection_state: :disconnected}, effects)
      |> schedule_persistence()

    {:reply, :ok, state}
  end

  def handle_call(:reconnect, _from, state) do
    now_ms = state.now_fun.()

    core = %{
      state.core
      | health: Core.Health.record_reconnect(state.core.health, now_ms),
        reconnect_throttle:
          Core.ReconnectThrottle.reconnect(state.core.reconnect_throttle, now_ms),
        deaf_session: Core.DeafSession.connect(state.core.deaf_session, now_ms)
    }

    {:reply, :ok, schedule_persistence(%{state | core: core, connection_state: :connected})}
  end

  def handle_call({:connection_update, connection}, _from, state)
      when connection in [:open, :connected] do
    if state.connection_state == :disconnected do
      handle_call(:reconnect, nil, state)
    else
      {:reply, :ok, %{state | connection_state: :connected}}
    end
  end

  def handle_call({:connection_update, connection}, _from, state)
      when connection in [:disconnected, :closed] do
    {:reply, :ok, %{state | connection_state: :disconnected}}
  end

  def handle_call({:timelock, update}, _from, state) do
    now_ms = state.now_fun.()
    {guard, effects} = Core.TimelockGuard.update(state.core.timelock_guard, update, now_ms)

    {core, effects} =
      apply_timelock_health(%{state.core | timelock_guard: guard}, effects, now_ms)

    state = apply_effects(%{state | core: core}, effects) |> schedule_persistence()
    {:reply, :ok, state}
  end

  def handle_call(:timelock_463, _from, state) do
    now_ms = state.now_fun.()
    {guard, effects} = Core.TimelockGuard.record_463_error(state.core.timelock_guard, now_ms)

    {core, effects} =
      apply_timelock_health(%{state.core | timelock_guard: guard}, effects, now_ms)

    state = apply_effects(%{state | core: core}, effects) |> schedule_persistence()
    {:reply, :ok, state}
  end

  def handle_call({:ban_event, event_type}, _from, state) do
    now_ms = state.now_fun.()
    {core, effects} = record_ban_event(state.core, event_type, now_ms)
    state = apply_effects(%{state | core: core}, effects) |> schedule_persistence()
    {:reply, :ok, state}
  end

  def handle_call({:incoming, jid, _text, id}, _from, state) do
    now_ms = state.now_fun.()
    reply_ratio = Core.ReplyRatio.record_received(state.core.reply_ratio, jid)
    {suggestion, reply_ratio} = Core.ReplyRatio.suggest_reply(reply_ratio, jid)

    core = %{
      state.core
      | reply_ratio: reply_ratio,
        timelock_guard: Core.TimelockGuard.register_known_chat(state.core.timelock_guard, jid),
        contact_graph: Core.ContactGraph.incoming(state.core.contact_graph, jid),
        deaf_session: Core.DeafSession.activity(state.core.deaf_session, now_ms),
        topology_throttler:
          Core.TopologyThrottler.record_replied(state.core.topology_throttler, jid, now_ms),
        human_entropy: Core.HumanEntropy.track_incoming(state.core.human_entropy, jid, id, now_ms)
    }

    {:reply, suggestion, schedule_persistence(%{state | core: core})}
  end

  def handle_call({:send_failed, error}, _from, state) do
    now_ms = state.now_fun.()

    {health, effects} =
      Core.Health.record_message_failed(state.core.health, inspect(error), now_ms)

    state = apply_effects(%{state | core: %{state.core | health: health}}, effects)
    {:reply, :ok, schedule_persistence(state)}
  end

  def handle_call({:group_operation, op, key}, _from, state) do
    now_ms = state.now_fun.()

    case Core.GroupOperationGuard.check(state.core.group_operation_guard, op, key, now_ms) do
      {:allow, guard} ->
        core = %{state.core | group_operation_guard: guard}
        dispatch_event(state, :group_operation, %{count: 1}, %{outcome: :allow, op: op})
        {:reply, {:allow, :ok}, schedule_persistence(%{state | core: core})}

      {:deny, reason, retry_after_sec, guard} ->
        core = %{state.core | group_operation_guard: guard}
        dispatch_event(state, :group_operation, %{count: 1}, %{outcome: :deny, op: op})

        decision = %{
          reason: :group_operation_limit,
          detail: reason,
          retry_after_sec: retry_after_sec
        }

        {:reply, {:deny, decision}, schedule_persistence(%{state | core: core})}
    end
  end

  def handle_call({:register_message_type, name, definition}, _from, state) do
    case Core.MessageTypeRegistry.register_message_type(
           state.core.message_type_registry,
           name,
           definition
         ) do
      {:ok, registry} ->
        core = %{state.core | message_type_registry: registry}
        {:reply, :ok, schedule_persistence(%{state | core: core})}

      {:error, reason, registry} ->
        core = %{state.core | message_type_registry: registry}
        {:reply, {:error, reason}, schedule_persistence(%{state | core: core})}
    end
  end

  def handle_call({:prepare_typed_send, recipient, content, type, opts}, _from, state) do
    now_ms = state.now_fun.()
    options = Map.put(Map.new(opts), :type, type)

    case Core.MessageTypeRegistry.prepare_send(
           state.core.message_type_registry,
           recipient,
           content,
           options,
           now_ms
         ) do
      {:ok, prepared, registry} ->
        core = %{state.core | message_type_registry: registry}
        {:reply, {:ok, prepared}, schedule_persistence(%{state | core: core})}

      {:error, reason, registry} ->
        core = %{state.core | message_type_registry: registry}
        {:reply, {:error, reason}, schedule_persistence(%{state | core: core})}
    end
  end

  def handle_call({:record_typed_send, prepared, message_id}, _from, state) do
    now_ms = state.now_fun.()

    registry =
      Core.MessageTypeRegistry.record_sent(
        state.core.message_type_registry,
        prepared,
        message_id,
        now_ms
      )

    core = %{state.core | message_type_registry: registry}
    {:reply, :ok, schedule_persistence(%{state | core: core})}
  end

  def handle_call(:message_type_warnings, _from, state) do
    now_ms = state.now_fun.()

    {warnings, registry} =
      Core.MessageTypeRegistry.warnings(state.core.message_type_registry, now_ms)

    core = %{state.core | message_type_registry: registry}
    {:reply, warnings, schedule_persistence(%{state | core: core})}
  end

  def handle_call({:message_type_stats, type}, _from, state),
    do:
      {:reply, Core.MessageTypeRegistry.get_stats(state.core.message_type_registry, type), state}

  def handle_call(:human_entropy_snapshot, _from, state),
    do: {:reply, state.core.human_entropy, state}

  def handle_call(:stats, _from, state) do
    now_ms = state.now_fun.()
    {stats, core} = stats_for(state.core, now_ms)
    {:reply, stats, %{state | core: core}}
  end

  def handle_call(:identity, _from, state),
    do: {:reply, {state.session_id, state.options}, state}

  def handle_call({:pause, reason}, _from, state) do
    core = %{state.core | health: Core.Health.set_paused(state.core.health, true)}
    dispatch_event(state, :paused, %{count: 1}, %{reason: safe_reason(reason)})
    {:reply, :ok, schedule_persistence(%{state | core: core, pause_reason: reason})}
  end

  def handle_call(:resume, _from, state) do
    core = %{state.core | health: Core.Health.set_paused(state.core.health, false)}
    dispatch_event(state, :resumed, %{count: 1}, %{})
    {:reply, :ok, schedule_persistence(%{state | core: core, pause_reason: nil})}
  end

  def handle_call(:flush_snapshot, _from, %{writer: nil} = state),
    do: {:reply, :disabled, state}

  def handle_call(:flush_snapshot, _from, state) do
    if state.persistence_timer, do: Process.cancel_timer(state.persistence_timer)
    generation = state.generation + 1
    snapshot = Snapshot.export(state.core, state.now_fun.())
    state = %{state | persistence_timer: nil, generation: generation}
    {:reply, {state.writer, generation, snapshot}, state}
  end

  @impl true
  def handle_cast({:presence_executed, plan}, state) do
    presence = Core.Presence.record_executed(state.core.presence, plan)
    {:noreply, schedule_persistence(%{state | core: %{state.core | presence: presence}})}
  end

  def handle_cast({:human_entropy_executed, actions}, state) do
    entropy = Core.HumanEntropy.record_cycle(state.core.human_entropy, actions)
    {:noreply, schedule_persistence(%{state | core: %{state.core | human_entropy: entropy}})}
  end

  @impl true
  def handle_info({:timelock_resume, generation}, state) do
    now_ms = state.now_fun.()
    {guard, effects} = Core.TimelockGuard.resume(state.core.timelock_guard, generation, now_ms)
    state = apply_effects(%{state | core: %{state.core | timelock_guard: guard}}, effects)
    {:noreply, schedule_persistence(state)}
  end

  def handle_info(:persist_now, %{writer: nil} = state),
    do: {:noreply, %{state | persistence_timer: nil}}

  def handle_info(:persist_now, state) do
    snapshot = Snapshot.export(state.core, state.now_fun.())

    case PersistenceWriter.save(state.writer, state.generation, snapshot) do
      :ok ->
        {:noreply, %{state | persistence_timer: nil}}

      {:error, reason} ->
        dispatch_event(state, :persistence_failed, %{count: 1}, %{reason: safe_reason(reason)})
        timer = Process.send_after(self(), :persist_now, 10)
        {:noreply, %{state | persistence_timer: timer}}
    end
  end

  def handle_info({:restore_error, error}, state) do
    dispatch_event(state, :restore_failed, %{count: 1}, %{reason: safe_reason(error)})
    {:noreply, state}
  end

  def handle_info({:amarula_antiban, :queue, :sent, %{msg_id: msg_id}}, state)
      when is_binary(msg_id) do
    now_ms = state.now_fun.()
    core = track_sent(state.core, msg_id, now_ms)
    core = %{core | reservations: Map.delete(core.reservations, msg_id)}
    {:noreply, schedule_persistence(%{state | core: core})}
  end

  def handle_info({:amarula_antiban, :queue, _action, _payload}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp decide(core, recipient, content, now_ms) do
    {health_status, health} = Core.Health.status(core.health, now_ms)
    {paused?, health} = Core.Health.paused?(health, now_ms)
    core = %{core | health: health}

    if paused? do
      deny(core, health_status, :health_paused, health_status.recommendation, 0, [])
    else
      decide_ban_recovery(core, recipient, content, health_status, now_ms)
    end
  end

  defp decide_ban_recovery(core, recipient, content, health_status, now_ms) do
    ban_status = Core.BanRecovery.status(core.ban_recovery, now_ms)

    if ban_status.phase in [:paused, :dead] do
      deny(core, health_status, :ban_recovery, ban_status.recommendation, 0, [])
    else
      core = apply_ban_recovery_rate(core, ban_status)
      decide_timelock(core, recipient, content, health_status, now_ms)
    end
  end

  defp decide_timelock(core, recipient, content, health_status, now_ms) do
    case Core.TimelockGuard.can_send(core.timelock_guard, recipient, now_ms) do
      {:deny, detail, guard} ->
        deny(%{core | timelock_guard: guard}, health_status, :timelock, detail, 0, [])

      {:allow, guard, effects} ->
        decide_warm_up(
          %{core | timelock_guard: guard},
          recipient,
          content,
          health_status,
          now_ms,
          effects
        )
    end
  end

  defp decide_warm_up(core, recipient, content, health_status, now_ms, effects) do
    case Core.WarmUp.can_send(core.warm_up, now_ms) do
      {false, warm_up} ->
        {status, warm_up} = Core.WarmUp.status(warm_up, now_ms)
        detail = "Warm-up limit: #{status.today_sent}/#{status.today_limit} messages today"

        deny(
          %{core | warm_up: warm_up},
          health_status,
          :warmup_limit,
          detail,
          0,
          effects,
          status.day
        )

      {true, warm_up} ->
        decide_contact(
          %{core | warm_up: warm_up},
          recipient,
          content,
          health_status,
          now_ms,
          effects
        )
    end
  end

  defp decide_contact(core, recipient, content, health_status, now_ms, effects) do
    case Core.ContactGraph.can_message(core.contact_graph, recipient, now_ms) do
      {:deny, detail, _needs_handshake, graph} ->
        deny(%{core | contact_graph: graph}, health_status, :contact_graph, detail, 0, effects)

      {:allow, _needs_handshake, graph} ->
        decide_topology(
          %{core | contact_graph: graph},
          recipient,
          content,
          health_status,
          now_ms,
          effects
        )
    end
  end

  defp decide_topology(core, recipient, content, health_status, now_ms, effects) do
    case Core.TopologyThrottler.before_send(core.topology_throttler, recipient, now_ms) do
      {:deny, reason, throttler} ->
        deny(
          %{core | topology_throttler: throttler},
          health_status,
          :topology_throttle,
          reason,
          0,
          effects
        )

      {:allow, _recommendation, delay_ms, throttler} ->
        decide_reply_ratio(
          %{core | topology_throttler: throttler},
          recipient,
          content,
          health_status,
          now_ms,
          effects,
          delay_ms
        )
    end
  end

  defp decide_reply_ratio(
         core,
         recipient,
         content,
         health_status,
         now_ms,
         effects,
         topology_delay_ms
       ) do
    case Core.ReplyRatio.before_send(core.reply_ratio, recipient, now_ms) do
      {:deny, detail, ratio} ->
        deny(%{core | reply_ratio: ratio}, health_status, :reply_ratio, detail, 0, effects)

      {:allow, ratio} ->
        decide_reconnect(
          %{core | reply_ratio: ratio},
          recipient,
          content,
          health_status,
          now_ms,
          effects,
          topology_delay_ms
        )
    end
  end

  defp decide_reconnect(
         core,
         recipient,
         content,
         health_status,
         now_ms,
         effects,
         topology_delay_ms
       ) do
    case Core.ReconnectThrottle.before_send(core.reconnect_throttle, now_ms) do
      {:deny, detail, retry_after_ms, throttle} ->
        deny(
          %{core | reconnect_throttle: throttle},
          health_status,
          :reconnect_throttle,
          detail,
          retry_after_ms,
          effects
        )

      {:allow, throttle} ->
        decide_group_profile(
          %{core | reconnect_throttle: throttle},
          recipient,
          content,
          health_status,
          now_ms,
          effects,
          topology_delay_ms
        )
    end
  end

  defp decide_group_profile(
         core,
         recipient,
         content,
         health_status,
         now_ms,
         effects,
         topology_delay_ms
       ) do
    {rate_stats, limiter} = Core.RateLimiter.stats(core.rate_limiter, now_ms)
    core = %{core | rate_limiter: limiter}

    if group_limit_exceeded?(core.config, recipient, rate_stats) do
      deny(core, health_status, :group_rate_limit, "Group rate limit exceeded", 0, effects)
    else
      decide_rate(core, recipient, content, health_status, now_ms, effects, topology_delay_ms)
    end
  end

  defp decide_rate(core, recipient, content, health_status, now_ms, effects, topology_delay_ms) do
    case Core.RateLimiter.get_delay(core.rate_limiter, recipient, content, now_ms) do
      {:deny, reason, limiter} ->
        deny(
          %{core | rate_limiter: limiter},
          health_status,
          reason,
          Atom.to_string(reason),
          0,
          effects
        )

      {:allow, delay_ms, limiter} ->
        core = %{core | rate_limiter: limiter}
        {delay_ms, presence, plan} = presence_decision(core, recipient, content, delay_ms, now_ms)
        plan_delay_ms = Enum.sum(Enum.map(plan, &effect_delay/1))
        delay_ms = delay_ms + topology_delay_ms

        {varied, content_variator} = Core.ContentVariator.vary(core.content_variator, content)
        varied_content = if varied != content, do: varied, else: nil
        {typo, legitimacy_signals} = maybe_inject_typo(core.legitimacy_signals, varied)

        core = %{
          core
          | presence: presence,
            content_variator: content_variator,
            legitimacy_signals: legitimacy_signals,
            total_delay_ms: core.total_delay_ms + delay_ms + plan_delay_ms
        }

        decision = %Decision{
          allowed: true,
          delay_ms: delay_ms,
          health: health_status,
          presence_plan: plan,
          typo: typo,
          varied_content: varied_content
        }

        {{:allow, decision}, core, effects}
    end
  end

  defp maybe_inject_typo(injector, content) do
    case Core.LegitimacySignals.maybe_inject_typo(injector, content) do
      {:none, injector} -> {nil, injector}
      {:typo, typo, injector} -> {typo, injector}
    end
  end

  defp presence_decision(core, recipient, content, delay_ms, now_ms) do
    activity_factor = Core.Presence.activity_factor(core.presence, now_ms)

    delay_ms =
      if activity_factor < 1.0,
        do: floor(delay_ms * min(5.0, 1.0 / activity_factor)),
        else: delay_ms

    delay_ms =
      if core.contact_graph.config.enabled do
        multiplier =
          contact_delay_multiplier(Core.ContactGraph.contact_state(core.contact_graph, recipient))

        floor(delay_ms * multiplier)
      else
        delay_ms
      end

    {distraction, presence} = Core.Presence.distraction_pause(core.presence)
    {offline, presence} = Core.Presence.offline_gap(presence)
    {typing, presence} = Core.Presence.plan(presence, content, now_ms)
    plan = effect_steps(distraction) ++ effect_steps(offline) ++ typing
    {delay_ms, presence, plan}
  end

  defp deny(core, health, reason, detail, delay_ms, effects, warmup_day \\ nil) do
    decision = %Decision{
      allowed: false,
      delay_ms: delay_ms,
      reason: reason,
      detail: detail,
      health: health,
      warmup_day: warmup_day
    }

    {{:deny, decision}, %{core | messages_blocked: core.messages_blocked + 1}, effects}
  end

  defp maybe_reserve(
         {:allow, decision},
         core,
         recipient,
         content,
         msg_id,
         true,
         now_ms
       )
       when is_binary(msg_id) do
    reservation = %{
      recipient: recipient,
      content: content,
      reserved_at: now_ms,
      decision: decision
    }

    core = commit_send(core, recipient, content, now_ms)
    %{core | reservations: Map.put(core.reservations, msg_id, reservation)}
  end

  defp maybe_reserve(
         _result,
         core,
         _recipient,
         _content,
         _msg_id,
         _reserve?,
         _now_ms
       ),
       do: core

  defp existing_reservation(core, msg_id, true) when is_binary(msg_id) do
    case Map.get(core.reservations, msg_id) do
      %{decision: %Decision{} = decision} -> {:ok, decision}
      %{decision: decision} when is_map(decision) -> {:ok, struct(Decision, decision)}
      _missing -> :none
    end
  end

  defp existing_reservation(_core, _msg_id, _reserve?), do: :none

  defp rollback_transactional_guards({:allow, _decision}, _before, candidate), do: candidate

  defp rollback_transactional_guards({:deny, _decision}, before, candidate) do
    %{
      candidate
      | contact_graph: before.contact_graph,
        reconnect_throttle: before.reconnect_throttle
    }
  end

  defp commit_send(core, recipient, content, now_ms) do
    %{
      core
      | rate_limiter: Core.RateLimiter.record(core.rate_limiter, recipient, content, now_ms),
        warm_up: Core.WarmUp.record(core.warm_up, now_ms),
        reply_ratio: Core.ReplyRatio.record_sent(core.reply_ratio, recipient),
        timelock_guard: Core.TimelockGuard.register_known_chat(core.timelock_guard, recipient),
        topology_throttler:
          Core.TopologyThrottler.record_sent(core.topology_throttler, recipient, now_ms),
        messages_allowed: core.messages_allowed + 1
    }
  end

  defp track_sent(core, msg_id, now_ms) do
    %{core | delivery_tracker: Core.DeliveryTracker.sent(core.delivery_tracker, msg_id, now_ms)}
  end

  defp record_receipts(core, ids, status, now_ms) when status in [:delivered, :read, :played] do
    Enum.reduce(ids, {core, []}, fn id, {core, effects} ->
      {tracker, tracker_effects} = Core.DeliveryTracker.receipt(core.delivery_tracker, id, now_ms)

      registry =
        if status == :read,
          do: Core.MessageTypeRegistry.record_read(core.message_type_registry, id),
          else: Core.MessageTypeRegistry.record_delivered(core.message_type_registry, id)

      core = %{
        core
        | delivery_tracker: tracker,
          retry_tracker: Core.RetryTracker.clear(core.retry_tracker, id),
          message_type_registry: registry
      }

      {core, effects ++ tracker_effects}
    end)
  end

  defp record_receipts(core, _ids, _status, _now_ms), do: {core, []}

  defp disconnect(core, 515, _now_ms) do
    classification = Core.Disconnect.classify(515)
    core = %{core | deaf_session: Core.DeafSession.disconnect(core.deaf_session)}
    {core, [{:protocol_restart, classification}]}
  end

  defp disconnect(core, 401, now_ms) do
    {health, health_effects} = Core.Health.record_disconnect(core.health, 401, now_ms)
    {core, ban_effects} = record_ban_event(%{core | health: health}, :hard_ban, now_ms)
    core = %{core | deaf_session: Core.DeafSession.disconnect(core.deaf_session)}
    {core, health_effects ++ ban_effects}
  end

  defp disconnect(core, reason, now_ms) do
    {health, effects} =
      Core.Health.record_disconnect(core.health, normalize_disconnect(reason), now_ms)

    core = %{core | health: health, deaf_session: Core.DeafSession.disconnect(core.deaf_session)}
    {core, effects}
  end

  defp apply_timelock_health(core, effects, now_ms) do
    if Enum.any?(effects, &match?({:timelock_detected, _state}, &1)) do
      detail = core.timelock_guard.enforcement_type
      {health, health_effects} = Core.Health.record_reachout_timelock(core.health, detail, now_ms)
      {%{core | health: health}, effects ++ health_effects}
    else
      {core, effects}
    end
  end

  defp apply_ban_recovery_rate(core, %{rate_multiplier: 1.0}), do: core

  defp apply_ban_recovery_rate(core, %{rate_multiplier: multiplier}) do
    %{core | rate_limiter: Core.RateLimiter.adapt_limits(core.rate_limiter, multiplier)}
  end

  defp record_ban_event(core, event_type, now_ms) do
    {ban_recovery, effects} =
      Core.BanRecovery.record_ban_event(core.ban_recovery, event_type, now_ms)

    {%{core | ban_recovery: ban_recovery}, effects}
  end

  defp apply_effects(state, effects) do
    Enum.reduce(effects, state, fn
      {:schedule_resume, generation, delay_ms}, state ->
        Process.send_after(self(), {:timelock_resume, generation}, delay_ms)
        state

      {:risk_changed, %{risk: :critical}} = effect, state ->
        dispatch_effect(state, effect)
        apply_soft_ban(state)

      effect, state ->
        dispatch_effect(state, effect)
        state
    end)
  end

  defp apply_soft_ban(state) do
    now_ms = state.now_fun.()
    {core, ban_effects} = record_ban_event(state.core, :soft_ban, now_ms)
    state = %{state | core: core}
    Enum.each(ban_effects, &dispatch_effect(state, &1))
    state
  end

  defp dispatch_effect(state, {:risk_changed, status}) do
    callback = state.core.config.on_risk_change
    at_risk = state.core.config.on_at_risk

    dispatch_task(fn ->
      :telemetry.execute(
        [:amarula_antiban, :session, :risk_changed],
        %{score: status.score},
        %{session_id: state.session_id, risk: status.risk}
      )

      invoke_callback(callback, [status])
      if status.risk in [:high, :critical], do: invoke_callback(at_risk, [status])
    end)
  end

  defp dispatch_effect(state, {:timelock_detected, lock_state}) do
    dispatch_named_effect(
      state,
      :timelock_detected,
      lock_state,
      state.core.config.on_timelock_detected
    )
  end

  defp dispatch_effect(state, {:timelock_lifted, lock_state}) do
    dispatch_named_effect(
      state,
      :timelock_lifted,
      lock_state,
      state.core.config.on_timelock_lifted
    )
  end

  defp dispatch_effect(state, {:low_delivery_rate, rate}) do
    dispatch_event(state, :low_delivery_rate, %{delivery_rate: rate}, %{})
  end

  defp dispatch_effect(state, {:recovery_started, status}) do
    dispatch_named_effect(
      state,
      :recovery_started,
      status,
      state.core.config.on_recovery_phase_change
    )
  end

  defp dispatch_effect(state, {:recovery_escalated, payload}) do
    dispatch_named_effect(state, :recovery_escalated, payload, nil)
  end

  defp dispatch_effect(state, {:hard_ban_detected, status}) do
    dispatch_named_effect(state, :hard_ban_detected, status, state.core.config.on_hard_ban)
  end

  defp dispatch_effect(state, {:protocol_restart, classification}) do
    dispatch_event(state, :protocol_restart, %{count: 1}, %{code: classification.code})
  end

  defp dispatch_effect(state, effect) do
    dispatch_event(state, :effect, %{count: 1}, %{effect: effect_tag(effect)})
  end

  defp dispatch_named_effect(state, name, payload, callback) do
    dispatch_task(fn ->
      :telemetry.execute(
        [:amarula_antiban, :session, name],
        %{count: 1},
        %{session_id: state.session_id}
      )

      invoke_callback(callback, [payload])
    end)
  end

  defp dispatch_decision(state, {outcome, decision}) do
    metadata = %{session_id: state.session_id, outcome: outcome, reason: decision.reason}
    dispatch_event(state, :decision, %{delay_ms: decision.delay_ms}, metadata)
  end

  defp dispatch_event(state, name, measurements, metadata) do
    metadata = Map.put(metadata, :session_id, state.session_id)

    dispatch_task(fn ->
      :telemetry.execute([:amarula_antiban, :session, name], measurements, metadata)
    end)
  end

  defp dispatch_task(fun) do
    case Process.whereis(AmarulaAntiban.Session.TaskSupervisor) do
      nil ->
        :ok

      _pid ->
        _ = Task.Supervisor.start_child(AmarulaAntiban.Session.TaskSupervisor, fun)
        :ok
    end
  end

  defp invoke_callback(callback, arguments) when is_function(callback),
    do: apply(callback, arguments)

  defp invoke_callback(_callback, _arguments), do: :ok

  defp schedule_persistence(state) do
    state = %{state | generation: state.generation + 1}

    if state.persistence_timer,
      do: Process.cancel_timer(state.persistence_timer)

    schedule_persistence_timer(%{state | persistence_timer: nil})
  end

  defp schedule_persistence_timer(%{writer: nil} = state), do: state

  defp schedule_persistence_timer(state) do
    timer = Process.send_after(self(), :persist_now, state.persistence_debounce_ms)
    %{state | persistence_timer: timer}
  end

  defp ensure_writer(_session_id, nil), do: {nil, nil}

  defp ensure_writer(session_id, store) do
    case PersistenceSupervisor.ensure_writer(session_id, store) do
      {:ok, _writer} -> {PersistenceWriter.via(session_id), nil}
      {:error, reason} -> {nil, reason}
    end
  end

  defp restore(nil, fresh, _now_ms), do: {fresh, 0, nil}

  defp restore(writer, fresh, now_ms) do
    case PersistenceWriter.load(writer) do
      {:ok, nil} ->
        {fresh, 0, nil}

      {:ok, snapshot} ->
        generation = snapshot_generation(snapshot)

        case Snapshot.restore(snapshot, fresh, now_ms) do
          {:ok, restored} -> {restored, generation, nil}
          {:error, reason} -> {fresh, generation, reason}
        end

      {:error, reason} ->
        {fresh, 0, reason}
    end
  end

  defp snapshot_generation(%{"generation" => generation})
       when is_integer(generation) and generation >= 0,
       do: generation

  defp snapshot_generation(_snapshot), do: 0

  defp stats_for(core, now_ms) do
    {health, health_state} = Core.Health.status(core.health, now_ms)
    {warm_up, warm_up_state} = Core.WarmUp.status(core.warm_up, now_ms)
    {rate_limiter, rate_state} = Core.RateLimiter.stats(core.rate_limiter, now_ms)
    {delivery_tracker, delivery_state} = Core.DeliveryTracker.stats(core.delivery_tracker, now_ms)

    {topology_throttler, topology_state} =
      Core.TopologyThrottler.stats(core.topology_throttler, now_ms)

    stats = %{
      messages_allowed: core.messages_allowed,
      messages_blocked: core.messages_blocked,
      total_delay_ms: core.total_delay_ms,
      health: health,
      warm_up: warm_up,
      rate_limiter: rate_limiter,
      reply_ratio: Core.ReplyRatio.stats(core.reply_ratio, now_ms),
      contact_graph: Core.ContactGraph.stats(core.contact_graph),
      presence: Core.Presence.stats(core.presence, now_ms),
      retry_tracker: Core.RetryTracker.stats(core.retry_tracker),
      reconnect_throttle: Core.ReconnectThrottle.stats(core.reconnect_throttle, now_ms),
      delivery_tracker: delivery_tracker,
      circuit_breaker: Core.JidCircuitBreaker.stats(core.circuit_breaker),
      session_health: Core.SessionHealth.stats(core.session_health),
      jid_canonicalizer: Core.JidCanonicalizer.stats(core.jid_canonicalizer),
      topology_throttler: topology_throttler,
      ban_recovery: Core.BanRecovery.status(core.ban_recovery, now_ms),
      legitimacy_signals: Core.LegitimacySignals.stats(core.legitimacy_signals),
      group_operation_guard: Core.GroupOperationGuard.stats(core.group_operation_guard),
      human_entropy: Core.HumanEntropy.stats(core.human_entropy),
      content_variator: Core.ContentVariator.stats(core.content_variator),
      message_type_registry: Core.MessageTypeRegistry.overview(core.message_type_registry)
    }

    core = %{
      core
      | health: health_state,
        warm_up: warm_up_state,
        rate_limiter: rate_state,
        delivery_tracker: delivery_state,
        topology_throttler: topology_state
    }

    {stats, core}
  end

  defp store_from(options, core) do
    options
    |> Keyword.get(:state_store, Keyword.get(options, :persist, core.config.persist))
    |> StateStore.normalize()
  end

  defp group_limit_exceeded?(%{group_profiles: false}, _recipient, _stats), do: false

  defp group_limit_exceeded?(config, recipient, stats) do
    if Jid.group_profile?(recipient) do
      limits =
        Jid.apply_group_multiplier(
          %{
            max_per_minute: stats.limits.per_minute,
            max_per_hour: stats.limits.per_hour,
            max_per_day: stats.limits.per_day
          },
          config.group_multiplier
        )

      stats.last_minute >= limits.max_per_minute or
        stats.last_hour >= limits.max_per_hour or
        stats.last_day >= limits.max_per_day
    else
      false
    end
  end

  defp contact_delay_multiplier(:stranger), do: 2.5
  defp contact_delay_multiplier(:handshake_sent), do: 1.8
  defp contact_delay_multiplier(:handshake_complete), do: 1.3
  defp contact_delay_multiplier(:known), do: 1.0

  defp effect_delay({_, delay_ms}) when is_integer(delay_ms), do: delay_ms
  defp effect_delay(:none), do: 0

  defp effect_steps(:none), do: []
  defp effect_steps({_kind, duration_ms} = step) when is_integer(duration_ms), do: [step]

  defp receipt_fields(id) when is_binary(id), do: {[id], :delivered}

  defp receipt_fields(receipt) when is_map(receipt) do
    ids = Map.get(receipt, :message_ids, Map.get(receipt, "message_ids", []))
    status = Map.get(receipt, :status, Map.get(receipt, "status")) |> normalize_status()
    {List.wrap(ids), status}
  end

  defp normalize_status(status) when status in [:delivered, :server_ack, :read, :played],
    do: status

  defp normalize_status("delivered"), do: :delivered
  defp normalize_status("server_ack"), do: :server_ack
  defp normalize_status("read"), do: :read
  defp normalize_status("played"), do: :played
  defp normalize_status(_status), do: :unknown

  defp normalize_disconnect({:stream_error, code, _reason}), do: code
  defp normalize_disconnect(reason), do: reason

  defp prune_reservations(reservations, now_ms) do
    Map.reject(reservations, fn {_id, reservation} ->
      now_ms - reservation.reserved_at > @reservation_retention_ms
    end)
  end

  defp safe_reason(reason) when is_atom(reason) or is_integer(reason), do: reason
  defp safe_reason({tag, _detail}) when is_atom(tag), do: tag
  defp safe_reason(_reason), do: :other

  defp effect_tag({tag, _payload}) when is_atom(tag), do: tag
  defp effect_tag({tag, _payload, _extra}) when is_atom(tag), do: tag
  defp effect_tag(tag) when is_atom(tag), do: tag
  defp effect_tag(_effect), do: :other
end
