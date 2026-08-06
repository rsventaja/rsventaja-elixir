defmodule Ersventaja.Repo.Migrations.DropLegacyCustomerColumnsFromPolicies do
  use Ecto.Migration

  def up do
    alter table(:policies) do
      remove :customer_name
      remove :customer_cpf_or_cnpj
      remove :customer_phone
      remove :customer_email
    end
  end

  def down do
    alter table(:policies) do
      add :customer_name, :string
      add :customer_cpf_or_cnpj, :string
      add :customer_phone, :string
      add :customer_email, :string
    end

    # Repopulate from customers table
    execute """
      UPDATE policies p
      SET
        customer_name = c.name,
        customer_cpf_or_cnpj = c.cpf_cnpj,
        customer_phone = c.phone,
        customer_email = c.email
      FROM customers c
      WHERE p.customer_id = c.id
    """
  end
end
