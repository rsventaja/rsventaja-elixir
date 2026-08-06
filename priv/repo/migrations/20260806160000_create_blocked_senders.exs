defmodule Ersventaja.Repo.Migrations.CreateBlockedSenders do
  use Ecto.Migration

  def change do
    create table(:blocked_senders) do
      add :phone, :string, null: false
      add :blocked_by, :string

      timestamps()
    end

    create unique_index(:blocked_senders, [:phone])
  end
end
