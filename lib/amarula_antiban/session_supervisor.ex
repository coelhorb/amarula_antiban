defmodule AmarulaAntiban.SessionSupervisor do
  @moduledoc """
  Dynamic session supervisor with lifecycle serialized by `SessionLifecycle`.

  Desired child specs live outside this process. If this supervisor crashes,
  the lifecycle owner rehydrates them and stable handles continue to resolve by
  `session_id`.
  """

  use DynamicSupervisor

  alias AmarulaAntiban.Session
  alias AmarulaAntiban.SessionHandle
  alias AmarulaAntiban.SessionLifecycle

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    DynamicSupervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Starts a session or returns the already registered process."
  @spec start_session(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(session_id, options \\ []) do
    SessionLifecycle.start_session(session_id, options)
  end

  @doc "Returns a stable logical handle and ensures its session exists."
  @spec handle(term(), keyword()) :: {:ok, SessionHandle.t()} | {:error, term()}
  def handle(session_id, options \\ []), do: SessionLifecycle.handle(session_id, options)

  @doc "Runs an operation against the current session, retrying one restart race."
  @spec with_session(SessionHandle.t() | term(), (pid() -> result)) :: result | {:error, term()}
        when result: term()
  def with_session(%SessionHandle{} = handle, fun) when is_function(fun, 1) do
    with_session(handle.session_id, handle.options, fun, 1)
  end

  def with_session(session_id, fun) when is_function(fun, 1) do
    options =
      case SessionLifecycle.options(session_id) do
        {:ok, stored} -> stored
        :error -> []
      end

    with_session(session_id, options, fun, 1)
  end

  @doc "Looks up a session by ID."
  @spec whereis(term()) :: pid() | nil
  def whereis(session_id) do
    case Registry.lookup(AmarulaAntiban.Registry, session_id) do
      [{pid, _value}] -> if(Process.alive?(pid), do: pid)
      [] -> nil
    end
  end

  @doc "Flushes and gracefully stops a session."
  @spec stop_session(term()) :: :ok | {:error, term()}
  def stop_session(session_id) do
    SessionLifecycle.stop_session(session_id)
  end

  @doc false
  @spec start_child(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_child(session_id, options) do
    child = {Session, Keyword.put(options, :session_id, session_id)}

    case DynamicSupervisor.start_child(__MODULE__, child) do
      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, {:shutdown, {:failed_to_start_child, _child, {:already_started, pid}}}} ->
        {:ok, pid}

      result ->
        result
    end
  end

  defp with_session(session_id, options, fun, retries) do
    with {:ok, pid} <- start_session(session_id, options) do
      fun.(pid)
    end
  catch
    :exit, reason ->
      if retries > 0 and restart_exit?(reason) do
        with_session(session_id, options, fun, retries - 1)
      else
        {:error, {:session_exit, reason}}
      end
  end

  defp restart_exit?({:noproc, _call}), do: true
  defp restart_exit?({:normal, _call}), do: true
  defp restart_exit?({:shutdown, _call}), do: true
  defp restart_exit?(_reason), do: false
end
