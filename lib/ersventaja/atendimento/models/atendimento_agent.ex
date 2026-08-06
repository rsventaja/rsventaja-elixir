defmodule Ersventaja.Atendimento.Models.AtendimentoAgent do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ersventaja.Customers.Models.Customer

  @fields ~w(
    name
    phone
  )a

  @required_fields ~w(
    name
    phone
  )a

  schema "atendimento_agents" do
    field :name, :string
    field :phone, :string

    timestamps()
  end

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:phone, name: :atendimento_agents_phone_index, message: "Já existe um agente com este telefone")
    |> normalize_name()
    |> normalize_phone()
  end

  defp normalize_name(%{changes: %{name: name}} = changeset) when not is_nil(name) do
    put_change(changeset, :name, name |> String.trim() |> String.upcase())
  end

  defp normalize_name(changeset), do: changeset

  defp normalize_phone(%{changes: %{phone: phone}} = changeset) when not is_nil(phone) and phone != "" do
    formatted = Customer.format_phone(phone)
    put_change(changeset, :phone, formatted)
  end

  defp normalize_phone(changeset), do: changeset
end
