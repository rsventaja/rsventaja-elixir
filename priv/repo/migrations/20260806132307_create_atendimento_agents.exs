defmodule Ersventaja.Repo.Migrations.CreateAtendimentoAgents do
  use Ecto.Migration

  def change do
    create table(:atendimento_agents) do
      add :name, :string, null: false
      add :phone, :string, null: false

      timestamps()
    end

    create unique_index(:atendimento_agents, [:phone])
  end
end
