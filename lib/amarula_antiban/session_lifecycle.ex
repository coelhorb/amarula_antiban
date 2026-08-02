defmodule AmarulaAntiban.SessionLifecycle do
  @moduledoc false

  use GenServer

  alias AmarulaAntiban.PersistenceSupervisor
  alias AmarulaAntiban.Session
  alias AmarulaAntiban.SessionHandle
  alias AmarulaAntiban.SessionSupervisor

  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec start_session(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(session_id, options),
    do: GenServer.call(__MODULE__, {:start, session_id, options}, :infinity)

  @spec stop_session(term()) :: :ok | {:error, term()}
  def stop_session(session_id),
    do: GenServer.call(__MODULE__, {:stop, session_id}, :infinity)

  @spec options(term()) :: {:ok, keyword()} | :error
  def options(session_id), do: GenServer.call(__MODULE__, {:options, session_id})

  @spec handle(term(), keyword()) :: {:ok, SessionHandle.t()} | {:error, term()}
  def handle(session_id, options) do
    with {:ok, _pid} <- start_session(session_id, options) do
      {:ok, %SessionHandle{session_id: session_id, options: options}}
    end
  end

  @impl true
  def init(_options), do: {:ok, %{specs: %{}, monitors: %{}}}

  @impl true
  def handle_call({:start, session_id, options}, _from, state) do
    options = Keyword.put(options, :session_id, session_id)
    state = put_in(state.specs[session_id], options)

    case ensure_started(session_id, options) do
      {:ok, pid} -> {:reply, {:ok, pid}, monitor_session(state, session_id, pid)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:stop, session_id}, _from, state) do
    {options, specs} = Map.pop(state.specs, session_id)
    state = %{state | specs: specs} |> demonitor_session(session_id)

    result =
      case SessionSupervisor.whereis(session_id) do
        nil -> :ok
        pid -> stop_pid(pid)
      end

    case result do
      :ok ->
        _ = PersistenceSupervisor.stop_writer(session_id)
        {:reply, :ok, state}

      {:error, _reason} = error ->
        state = if options, do: put_in(state.specs[session_id], options), else: state
        {:reply, error, state}
    end
  end

  def handle_call({:options, session_id}, _from, state) do
    case Map.fetch(state.specs, session_id) do
      {:ok, options} -> {:reply, {:ok, options}, state}
      :error -> {:reply, :error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.monitors, fn {_id, monitor} -> monitor == ref end) do
      {session_id, ^ref} ->
        state = %{state | monitors: Map.delete(state.monitors, session_id)}
        if Map.has_key?(state.specs, session_id), do: schedule_rehydrate(session_id)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:rehydrate, session_id}, state) do
    case Map.fetch(state.specs, session_id) do
      {:ok, options} ->
        case ensure_started(session_id, options) do
          {:ok, pid} ->
            {:noreply, monitor_session(state, session_id, pid)}

          {:error, _reason} ->
            schedule_rehydrate(session_id)
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  defp ensure_started(session_id, options) do
    case SessionSupervisor.whereis(session_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> SessionSupervisor.start_child(session_id, options)
    end
  catch
    :exit, reason -> {:error, {:supervisor_exit, reason}}
  end

  defp stop_pid(pid) do
    with :ok <- Session.flush(pid) do
      case Process.whereis(SessionSupervisor) do
        nil -> :ok
        _supervisor -> DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      end
    end
  end

  defp monitor_session(state, session_id, pid) do
    state = demonitor_session(state, session_id)
    %{state | monitors: Map.put(state.monitors, session_id, Process.monitor(pid))}
  end

  defp demonitor_session(state, session_id) do
    case Map.pop(state.monitors, session_id) do
      {nil, monitors} ->
        %{state | monitors: monitors}

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: monitors}
    end
  end

  defp schedule_rehydrate(session_id),
    do: Process.send_after(self(), {:rehydrate, session_id}, 10)
end
