defmodule Ersventaja.Repo.Migrations.AddPhoneToLgpdConsents do
  use Ecto.Migration

  def up do
    # Consent is now per (CPF/CNPJ + WhatsApp phone) pair, not just per CPF.
    # This means the same CPF can consent from multiple phones independently,
    # and a phone can only access policies for CPFs it has consented to.

    # 1. Drop the old primary key on cpf_cnpj alone
    execute "ALTER TABLE lgpd_consents DROP CONSTRAINT lgpd_consents_pkey"

    # 2. Add an auto-increment id as the new primary key
    execute "ALTER TABLE lgpd_consents ADD COLUMN id SERIAL PRIMARY KEY"

    # 3. Make whatsapp_phone NOT NULL (it was already populated for the
    #    existing record in production)
    execute "ALTER TABLE lgpd_consents ALTER COLUMN whatsapp_phone SET NOT NULL"

    # 4. Unique constraint on the (cpf_cnpj, whatsapp_phone) pair —
    #    the same phone cannot consent twice for the same CPF, but different
    #    phones can consent independently for the same CPF.
    create unique_index(:lgpd_consents, [:cpf_cnpj, :whatsapp_phone])
  end

  def down do
    # Reverse: drop the new unique index
    drop unique_index(:lgpd_consents, [:cpf_cnpj, :whatsapp_phone])

    # Make whatsapp_phone nullable again
    execute "ALTER TABLE lgpd_consents ALTER COLUMN whatsapp_phone DROP NOT NULL"

    # Drop the new id column and PK
    execute "ALTER TABLE lgpd_consents DROP CONSTRAINT lgpd_consents_pkey"
    execute "ALTER TABLE lgpd_consents DROP COLUMN id"

    # Restore cpf_cnpj as PK
    execute "ALTER TABLE lgpd_consents ADD PRIMARY KEY (cpf_cnpj)"
  end
end
