defmodule Ersventaja.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize ETS tables for WhatsApp bot state
    Ersventaja.WhatsappBot.init()

    children = [
      # Start the Ecto repository
      Ersventaja.Repo,
      # Start the Telemetry supervisor
      ErsventajaWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: Ersventaja.PubSub},
      # Start the Endpoint (http/https)
      ErsventajaWeb.Endpoint,
      Ersventaja.BackupJob
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ersventaja.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ErsventajaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
