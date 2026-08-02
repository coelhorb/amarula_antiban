defmodule AmarulaAntiban.EventBridge do
  @moduledoc """
  Stable Queue event owner for one logical session.

  The bridge is supervised outside `SessionSupervisor`, so Queue processes may
  retain its pid while the mutable Session and its DynamicSupervisor restart.
  """

  use GenServer

  alias AmarulaAntiban.SessionSupervisor

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

  def whereis(session_id), do: GenServer.whereis(via(session_id))
  def configure(pid, options), do: GenServer.call(pid, {:configure, options})

  def via(session_id),
    do: {:via, Registry, {AmarulaAntiban.EventBridgeRegistry, session_id}}

  @impl true
  def init(options) do
    {:ok,
     %{
       session_id: Keyword.fetch!(options, :session_id),
       options: Keyword.fetch!(options, :options)
     }}
  end

  @impl true
  def handle_call({:configure, options}, _from, state),
    do: {:reply, :ok, %{state | options: options}}

  @impl true
  def handle_info({:amarula_antiban, :queue, _action, _payload} = event, state) do
    case SessionSupervisor.start_session(state.session_id, state.options) do
      {:ok, pid} -> send(pid, event)
      {:error, _reason} -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
