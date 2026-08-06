defmodule Ersventaja.Repo.Migrations.AddActiveToAtendimentoAgents do
  use Ecto.Migration

  def change do
    alter table(:atendimento_agents) do
      add :active, :boolean, null: false, default: true
    end

    create index(:atendimento_agents, [:active])
  end
end
