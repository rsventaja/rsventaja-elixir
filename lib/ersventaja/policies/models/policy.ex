defmodule Ersventaja.Policies.Models.Policy do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:id, :detail, :start_date, :end_date, :calculated, :customer_id]}

  alias Ersventaja.Policies.Models.Insurer
  alias Ersventaja.Policies.Models.InsuranceType
  alias Ersventaja.Customers.Models.Customer

  @fields ~w(
    detail
    start_date
    end_date
    calculated
    license_plate
    insurance_type_id
    customer_id
  )a

  @required_fields ~w(
    detail
    start_date
    end_date
    calculated
  )a

  schema "policies" do
    belongs_to(:insurer, Insurer)
    belongs_to(:insurance_type, InsuranceType)
    belongs_to(:customer, Customer)

    field(:detail, :string)
    field(:start_date, :date)
    field(:end_date, :date)
    field(:calculated, :boolean)
    field(:license_plate, :string)

    timestamps()
  end

  @doc false
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
  end
end
