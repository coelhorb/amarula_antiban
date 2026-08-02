ExUnit.start()

defmodule AmarulaAntiban.TestSlowStore do
  @moduledoc false
  @behaviour AmarulaAntiban.StateStore

  @impl true
  def load(_test_pid), do: {:ok, nil}

  @impl true
  def save(test_pid, snapshot) do
    if self() == test_pid do
      :ok
    else
      send(test_pid, {:slow_store_save, self(), snapshot})

      receive do
        :finish_slow_store_save -> :ok
      after
        100 -> :ok
      end
    end
  end
end

defmodule AmarulaAntiban.TestControlledStore do
  @moduledoc false
  @behaviour AmarulaAntiban.StateStore

  @impl true
  def load(agent), do: {:ok, Agent.get(agent, & &1.snapshot)}

  @impl true
  def save(agent, snapshot) do
    generation = Map.get(snapshot, "generation", 0)
    test_pid = Agent.get(agent, & &1.test_pid)
    send(test_pid, {:controlled_store_save, self(), generation, snapshot})

    receive do
      {:controlled_store_release, ^generation} ->
        Agent.update(agent, &Map.put(&1, :snapshot, snapshot))
        :ok

      {:controlled_store_raise, ^generation} ->
        raise "controlled adapter crash"

      {:controlled_store_exit, ^generation} ->
        exit(:controlled_adapter_exit)
    after
      5_000 ->
        {:error, :controlled_store_timeout}
    end
  end
end
