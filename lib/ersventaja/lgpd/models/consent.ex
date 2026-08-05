defmodule Ersventaja.Lgpd.Models.Consent do
  use Ecto.Schema
  import Ecto.Changeset

  @fields ~w(
    cpf_cnpj
    consented_at
    whatsapp_phone
    consent_text_shown
    policy_version
    source
    revoked_at
    revocation_reason
  )a

  @required ~w(
    cpf_cnpj
    consented_at
    whatsapp_phone
    consent_text_shown
  )a

  schema "lgpd_consents" do
    field(:cpf_cnpj, :string)
    field(:consented_at, :utc_datetime_usec)
    field(:whatsapp_phone, :string)
    field(:consent_text_shown, :string)
    field(:policy_version, :string, default: "1.0")
    field(:source, :string, default: "whatsapp")
    field(:revoked_at, :utc_datetime_usec)
    field(:revocation_reason, :string)

    timestamps()
  end

  @doc false
  def changeset(consent, attrs) do
    consent
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> validate_length(:cpf_cnpj, min: 11, max: 14)
    |> validate_format(:cpf_cnpj, ~r/^\d+$/, message: "must contain only digits")
    |> unique_constraint([:cpf_cnpj, :whatsapp_phone],
      name: :lgpd_consents_cpf_cnpj_whatsapp_phone_index
    )
  end
end
