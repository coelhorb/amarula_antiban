defmodule AmarulaAntiban.HumanEntropyWorker do
  @moduledoc """
  Per-session GenServer driving `Core.HumanEntropy`'s background humanization
  cycle — the only part of this port that runs outside the send flow.

  Started by `Plugin.attach/2` (not by `SessionSupervisor` alone): it only
  makes sense to run while there is a real Amarula connection to act
  through, the same reasoning behind `EventBridge`'s lifecycle. Each cycle
  fetches a read-only snapshot of `Session`'s human-entropy core state,
  decides actions with the pure `Core.HumanEntropy.roll_cycle/1`, executes
  them directly against Amarula (best-effort, tolerating an unavailable
  connection — same pattern `Plugin` already uses for presence steps),
  reports the actions back to `Session` for accounting, then reschedules
  itself with a fresh `Core.HumanEntropy.next_delay_ms/1` — a
  self-rescheduling timer, not a fixed interval, matching upstream's
  recursive `setTimeout`.
  """

  use GenServer

  alias AmarulaAntiban.Core.HumanEntropy
  alias AmarulaAntiban.Session
  alias AmarulaAntiban.SessionSupervisor

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    session_id = Keyword.fetch!(options, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [options]},
      restart: :permanent
    }
  end

  @doc "Starts one registered worker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    session_id = Keyword.fetch!(options, :session_id)
    GenServer.start_link(__MODULE__, options, name: via(session_id))
  end

  @doc "Looks up a registered worker."
  @spec whereis(term()) :: pid() | nil
  def whereis(session_id), do: GenServer.whereis(via(session_id))

  @doc "Updates the handle/conn an already-running worker acts through."
  @spec configure(pid(), keyword()) :: :ok
  def configure(pid, options), do: GenServer.call(pid, {:configure, options})

  @doc "Returns the Registry-backed server name for a session ID."
  @spec via(term()) :: {:via, Registry, {atom(), term()}}
  def via(session_id), do: {:via, Registry, {AmarulaAntiban.HumanEntropyRegistry, session_id}}

  @impl true
  def init(options) do
    state = %{
      handle: Keyword.fetch!(options, :handle),
      conn: Keyword.fetch!(options, :conn),
      sleep_fun: Keyword.get(options, :sleep_fun, &Process.sleep/1)
    }

    {:ok, state, {:continue, :run_cycle}}
  end

  @impl true
  def handle_continue(:run_cycle, state) do
    run_cycle(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:configure, options}, _from, state) do
    state = %{
      state
      | handle: Keyword.get(options, :handle, state.handle),
        conn: Keyword.get(options, :conn, state.conn)
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:run_cycle, state) do
    run_cycle(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp run_cycle(state) do
    entropy = fetch_snapshot(state)
    actions = HumanEntropy.roll_cycle(entropy)
    execute_actions(state, actions)
    report(state, actions)
    Process.send_after(self(), :run_cycle, HumanEntropy.next_delay_ms(entropy))
  end

  defp fetch_snapshot(state) do
    case SessionSupervisor.with_session(state.handle, &Session.human_entropy_snapshot/1) do
      {:error, _reason} -> HumanEntropy.new()
      entropy -> entropy
    end
  end

  defp report(_state, []), do: :ok

  defp report(state, actions) do
    _ = SessionSupervisor.with_session(state.handle, &Session.human_entropy_executed(&1, actions))
    :ok
  end

  defp execute_actions(state, actions), do: Enum.each(actions, &execute_action(state, &1))

  defp execute_action(state, {:typing, jid, duration_ms}) do
    pid = presence_pid(state.conn)
    best_effort(pid, fn -> Amarula.send_chatstate(pid, jid, :composing) end)
    state.sleep_fun.(duration_ms)
    best_effort(pid, fn -> Amarula.send_chatstate(pid, jid, :paused) end)
  end

  defp execute_action(state, {:presence_toggle, duration_ms}) do
    pid = presence_pid(state.conn)
    best_effort(pid, fn -> Amarula.set_presence(pid, :unavailable) end)
    state.sleep_fun.(duration_ms)
    best_effort(pid, fn -> Amarula.set_presence(pid, :available) end)
  end

  defp presence_pid(conn) do
    Amarula.whereis(conn, conn.profile)
  rescue
    RuntimeError -> nil
  end

  defp best_effort(nil, _fun), do: :ok

  defp best_effort(_pid, fun) do
    fun.()
  catch
    :exit, _reason -> :ok
  end
end
