defmodule AmarulaAntiban.EventBridgeSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias AmarulaAntiban.EventBridge

  def start_link(options \\ []) do
    DynamicSupervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec ensure_bridge(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_bridge(session_id, options) do
    case EventBridge.whereis(session_id) do
      pid when is_pid(pid) ->
        :ok = EventBridge.configure(pid, options)
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(
               __MODULE__,
               {EventBridge, session_id: session_id, options: options}
             ) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end
    end
  end
end
