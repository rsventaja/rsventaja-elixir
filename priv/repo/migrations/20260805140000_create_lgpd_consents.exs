defmodule Ersventaja.Repo.Migrations.CreateLgpdConsents do
  use Ecto.Migration

  def change do
    # ------------------------------------------------------------------
    # LGPD consent table — one row per CPF/CNPJ that has given consent.
    # Controller (RS Ventaja) carries the burden of proof (Art. 8º §2º).
    # ------------------------------------------------------------------
    create table(:lgpd_consents, primary_key: false) do
      # CPF/CNPJ is the natural key — consent is per document, not per phone number.
      # Normalized digits only (11 for CPF, 14 for CNPJ).
      add(:cpf_cnpj, :string, null: false, primary_key: true)

      # When consent was given
      add(:consented_at, :utc_datetime_usec, null: false)

      # WhatsApp phone number that gave consent (for audit trail)
      add(:whatsapp_phone, :string)

      # What the user saw — the exact consent text displayed, stored as evidence
      add(:consent_text_shown, :text, null: false)

      # Version of the privacy policy / consent terms at the time
      add(:policy_version, :string, null: false, default: "1.0")

      # Source channel (e.g. "whatsapp", "web", "app")
      add(:source, :string, null: false, default: "whatsapp")

      # Revocation support (Art. 8º §5º — consent may be revoked at any time)
      add(:revoked_at, :utc_datetime_usec)
      add(:revocation_reason, :text)

      timestamps()
    end

    # Index for lookups — though cpf_cnpj is PK, we also index by whatsapp_phone
    # for audit queries ("show all consents given by this phone number").
    create(index(:lgpd_consents, [:whatsapp_phone]))
    create(index(:lgpd_consents, [:consented_at]))

    # ------------------------------------------------------------------
    # WhatsApp webhook payload archive — full payload stored for audit.
    # Every incoming webhook is stored verbatim so we can reconstruct
    # exactly what was received for regulatory scrutiny.
    # ------------------------------------------------------------------
    create table(:whatsapp_webhook_payloads) do
      # WhatsApp message ID for dedup / correlation
      add(:whatsapp_message_id, :string)

      # Sender's WhatsApp phone number (from the messages[].from field)
      add(:from_phone, :string)

      # Business phone number ID that received the message
      add(:phone_number_id, :string)

      # The full raw JSON payload as received from Meta
      add(:raw_payload, :text, null: false)

      # When the webhook was received by our server
      add(:received_at, :utc_datetime_usec, null: false)

      timestamps()
    end

    create(index(:whatsapp_webhook_payloads, [:whatsapp_message_id]))
    create(index(:whatsapp_webhook_payloads, [:from_phone]))
    create(index(:whatsapp_webhook_payloads, [:received_at]))
  end
end
