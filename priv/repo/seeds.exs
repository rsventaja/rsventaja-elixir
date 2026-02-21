# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Ersventaja.Repo.insert!(%Ersventaja.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Create default user only if it doesn't exist (idempotent seeds)
alias Ersventaja.UserManager.Models.User
unless Ersventaja.Repo.get_by(User, username: "user") do
  Ersventaja.UserManager.create_user(%{username: "user", password: "123"})
end
