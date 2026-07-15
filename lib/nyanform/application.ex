defmodule Nyanform.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Nyanform.Session.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Nyanform.Session.Supervisor},
      Nyanform.Session.Manager,
      {Task.Supervisor, name: Nyanform.Compile.TaskSupervisor, max_children: 32}
    ]

    opts = [strategy: :one_for_one, name: Nyanform.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
