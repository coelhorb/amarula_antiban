defmodule AmarulaAntiban.PersistenceSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias AmarulaAntiban.PersistenceWriter

  def start_link(options \\ []) do
    DynamicSupervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec ensure_writer(term(), AmarulaAntiban.StateStore.ref()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_writer(session_id, store) do
    case PersistenceWriter.whereis(session_id) do
      pid when is_pid(pid) -> PersistenceWriter.configure(pid, store)
      nil -> start_writer(session_id, store)
    end
  end

  @spec stop_writer(term()) :: :ok | {:error, term()}
  def stop_writer(session_id) do
    case PersistenceWriter.whereis(session_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  defp start_writer(session_id, store) do
    case DynamicSupervisor.start_child(
           __MODULE__,
           {PersistenceWriter, session_id: session_id, store: store}
         ) do
      {:error, {:already_started, pid}} -> PersistenceWriter.configure(pid, store)
      result -> result
    end
  end
end
