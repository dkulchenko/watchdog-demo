defmodule Demoapp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Watchdog,
      {Watchdog.Starter, Demoapp.TestServer}
      # Starts a worker by calling: Demoapp.Worker.start_link(arg)
      # {Demoapp.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Demoapp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
