defmodule AmarulaAntiban.HumanEntropySupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias AmarulaAntiban.HumanEntropyWorker

  def start_link(options \\ []) do
    DynamicSupervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Ensures a worker exists for `session_id`, (re)configuring it with `options` if it does."
  @spec ensure_worker(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_worker(session_id, options) do
    options = Keyword.put(options, :session_id, session_id)

    case HumanEntropyWorker.whereis(session_id) do
      pid when is_pid(pid) ->
        :ok = HumanEntropyWorker.configure(pid, options)
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(__MODULE__, {HumanEntropyWorker, options}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end
    end
  end
end
