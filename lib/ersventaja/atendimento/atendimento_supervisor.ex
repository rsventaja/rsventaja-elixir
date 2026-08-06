defmodule Ersventaja.Atendimento.AtendimentoSupervisor do
  @moduledoc """
  DynamicSupervisor para gerenciar processos AtendimentoServer.

  Cada atendimento ativo ganha seu próprio processo GenServer,
  supervisionado por este DynamicSupervisor.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Inicia um novo processo AtendimentoServer para um atendimento.

  `data` deve ser um map com as chaves:
    - `:atendimento_id`
    - `:client_phone`
    - `:agent_phone`
    - `:phone_number_id`
    - `:category`
    - `:customer_name`
    - `:cpf_cnpj`
  """
  def start_child(data) do
    spec = %{
      id: :"atendimento_#{data.atendimento_id}",
      start: {Ersventaja.Atendimento.AtendimentoServer, :start_link, [data]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
