defmodule AmarulaAntiban.PersistenceWriter do
  @moduledoc """
  A serialized, generation-aware persistence boundary for one logical session.

  All adapter I/O for a `session_id` passes through this process. Generations
  make a late request harmless, while synchronous `flush/3` is an ordered
  barrier. Adapter raises/exits are converted to tagged errors and never leave
  hidden tasks behind.
  """

  use GenServer

  alias AmarulaAntiban.StateStore

  @type save_result :: :ok | {:error, term()}

  def child_spec(options) do
    session_id = Keyword.fetch!(options, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [options]},
      restart: :permanent
    }
  end

  def start_link(options) do
    session_id = Keyword.fetch!(options, :session_id)
    GenServer.start_link(__MODULE__, options, name: via(session_id))
  end

  @spec whereis(term()) :: pid() | nil
  def whereis(session_id), do: GenServer.whereis(via(session_id))

  @spec configure(pid(), StateStore.ref()) :: {:ok, pid()} | {:error, term()}
  def configure(pid, store) do
    case GenServer.call(pid, {:configure, store}) do
      :ok -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  @spec load(GenServer.server()) :: {:ok, StateStore.snapshot() | nil} | {:error, term()}
  def load(server), do: GenServer.call(server, :load, :infinity)

  @spec save(GenServer.server(), non_neg_integer(), map()) :: :ok | {:error, term()}
  def save(server, generation, snapshot) do
    GenServer.cast(server, {:save, generation, snapshot})
  catch
    :exit, reason -> {:error, {:writer_exit, reason}}
  end

  @spec flush(GenServer.server(), non_neg_integer(), map()) :: save_result()
  def flush(server, generation, snapshot) do
    GenServer.call(server, {:flush, generation, snapshot}, :infinity)
  catch
    :exit, reason -> {:error, {:writer_exit, reason}}
  end

  @spec via(term()) :: {:via, Registry, {atom(), term()}}
  def via(session_id),
    do: {:via, Registry, {AmarulaAntiban.PersistenceRegistry, session_id}}

  @impl true
  def init(options) do
    {:ok,
     %{
       session_id: Keyword.fetch!(options, :session_id),
       store: Keyword.fetch!(options, :store),
       confirmed_generation: 0
     }}
  end

  @impl true
  def handle_call({:configure, store}, _from, %{store: store} = state),
    do: {:reply, :ok, state}

  def handle_call({:configure, store}, _from, state),
    do: {:reply, {:error, {:store_mismatch, state.store, store}}, state}

  def handle_call(:load, _from, state) do
    case safe_apply(StateStore, :load, [state.store]) do
      {:ok, snapshot} = result ->
        generation = snapshot_generation(snapshot)
        {:reply, result, %{state | confirmed_generation: generation}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:flush, generation, snapshot}, _from, state) do
    {result, state} = persist(state, generation, snapshot)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:save, generation, snapshot}, state) do
    {_result, state} = persist(state, generation, snapshot)
    {:noreply, state}
  end

  defp persist(state, generation, _snapshot) when generation <= state.confirmed_generation,
    do: {:ok, state}

  defp persist(state, generation, snapshot) do
    snapshot = Map.put(snapshot, "generation", generation)

    case safe_apply(StateStore, :save, [state.store, snapshot]) do
      :ok ->
        {:ok, %{state | confirmed_generation: generation}}

      {:error, reason} = error ->
        emit_failure(state.session_id, generation, reason)
        {error, state}

      other ->
        error = {:error, {:invalid_adapter_result, other}}
        emit_failure(state.session_id, generation, elem(error, 1))
        {error, state}
    end
  end

  defp safe_apply(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    error -> {:error, {:adapter_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:adapter_exit, kind, reason}}
  end

  defp snapshot_generation(%{"generation" => generation})
       when is_integer(generation) and generation >= 0,
       do: generation

  defp snapshot_generation(_snapshot), do: 0

  defp emit_failure(session_id, generation, reason) do
    :telemetry.execute(
      [:amarula_antiban, :session, :persistence_failed],
      %{count: 1},
      %{session_id: session_id, generation: generation, reason: reason_tag(reason)}
    )
  end

  defp reason_tag({tag, _detail}) when is_atom(tag), do: tag
  defp reason_tag({tag, _kind, _detail}) when is_atom(tag), do: tag
  defp reason_tag(tag) when is_atom(tag), do: tag
  defp reason_tag(_reason), do: :other
end
