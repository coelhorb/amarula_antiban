defmodule AmarulaAntiban.Queue do
  @moduledoc """
  Supervisable FIFO/priority queue backed by `:queue`.

  The supplied `send_fun` receives `{recipient, content}` and runs in a
  supervised, monitored task. It may return `:ok`, the Amarula result
  `{:ok, msg_id}`, or `{:error, reason}`. The queue process never performs the
  send itself, so `stats/1`, `add/4`, and lifecycle calls remain responsive.

  A message remains in the exported snapshot while it is being processed and
  is removed only after success. Send timeout, task failure, and a restored
  snapshot requeue it under an **at-least-once** policy. Consequently, a crash
  after remote success but before the Queue observes it can cause a duplicate
  send. Exactly-once delivery would require a transactional outbox shared with
  the transport and is outside this module's scope.

  `stop/1` stops periodic draining but lets an in-flight send finish. `remove/2`
  returns `false` for the in-flight message, and `clear/1` preserves it while
  removing every other message.
  """
  use GenServer

  alias AmarulaAntiban.Telemetry

  defmodule Message do
    @moduledoc false
    @type t :: %__MODULE__{
            id: String.t(),
            recipient: String.t(),
            content: term(),
            priority: :high | :normal | :low,
            added_at: integer(),
            attempts: non_neg_integer(),
            max_attempts: pos_integer(),
            last_error: String.t() | nil,
            scheduled_for: integer() | nil,
            metadata: term(),
            sequence: non_neg_integer(),
            transport_msg_id: String.t() | nil
          }
    defstruct [
      :id,
      :recipient,
      :content,
      :priority,
      :added_at,
      :attempts,
      :max_attempts,
      :last_error,
      :scheduled_for,
      :metadata,
      :sequence,
      :transport_msg_id
    ]
  end

  @type processing :: %{
          operation_ref: reference(),
          monitor_ref: reference(),
          pid: pid(),
          timeout_ref: reference(),
          message_id: String.t(),
          reply_to: GenServer.from() | nil
        }

  @type state :: %{
          config: map(),
          queues: %{
            high: :queue.queue(Message.t()),
            normal: :queue.queue(Message.t()),
            low: :queue.queue(Message.t())
          },
          running: boolean(),
          timer: reference() | nil,
          drain_generation: non_neg_integer(),
          counter: non_neg_integer(),
          generation: non_neg_integer(),
          processing: processing() | nil,
          send_fun: (String.t(), term() -> term()) | nil,
          owner: pid() | nil
        }

  @priorities [:high, :normal, :low]
  @term_encoding "erlang-term/base64"
  @defaults %{
    max_attempts: 3,
    retry_base_delay_ms: 30_000,
    max_queue_size: 1_000,
    priority_order: true,
    interval_ms: 1_000,
    send_timeout_ms: 90_000,
    task_supervisor: AmarulaAntiban.Queue.TaskSupervisor
  }

  @doc "Starts a queue. Use `start_supervised!/1` in tests."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @doc """
  Adds one message and returns its generated ID, or `{:error, :full}`.

  This call deliberately waits indefinitely: the handler only validates and
  enqueues in memory, so a default call timeout cannot expire and leave a
  surprising late addition in the server mailbox.
  """
  @spec add(GenServer.server(), String.t(), term(), keyword()) ::
          {:ok, String.t()} | {:error, :full}
  def add(server, recipient, content, options \\ []),
    do: GenServer.call(server, {:add, recipient, content, options}, :infinity)

  @doc "Sets the function used by supervised send tasks."
  @spec set_send_fun(GenServer.server(), (String.t(), term() -> term())) :: :ok
  def set_send_fun(server, fun) when is_function(fun, 2),
    do: GenServer.call(server, {:send_fun, fun})

  @doc "Begins periodic draining."
  @spec start(GenServer.server()) :: :ok
  def start(server), do: GenServer.call(server, :start)

  @doc "Stops periodic draining without aborting the in-flight send."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.call(server, :stop)

  @doc """
  Drains at most one eligible message now.

  The caller waits for the queue's explicit `:send_timeout_ms`, rather than a
  shorter implicit `GenServer.call/3` timeout. Returns `:busy` if another send
  is already in flight.
  """
  @spec drain(GenServer.server()) ::
          :empty
          | :busy
          | :sent
          | {:sent, String.t()}
          | :delayed
          | {:retry, non_neg_integer()}
          | {:failed, term()}
          | {:error, :send_fun_not_set}
  def drain(server), do: GenServer.call(server, :drain, :infinity)

  @doc "Returns queue counts without exposing payloads."
  @spec stats(GenServer.server()) :: map()
  def stats(server), do: GenServer.call(server, :stats)

  @doc """
  Exports a JSON-safe snapshot of pending and in-flight messages.

  Arbitrary Elixir content and metadata are encoded as tagged Erlang external
  terms so the result always survives `Jason.encode!/1` and `Jason.decode!/1`.
  """
  @spec export(GenServer.server()) :: [map()]
  def export(server), do: GenServer.call(server, :export)

  @doc """
  Restores exported or legacy snapshots.

  A snapshot item marked as processing is restored as pending (at-least-once).
  Priority mode sorts by priority, `added_at`, then stable sequence, matching
  upstream `sortQueue()`. Restore is rejected while a local send is in flight.
  """
  @spec restore(GenServer.server(), [map() | Message.t()]) :: :ok | {:error, :processing}
  def restore(server, messages) when is_list(messages),
    do: GenServer.call(server, {:restore, messages}, :infinity)

  @doc "Removes a message by ID; returns `false` for the in-flight message."
  @spec remove(GenServer.server(), String.t()) :: boolean()
  def remove(server, id), do: GenServer.call(server, {:remove, id})

  @doc "Removes all queued messages except the in-flight message and returns the count removed."
  @spec clear(GenServer.server()) :: non_neg_integer()
  def clear(server), do: GenServer.call(server, :clear)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    config =
      @defaults
      |> Map.merge(Map.new(options))
      |> Map.put_new(:now_fun, fn -> System.system_time(:millisecond) end)

    {:ok,
     %{
       config: config,
       queues: empty_queues(),
       running: false,
       timer: nil,
       drain_generation: 0,
       counter: 0,
       generation: 0,
       processing: nil,
       send_fun: nil,
       owner: Map.get(config, :owner)
     }}
  end

  @impl true
  def handle_call({:send_fun, fun}, _from, state), do: {:reply, :ok, %{state | send_fun: fun}}

  def handle_call({:add, recipient, content, options}, _from, state) do
    if total(state) >= state.config.max_queue_size do
      {:reply, {:error, :full}, state}
    else
      now = state.config.now_fun.()
      priority = Keyword.get(options, :priority, :normal)
      sequence = state.counter + 1
      id = "msg_#{now}_#{sequence}"

      message = %Message{
        id: id,
        recipient: recipient,
        content: content,
        priority: priority,
        added_at: now,
        attempts: 0,
        max_attempts: state.config.max_attempts,
        scheduled_for: Keyword.get(options, :scheduled_for),
        metadata: Keyword.get(options, :metadata),
        sequence: sequence
      }

      state = enqueue(state, message) |> Map.put(:counter, sequence)

      notify(state, :added, %{count: 1}, %{queue_id: id, priority: priority})
      {:reply, {:ok, id}, state}
    end
  end

  def handle_call(:start, _from, %{running: true} = state), do: {:reply, :ok, state}

  def handle_call(:start, _from, state) do
    state = %{state | running: true, drain_generation: state.drain_generation + 1}
    notify(state, :started, %{count: 1}, %{})
    {:reply, :ok, schedule(state)}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, stop_timer(state, :stopped)}

  def handle_call(:drain, _from, %{processing: processing} = state)
      when not is_nil(processing),
      do: {:reply, :busy, state}

  def handle_call(:drain, from, state) do
    case begin_processing(state, from) do
      {:started, state} -> {:noreply, state}
      {:finished, result, state} -> {:reply, result, state}
    end
  end

  def handle_call(:stats, _from, state), do: {:reply, stats_for(state), state}

  def handle_call(:export, _from, state) do
    processing_id = if state.processing, do: state.processing.message_id
    messages = Enum.map(all_messages(state), &message_to_snapshot(&1, &1.id == processing_id))
    {:reply, messages, state}
  end

  def handle_call({:restore, _messages}, _from, %{processing: processing} = state)
      when not is_nil(processing),
      do: {:reply, {:error, :processing}, state}

  def handle_call({:restore, messages}, _from, state) do
    messages =
      messages
      |> Enum.with_index(1)
      |> Enum.map(fn {message, sequence} -> message_from_map(message, sequence) end)
      |> sort_messages(state.config.priority_order)

    queues = queues_from_messages(messages)

    counter =
      Enum.reduce(messages, state.counter, fn message, counter ->
        max(counter, max(id_counter(message.id), message.sequence))
      end)

    {:reply, :ok, %{state | queues: queues, counter: counter}}
  end

  def handle_call({:remove, id}, _from, %{processing: %{message_id: id}} = state),
    do: {:reply, false, state}

  def handle_call({:remove, id}, _from, state) do
    {removed, state} = remove_id(state, id)
    {:reply, removed, state}
  end

  def handle_call(:clear, _from, state) do
    processing_id = if state.processing, do: state.processing.message_id
    kept = Enum.filter(all_messages(state), &(&1.id == processing_id))
    removed = total(state) - length(kept)
    state = %{state | queues: queues_from_messages(kept)}
    notify(state, :cleared, %{count: removed}, %{})
    {:reply, removed, state}
  end

  @impl true
  def handle_info(
        {:drain, generation},
        %{running: true, drain_generation: generation} = state
      ) do
    state = %{state | timer: nil}

    state =
      if state.processing do
        state
      else
        case begin_processing(state, nil) do
          {:started, state} -> state
          {:finished, _result, state} -> state
        end
      end

    {:noreply, if(state.running, do: schedule(state), else: state)}
  end

  # A timer may already be in the mailbox when stop/1 invalidates its generation.
  def handle_info({:drain, _stale_generation}, state), do: {:noreply, state}
  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info(
        {:queue_send_result, operation_ref, result},
        %{processing: %{operation_ref: operation_ref} = processing} = state
      ) do
    cancel_processing_watchers(processing)
    {reply, state} = complete_result(%{state | processing: nil}, processing.message_id, result)
    reply_waiter(processing.reply_to, reply)
    {:noreply, state}
  end

  def handle_info(
        {:queue_send_timeout, operation_ref},
        %{processing: %{operation_ref: operation_ref} = processing} = state
      ) do
    Process.exit(processing.pid, :kill)
    cancel_processing_watchers(processing)

    {reply, state} =
      complete_result(%{state | processing: nil}, processing.message_id, {:error, :send_timeout})

    reply_waiter(processing.reply_to, reply)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, reason},
        %{processing: %{monitor_ref: monitor_ref} = processing} = state
      ) do
    cancel_timeout(processing.timeout_ref)

    {reply, state} =
      complete_result(
        %{state | processing: nil},
        processing.message_id,
        {:error, {:send_task_down, reason}}
      )

    reply_waiter(processing.reply_to, reply)
    {:noreply, state}
  end

  # Result, timeout, and DOWN messages from an older generation are intentionally ignored.
  def handle_info({:queue_send_result, _operation_ref, _result}, state), do: {:noreply, state}
  def handle_info({:queue_send_timeout, _operation_ref}, state), do: {:noreply, state}
  def handle_info({:DOWN, _monitor_ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{processing: %{pid: pid}}) do
    Process.exit(pid, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp begin_processing(%{send_fun: nil} = state, _reply_to),
    do: {:finished, {:error, :send_fun_not_set}, state}

  defp begin_processing(state, reply_to) do
    case eligible_message(state) do
      nil ->
        {:finished, :empty, state}

      message ->
        message = %{message | attempts: message.attempts + 1, transport_msg_id: nil}
        state = update_message(state, message)
        generation = state.generation + 1
        operation_ref = make_ref()
        queue = self()
        send_fun = state.send_fun

        task_fun = fn ->
          # The supervisor owns restart/accounting; this link owns cancellation.
          # It is established before send_fun so a brutally killed Queue cannot
          # leave an uncorrelated transport task behind.
          Process.link(queue)
          result = send_fun.(message.recipient, message.content)
          send(queue, {:queue_send_result, operation_ref, result})
        end

        case Task.Supervisor.start_child(state.config.task_supervisor, task_fun) do
          {:ok, pid} ->
            monitor_ref = Process.monitor(pid)

            timeout_ref =
              Process.send_after(
                self(),
                {:queue_send_timeout, operation_ref},
                state.config.send_timeout_ms
              )

            processing = %{
              operation_ref: operation_ref,
              monitor_ref: monitor_ref,
              pid: pid,
              timeout_ref: timeout_ref,
              message_id: message.id,
              reply_to: reply_to
            }

            {:started, %{state | generation: generation, processing: processing}}

          {:error, reason} ->
            {result, state} =
              complete_result(state, message.id, {:error, {:send_task_start, reason}})

            {:finished, result, %{state | generation: generation}}
        end
    end
  end

  defp complete_result(state, message_id, result) do
    case find_message(state, message_id) do
      nil ->
        {{:failed, :message_missing}, state}

      message ->
        apply_send_result(state, message, result)
    end
  end

  defp apply_send_result(state, message, :ok), do: sent(state, message, nil)

  defp apply_send_result(state, message, {:ok, msg_id}) when is_binary(msg_id),
    do: sent(state, message, msg_id)

  defp apply_send_result(state, message, {:error, {:antiban, _} = reason}),
    do: delayed(state, message, reason)

  defp apply_send_result(state, message, {:error, {:halted, {:antiban, _} = reason}}),
    do: delayed(state, message, reason)

  defp apply_send_result(state, message, {:error, reason}),
    do: failed_or_retry(state, message, reason)

  defp apply_send_result(state, message, other),
    do: failed_or_retry(state, message, {:invalid_send_result, other})

  defp sent(state, message, nil) do
    notify(
      state,
      :sent,
      %{attempts: message.attempts},
      %{queue_id: message.id, msg_id: nil},
      %{id: message.id, queue_id: message.id, msg_id: nil, attempts: message.attempts}
    )

    {_removed, state} = remove_id(state, message.id)
    {:sent, state}
  end

  defp sent(state, message, msg_id) do
    message = %{message | transport_msg_id: msg_id}
    state = update_message(state, message)

    notify(
      state,
      :sent,
      %{attempts: message.attempts},
      %{queue_id: message.id, msg_id: msg_id},
      %{id: message.id, queue_id: message.id, msg_id: msg_id, attempts: message.attempts}
    )

    {_removed, state} = remove_id(state, message.id)
    {{:sent, msg_id}, state}
  end

  defp delayed(state, message, reason) do
    delayed = %{
      message
      | attempts: max(message.attempts - 1, 0),
        last_error: inspect(reason),
        transport_msg_id: nil
    }

    state = update_message(state, delayed)

    notify(
      state,
      :delayed,
      %{count: 1},
      %{queue_id: message.id, reason: :antiban},
      %{id: message.id, queue_id: message.id, reason: reason}
    )

    {:delayed, state}
  end

  defp failed_or_retry(state, message, reason)
       when message.attempts >= message.max_attempts do
    notify(
      state,
      :failed,
      %{attempts: message.attempts},
      %{queue_id: message.id, reason: reason_tag(reason)},
      %{id: message.id, queue_id: message.id, attempts: message.attempts, reason: reason}
    )

    {_removed, state} = remove_id(state, message.id)
    {{:failed, reason}, state}
  end

  defp failed_or_retry(state, message, reason) do
    backoff = state.config.retry_base_delay_ms * trunc(:math.pow(2, message.attempts - 1))

    retry = %{
      message
      | last_error: inspect(reason),
        scheduled_for: state.config.now_fun.() + backoff,
        transport_msg_id: nil
    }

    state = update_message(state, retry)

    notify(
      state,
      :retry,
      %{attempts: message.attempts, delay_ms: backoff},
      %{queue_id: message.id, reason: reason_tag(reason)},
      %{
        id: message.id,
        queue_id: message.id,
        attempts: message.attempts,
        delay_ms: backoff,
        reason: reason
      }
    )

    {{:retry, backoff}, state}
  end

  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag({tag, _detail}) when is_atom(tag), do: tag
  defp reason_tag(_reason), do: :other

  defp cancel_processing_watchers(processing) do
    cancel_timeout(processing.timeout_ref)
    Process.demonitor(processing.monitor_ref, [:flush])
  end

  defp cancel_timeout(timer_ref) do
    Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end

  defp reply_waiter(nil, _reply), do: :ok
  defp reply_waiter(from, reply), do: GenServer.reply(from, reply)

  defp empty_queues, do: %{high: :queue.new(), normal: :queue.new(), low: :queue.new()}

  defp queues_from_messages(messages) do
    Enum.reduce(messages, empty_queues(), fn message, queues ->
      Map.update!(queues, message.priority, &:queue.in(message, &1))
    end)
  end

  defp enqueue(state, message),
    do: put_in(state.queues[message.priority], :queue.in(message, state.queues[message.priority]))

  defp update_message(state, updated) do
    queues =
      Map.update!(state.queues, updated.priority, fn queue ->
        queue
        |> :queue.to_list()
        |> Enum.map(&replace_message(&1, updated))
        |> :queue.from_list()
      end)

    %{state | queues: queues}
  end

  defp find_message(state, id), do: Enum.find(all_messages(state), &(&1.id == id))

  defp replace_message(%{id: id}, %{id: id} = updated), do: updated
  defp replace_message(message, _updated), do: message

  defp eligible_message(state) do
    now = state.config.now_fun.()

    eligible =
      state
      |> all_messages()
      |> Enum.filter(&(is_nil(&1.scheduled_for) or &1.scheduled_for <= now))

    oldest_eligible(eligible, state.config.priority_order)
  end

  defp oldest_eligible(messages, true),
    do:
      Enum.min_by(messages, &{priority_weight(&1.priority), &1.added_at, &1.sequence}, fn ->
        nil
      end)

  defp oldest_eligible(messages, false),
    do: Enum.min_by(messages, &{&1.added_at, &1.sequence}, fn -> nil end)

  defp all_messages(state) do
    messages = Enum.flat_map(@priorities, &:queue.to_list(state.queues[&1]))
    sort_messages(messages, state.config.priority_order)
  end

  defp sort_messages(messages, true),
    do: Enum.sort_by(messages, &{priority_weight(&1.priority), &1.added_at, &1.sequence})

  defp sort_messages(messages, false),
    do: Enum.sort_by(messages, &{&1.added_at, &1.sequence})

  defp priority_weight(:high), do: 0
  defp priority_weight(:normal), do: 1
  defp priority_weight(:low), do: 2

  defp total(state), do: state |> all_messages() |> length()

  defp stats_for(state) do
    now = state.config.now_fun.()
    messages = all_messages(state)

    %{
      total: length(messages),
      pending: Enum.count(messages, &(is_nil(&1.scheduled_for) or &1.scheduled_for <= now)),
      scheduled: Enum.count(messages, &(&1.scheduled_for && &1.scheduled_for > now)),
      by_priority: Map.new(@priorities, &{&1, :queue.len(state.queues[&1])}),
      processing: not is_nil(state.processing),
      processing_id: if(state.processing, do: state.processing.message_id),
      is_running: state.running
    }
  end

  defp remove_id(state, id) do
    messages = all_messages(state)
    kept = Enum.reject(messages, &(&1.id == id))
    {length(messages) != length(kept), %{state | queues: queues_from_messages(kept)}}
  end

  defp schedule(state) do
    message = {:drain, state.drain_generation}
    %{state | timer: Process.send_after(self(), message, state.config.interval_ms)}
  end

  defp stop_timer(state, action) do
    if state.timer, do: Process.cancel_timer(state.timer)
    notify(state, action, %{count: 1}, %{})

    %{
      state
      | running: false,
        timer: nil,
        drain_generation: state.drain_generation + 1
    }
  end

  defp notify(state, action, measurements, metadata, owner_metadata \\ nil) do
    metadata = maybe_profile(metadata, state.config)
    Telemetry.emit([:amarula_antiban, :queue, action], measurements, metadata)

    if state.owner do
      send(
        state.owner,
        {:amarula_antiban, :queue, action, owner_metadata || metadata}
      )
    end
  end

  defp maybe_profile(metadata, %{profile: profile}), do: Map.put(metadata, :profile, profile)
  defp maybe_profile(metadata, _config), do: metadata

  defp message_to_snapshot(message, processing?) do
    %{
      "id" => message.id,
      "recipient" => message.recipient,
      "content" => encode_term(message.content),
      "content_encoding" => @term_encoding,
      "priority" => Atom.to_string(message.priority),
      "added_at" => message.added_at,
      "attempts" => message.attempts,
      "max_attempts" => message.max_attempts,
      "last_error" => message.last_error,
      "scheduled_for" => message.scheduled_for,
      "metadata" => encode_term(message.metadata),
      "metadata_encoding" => @term_encoding,
      "sequence" => message.sequence,
      "transport_msg_id" => message.transport_msg_id,
      "processing" => processing?
    }
  end

  defp message_from_map(%Message{} = message, _sequence),
    do: %{message | transport_msg_id: nil}

  defp message_from_map(message, sequence) do
    get = fn key -> Map.get(message, key, Map.get(message, Atom.to_string(key))) end

    content = decode_snapshot_term(get.(:content), get.(:content_encoding))
    metadata = decode_snapshot_term(get.(:metadata), get.(:metadata_encoding))

    struct!(Message, %{
      id: get.(:id),
      recipient: get.(:recipient),
      content: content,
      priority: get.(:priority) |> to_existing_atom(),
      added_at: get.(:added_at),
      attempts: get.(:attempts) || 0,
      max_attempts: get.(:max_attempts) || @defaults.max_attempts,
      last_error: get.(:last_error),
      scheduled_for: get.(:scheduled_for),
      metadata: metadata,
      sequence: get.(:sequence) || sequence,
      transport_msg_id: nil
    })
  end

  defp encode_term(term), do: term |> :erlang.term_to_binary() |> Base.encode64()

  defp decode_snapshot_term(value, @term_encoding) when is_binary(value) do
    value |> Base.decode64!() |> :erlang.binary_to_term([:safe])
  end

  defp decode_snapshot_term(value, _legacy_or_unknown_encoding), do: value

  defp to_existing_atom(value) when value in @priorities, do: value

  defp to_existing_atom(value) when is_binary(value) do
    case value do
      "high" -> :high
      "normal" -> :normal
      "low" -> :low
    end
  end

  defp id_counter(id) do
    case id |> String.split("_") |> List.last() |> Integer.parse() do
      {number, ""} -> number
      _other -> 0
    end
  end
end
