defmodule Ersventaja.Repo.Migrations.CreateAtendimentos do
  use Ecto.Migration

  def change do
    create table(:atendimentos) do
      add :customer_id, references(:customers, on_delete: :nothing)
      add :agent_id, references(:atendimento_agents, on_delete: :nothing)
      add :whatsapp_phone, :string, null: false
      add :cpf_cnpj, :string, null: false
      add :category, :string, null: false
      add :status, :string, null: false, default: "active"
      add :customer_name, :string
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      add :ended_by, :string

      timestamps()
    end

    create index(:atendimentos, [:whatsapp_phone])
    create index(:atendimentos, [:status])
    create index(:atendimentos, [:agent_id])
  end
end
