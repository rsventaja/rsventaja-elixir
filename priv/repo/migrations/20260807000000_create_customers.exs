defmodule Ersventaja.Repo.Migrations.CreateCustomers do
  use Ecto.Migration

  def up do
    # 1. Create customers table
    create table(:customers) do
      add :name, :string, null: false
      add :cpf_cnpj, :string
      add :phone, :string
      add :email, :string

      timestamps()
    end

    # Partial unique index: only for non-null, non-empty cpf_cnpj
    execute """
      CREATE UNIQUE INDEX customers_cpf_cnpj_idx ON customers(cpf_cnpj)
      WHERE cpf_cnpj IS NOT NULL AND cpf_cnpj != ''
    """

    # 2. Add customer_id to policies
    alter table(:policies) do
      add :customer_id, references(:customers, on_delete: :nilify_all)
    end

    # 3. Migrate existing data: group by CPF/CNPJ (digits only)
    #    For each group, pick the most frequent values using DISTINCT ON + window functions
    execute """
      WITH ranked AS (
        SELECT
          customer_cpf_or_cnpj,
          customer_name,
          customer_phone,
          customer_email,
          end_date,
          REGEXP_REPLACE(COALESCE(customer_cpf_or_cnpj, ''), '[^0-9]', '', 'g') AS cpf_digits,
          -- Count how many times each name variant appears within this CPF group
          COUNT(*) OVER (PARTITION BY REGEXP_REPLACE(COALESCE(customer_cpf_or_cnpj, ''), '[^0-9]', '', 'g'), UPPER(TRIM(customer_name))) AS name_freq,
          COUNT(*) OVER (PARTITION BY REGEXP_REPLACE(COALESCE(customer_cpf_or_cnpj, ''), '[^0-9]', '', 'g'), customer_phone) AS phone_freq,
          COUNT(*) OVER (PARTITION BY REGEXP_REPLACE(COALESCE(customer_cpf_or_cnpj, ''), '[^0-9]', '', 'g'), customer_email) AS email_freq,
          COUNT(*) OVER (PARTITION BY REGEXP_REPLACE(COALESCE(customer_cpf_or_cnpj, ''), '[^0-9]', '', 'g'), customer_cpf_or_cnpj) AS cpf_freq
        FROM policies
        WHERE customer_cpf_or_cnpj IS NOT NULL AND customer_cpf_or_cnpj != ''
      ),
      best AS (
        SELECT DISTINCT ON (cpf_digits)
          cpf_digits,
          customer_cpf_or_cnpj AS best_cpf,
          customer_name AS best_name,
          customer_phone AS best_phone,
          customer_email AS best_email
        FROM ranked
        WHERE customer_name IS NOT NULL AND customer_name != ''
        ORDER BY cpf_digits, name_freq DESC, end_date DESC
      )
      INSERT INTO customers (name, cpf_cnpj, phone, email, inserted_at, updated_at)
      SELECT
        best_name,
        best_cpf,
        best_phone,
        best_email,
        NOW(),
        NOW()
      FROM best
    """

    # 4. Link policies to customers
    execute """
      UPDATE policies p
      SET customer_id = c.id
      FROM customers c
      WHERE REGEXP_REPLACE(COALESCE(p.customer_cpf_or_cnpj, ''), '[^0-9]', '', 'g') =
            REGEXP_REPLACE(COALESCE(c.cpf_cnpj, ''), '[^0-9]', '', 'g')
        AND p.customer_cpf_or_cnpj IS NOT NULL
        AND p.customer_cpf_or_cnpj != ''
    """
  end

  def down do
    # Remove customer_id column
    alter table(:policies) do
      remove :customer_id
    end

    # Drop customers table
    drop table(:customers)
  end
end
