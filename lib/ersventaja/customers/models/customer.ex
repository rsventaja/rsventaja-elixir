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
    |> normalize_phone()
  end

  defp normalize_cpf_cnpj(%{changes: %{cpf_cnpj: cpf_cnpj}} = changeset)
       when not is_nil(cpf_cnpj) do
    # Keep formatting but trim whitespace
    put_change(changeset, :cpf_cnpj, String.trim(cpf_cnpj))
  end

  defp normalize_cpf_cnpj(changeset), do: changeset

  defp normalize_name(%{changes: %{name: name}} = changeset) when not is_nil(name) do
    put_change(changeset, :name, name |> String.trim() |> String.upcase())
  end

  defp normalize_name(changeset), do: changeset

  defp normalize_phone(%{changes: %{phone: phone}} = changeset)
       when not is_nil(phone) and phone != "" do
    formatted = format_phone(phone)
    put_change(changeset, :phone, formatted)
  end

  defp normalize_phone(changeset), do: changeset

  def format_phone(phone) when is_binary(phone) do
    digits = String.replace(phone, ~r/[^0-9]/, "")

    # Remove country code 55 prefix
    digits =
      if String.length(digits) >= 12 and String.starts_with?(digits, "55"),
        do: String.slice(digits, 2..-1//1),
        else: digits

    # Missing DDD → default to 11 (São Paulo)
    digits =
      case String.length(digits) do
        9 -> "11" <> digits
        8 -> "11" <> digits
        _ -> digits
      end

    case String.length(digits) do
      11 ->
        # Cell: (DD) 9XXXX-XXXX
        "(" <>
          String.slice(digits, 0, 2) <>
          ") " <>
          String.slice(digits, 2, 1) <>
          String.slice(digits, 3, 4) <>
          "-" <> String.slice(digits, 7, 4)

      10 ->
        # Landline: (DD) XXXX-XXXX
        "(" <>
          String.slice(digits, 0, 2) <>
          ") " <>
          String.slice(digits, 2, 4) <> "-" <> String.slice(digits, 6, 4)

      _ ->
        # Can't normalize — keep original
        phone
    end
  end

  def format_phone(nil), do: nil
  def format_phone(phone), do: phone
end
