defmodule Ersventaja.Customers do
  @moduledoc """
  Contexto para gestão de clientes (customers).

  Cada customer é identificado unicamente pelo CPF/CNPJ normalizado (apenas dígitos).
  Policies que compartilham o mesmo CPF/CNPJ pertencem ao mesmo customer.
  """

  alias Ersventaja.Repo
  alias Ersventaja.Customers.Models.Customer

  import Ecto.Query

  @doc """
  Encontra um customer existente pelo CPF/CNPJ (compara apenas dígitos),
  ou cria um novo se não existir.

  ## Exemplos

      iex> find_or_create_by_cpf_cnpj("123.456.789-00", %{name: "FULANO DE TAL", phone: "(11) 99999-0000"})
      {:ok, %Customer{}}
  """
  @spec find_or_create_by_cpf_cnpj(String.t(), map()) :: {:ok, Customer.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_by_cpf_cnpj(cpf_cnpj, attrs \\ %{}) do
    digits = normalize_cpf_cnpj(cpf_cnpj)

    if digits == "" do
      {:ok, nil}
    else
      case Repo.get_by(Customer, cpf_cnpj: cpf_cnpj) do
        nil ->
          # Search by digits match across all formatted CPFs
          existing =
            Customer
            |> where(
              [c],
              fragment("regexp_replace(?, '[^0-9]', '', 'g')", c.cpf_cnpj) == ^digits
            )
            |> Repo.one()

          case existing do
            nil ->
              # Create new customer
              %Customer{}
              |> Customer.changeset(Map.merge(attrs, %{cpf_cnpj: cpf_cnpj}))
              |> Repo.insert()

            customer ->
              # Update existing customer with new info
              customer
              |> Customer.changeset(attrs)
              |> Repo.update()
          end

        customer ->
          # Update existing customer with new info
          customer
          |> Customer.changeset(attrs)
          |> Repo.update()
      end
    end
  end

  @doc """
  Busca um customer pelo ID.
  """
  def get_customer!(id), do: Repo.get!(Customer, id)

  @doc """
  Busca um customer pelo ID, retornando nil se não encontrado.
  """
  def get_customer(id), do: Repo.get(Customer, id)

  @doc """
  Atualiza os dados do customer. Como os dados de cliente agora são normalizados
  na tabela customers, a atualização é feita diretamente pelo changeset.
  """
  def update_customer(customer, attrs) do
    customer
    |> Customer.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Lista todos os customers.
  """
  def list_customers do
    Repo.all(from(c in Customer, order_by: c.name))
  end

  @doc """
  Busca customers por CPF/CNPJ (compara apenas dígitos).
  """
  def get_by_cpf_cnpj(cpf_cnpj) when is_binary(cpf_cnpj) do
    digits = normalize_cpf_cnpj(cpf_cnpj)

    if digits == "" do
      nil
    else
      from(c in Customer,
        where:
          not is_nil(c.cpf_cnpj) and c.cpf_cnpj != "" and
            fragment("regexp_replace(?, '[^0-9]', '', 'g')", c.cpf_cnpj) == ^digits
      )
      |> Repo.one()
    end
  end

  def get_by_cpf_cnpj(_), do: nil

  defp normalize_cpf_cnpj(nil), do: ""
  defp normalize_cpf_cnpj(str), do: String.replace(str, ~r/[^0-9]/, "")
end
