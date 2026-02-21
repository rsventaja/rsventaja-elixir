defmodule Ersventaja.UserManager.Models.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field(:password, :string)
    field(:username, :string)

    timestamps()
  end

  @doc false
  def changeset(user, attrs) do
    hashed_attrs = hash_password(attrs)

    user
    |> cast(hashed_attrs, [:username, :password])
    |> validate_required([:username, :password])
    |> unique_constraint(:username)
  end

  defp hash_password(%{username: username, password: password}) do
    %{username: username, password: Bcrypt.hash_pwd_salt(password)}
  end
end
