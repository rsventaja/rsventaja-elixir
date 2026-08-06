defmodule Ersventaja.Atendimento.Models.AtendimentoMessage do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ersventaja.Atendimento.Models.Atendimento

  @fields ~w(
    atendimento_id
    direction
    sender_type
    content_type
    content
    whatsapp_phone
    media_id
    mime_type
  )a

  @required_fields ~w(
    atendimento_id
    direction
    sender_type
    content_type
  )a

  schema "atendimento_messages" do
    belongs_to :atendimento, Atendimento

    field :direction, :string
    field :sender_type, :string
    field :content_type, :string
    field :content, :string
    field :whatsapp_phone, :string
    field :media_id, :string
    field :mime_type, :string

    timestamps()
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:direction, ["incoming", "outgoing"])
    |> validate_inclusion(:sender_type, ["client", "agent", "system"])
    |> validate_inclusion(:content_type, ["text", "image", "document", "audio"])
  end
end
