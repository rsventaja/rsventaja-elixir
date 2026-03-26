defmodule Ersventaja.Repo.Migrations.CreateSegfyQuotations do
  use Ecto.Migration

  def change do
    create table(:segfy_quotations) do
      add :policy_id, references(:policies, on_delete: :delete_all), null: false
      add :quotation_url, :string
      add :codigo_orcamento, :string
      add :quotation_id, :string
      add :premiums, :map, default: %{}

      timestamps()
    end

    create unique_index(:segfy_quotations, [:policy_id])
  end
end
