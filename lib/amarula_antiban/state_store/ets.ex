defmodule AmarulaAntiban.StateStore.Ets do
  @moduledoc """
  In-memory JSON store for tests and ephemeral deployments.

  Values are stored as encoded JSON rather than Elixir terms, so restores cross
  the same Jason serialization boundary as the file backend.
  """

  use GenServer

  @behaviour AmarulaAntiban.StateStore

  @table __MODULE__

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, table}
  end

  @impl AmarulaAntiban.StateStore
  def load(key) do
    case :ets.lookup(@table, key) do
      [{^key, json}] -> Jason.decode(json)
      [] -> {:ok, nil}
    end
  rescue
    ArgumentError -> {:error, :store_not_started}
  end

  @impl AmarulaAntiban.StateStore
  def save(key, snapshot) do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         {:ok, json} <- Jason.encode(snapshot) do
      GenServer.call(pid, {:save, key, json})
    else
      nil -> {:error, :store_not_started}
      {:error, error} -> {:error, {:invalid_snapshot, error}}
    end
  end

  @doc "Deletes every in-memory snapshot."
  @spec clear() :: :ok | {:error, :store_not_started}
  def clear do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :store_not_started}
      pid -> GenServer.call(pid, :clear)
    end
  end

  @impl true
  def handle_call({:save, key, json}, _from, table) do
    true = :ets.insert(table, {key, json})
    {:reply, :ok, table}
  end

  def handle_call(:clear, _from, table) do
    true = :ets.delete_all_objects(table)
    {:reply, :ok, table}
  end
end
