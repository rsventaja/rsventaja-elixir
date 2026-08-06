defmodule Ersventaja.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

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
      Ersventaja.BackupJob,
      Ersventaja.Atendimento.AtendimentoSupervisor
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ersventaja.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Recupera atendimentos ativos que ficaram órfãos após restart
    recover_atendimentos()

    {:ok, pid}
  end

  defp recover_atendimentos do
    recovered = Ersventaja.Atendimento.recover_active_atendimentos()

    Enum.each(recovered, fn data ->
      case Ersventaja.Atendimento.AtendimentoSupervisor.start_child(data) do
        {:ok, pid} ->
          Logger.info(
            "[Application] Recovered atendimento ##{data.atendimento_id}, PID: #{inspect(pid)}"
          )

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Application] Failed to recover atendimento ##{data.atendimento_id}: #{inspect(reason)}"
          )
      end
    end)

    if recovered != [] do
      Logger.info("[Application] Recovered #{length(recovered)} active atendimento(s)")
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ErsventajaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
