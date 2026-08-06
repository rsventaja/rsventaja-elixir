defmodule Ersventaja.Customers.Models.Customer do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ersventaja.Policies.Models.Policy

  @fields ~w(
    name
    cpf_cnpj
    phone
    email
  )a

  @required_fields ~w(
    name
  )a

  schema "customers" do
    field(:name, :string)
    field(:cpf_cnpj, :string)
    field(:phone, :string)
    field(:email, :string)

    has_many(:policies, Policy)

    timestamps()
  end

  @doc false
  def changeset(customer, attrs) do
    customer
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:cpf_cnpj,
      name: :customers_cpf_cnpj_idx,
      message: "Já existe um cliente com este CPF/CNPJ"
    )
    |> normalize_cpf_cnpj()
    |> normalize_name()
  end

  defp normalize_cpf_cnpj(%{changes: %{cpf_cnpj: cpf_cnpj}} = changeset) when not is_nil(cpf_cnpj) do
    # Keep formatting but trim whitespace
    put_change(changeset, :cpf_cnpj, String.trim(cpf_cnpj))
  end

  defp normalize_cpf_cnpj(changeset), do: changeset

  defp normalize_name(%{changes: %{name: name}} = changeset) when not is_nil(name) do
    put_change(changeset, :name, name |> String.trim() |> String.upcase())
  end

  defp normalize_name(changeset), do: changeset
end
