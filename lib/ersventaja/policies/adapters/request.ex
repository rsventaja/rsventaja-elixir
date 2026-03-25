defmodule Ersventaja.Policies.Adapters.RequestAdapter do
  @moduledoc false

  alias Ersventaja.Policies.Schemas.In.CreatePolicyRequest

  @spec create_policy_request(map) :: Ersventaja.Policies.Schemas.In.CreatePolicyRequest.t()
  def create_policy_request(
        %{
          "encoded_file" => encoded_file,
          "name" => name,
          "detail" => detail,
          "start_date" => start_date,
          "end_date" => end_date,
          "insurer_id" => insurer_id
        } = attrs
      ),
      do: %CreatePolicyRequest{
        encoded_file: encoded_file,
        name: name,
        detail: detail,
        start_date: Date.from_iso8601!(start_date),
        end_date: Date.from_iso8601!(end_date),
        insurer_id: insurer_id,
        customer_cpf_or_cnpj: Map.get(attrs, "customer_cpf_or_cnpj"),
        customer_phone: Map.get(attrs, "customer_phone"),
        customer_email: Map.get(attrs, "customer_email"),
        license_plate: Map.get(attrs, "license_plate"),
        insurance_type_id: Map.get(attrs, "insurance_type_id")
      }
end
