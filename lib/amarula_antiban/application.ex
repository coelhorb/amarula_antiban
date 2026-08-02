defmodule AmarulaAntiban.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AmarulaAntiban.Registry},
      {Registry, keys: :unique, name: AmarulaAntiban.PersistenceRegistry},
      {Registry, keys: :unique, name: AmarulaAntiban.EventBridgeRegistry},
      AmarulaAntiban.SessionLifecycle,
      AmarulaAntiban.SessionSupervisor,
      AmarulaAntiban.PersistenceSupervisor,
      AmarulaAntiban.EventBridgeSupervisor,
      AmarulaAntiban.StateStore.Ets,
      {Task.Supervisor, name: AmarulaAntiban.Session.TaskSupervisor},
      {Task.Supervisor, name: AmarulaAntiban.Webhook.TaskSupervisor},
      {Task.Supervisor, name: AmarulaAntiban.Queue.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: AmarulaAntiban.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
