defmodule Battlefield.Application do
  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT", "4040"))

    children = [
      {Registry, keys: :duplicate, name: Battlefield.Clients},
      Battlefield.Sim,
      {Battlefield.WS, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Battlefield.Supervisor)
  end
end
