defmodule Ersventaja.Segfy.Models.SegfyQuotation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ersventaja.Policies.Models.Policy

  @fields ~w(policy_id quotation_url codigo_orcamento quotation_id premiums)a
  @required ~w(policy_id)a

  schema "segfy_quotations" do
    belongs_to(:policy, Policy)
    field(:quotation_url, :string)
    field(:codigo_orcamento, :string)
    field(:quotation_id, :string)
    field(:premiums, :map, default: %{})

    timestamps()
  end

  def changeset(quotation, attrs) do
    quotation
    |> cast(attrs, @fields)
    |> validate_required(@required)
    |> foreign_key_constraint(:policy_id)
    |> unique_constraint(:policy_id)
  end
end
