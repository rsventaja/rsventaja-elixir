defmodule Ersventaja.Repo.Migrations.AddUniqueIndexToUsersUsername do
  use Ecto.Migration

  def up do
    # Remove duplicate usernames (keep row with smallest id per username)
    execute("""
    DELETE FROM users a
    USING users b
    WHERE a.username = b.username AND a.id > b.id
    """)

    create unique_index(:users, [:username])
  end

  def down do
    drop index(:users, [:username])
  end
end
