defmodule Ersventaja.Policies.Models.InsuranceType do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:id, :name]}

  schema "insurance_types" do
    field(:name, :string)

    timestamps()
  end

  @doc false
  def changeset(insurance_type, attrs) do
    insurance_type
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
