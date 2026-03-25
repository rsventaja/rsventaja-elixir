defmodule Ersventaja.Repo.Migrations.CreateInsuranceTypes do
  use Ecto.Migration

  def change do
    create table(:insurance_types) do
      add :name, :string, null: false

      timestamps()
    end

    create unique_index(:insurance_types, [:name])

    alter table(:policies) do
      add :insurance_type_id, references(:insurance_types, on_delete: :nilify_all)
    end
  end
end
