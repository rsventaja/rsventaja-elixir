defmodule Ersventaja.Atendimento.Models.Atendimento do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ersventaja.Atendimento.Models.AtendimentoAgent
  alias Ersventaja.Atendimento.Models.AtendimentoMessage
  alias Ersventaja.Customers.Models.Customer

  @fields ~w(
    customer_id
    agent_id
    whatsapp_phone
    cpf_cnpj
    category
    status
    customer_name
    started_at
    ended_at
    ended_by
  )a

  @required_fields ~w(
    whatsapp_phone
    cpf_cnpj
    category
    status
    started_at
  )a

  schema "atendimentos" do
    belongs_to :customer, Customer
    belongs_to :agent, AtendimentoAgent
    has_many :messages, AtendimentoMessage

    field :whatsapp_phone, :string
    field :cpf_cnpj, :string
    field :category, :string
    field :status, :string, default: "active"
    field :customer_name, :string
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :ended_by, :string

    timestamps()
  end

  @doc false
  def changeset(atendimento, attrs) do
    atendimento
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:category, ["duvida", "sinistro", "troca_veiculo"])
    |> validate_inclusion(:status, ["active", "ended", "expired"])
  end
end
