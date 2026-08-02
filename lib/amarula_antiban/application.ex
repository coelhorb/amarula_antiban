defmodule AmarulaAntiban.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AmarulaAntiban.Registry},
      {DynamicSupervisor, name: AmarulaAntiban.SessionSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: AmarulaAntiban.Webhook.TaskSupervisor},
      {Task.Supervisor, name: AmarulaAntiban.Queue.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: AmarulaAntiban.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
