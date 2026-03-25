defmodule Ersventaja.Policies.Adapters.ResponseAdapter do
  @moduledoc false

  @spec get_policy_response(list()) :: list()
  def get_policy_response(list),
    do: Enum.map(list, &policy_response(&1))

  defp policy_response(
         %{
           calculated: calculated,
           customer_name: customer_name,
           detail: detail,
           end_date: end_date,
           file_name: file_name,
           id: id,
           insurer_id: insurer_id,
           start_date: start_date,
           insurer: %{
             name: insurer_name
           }
         } = policy
       ),
       do: %{
         calculated: calculated,
         customer_name: customer_name,
         detail: detail,
         end_date: end_date,
         file_name: file_name,
         id: id,
         insurer_id: insurer_id,
         insurer: insurer_name,
         start_date: start_date,
         customer_cpf_or_cnpj: Map.get(policy, :customer_cpf_or_cnpj),
         customer_phone: Map.get(policy, :customer_phone),
         customer_email: Map.get(policy, :customer_email),
         license_plate: Map.get(policy, :license_plate),
         insurance_type:
           case Map.get(policy, :insurance_type) do
             %{name: name} -> name
             _ -> nil
           end,
         insurance_type_id: Map.get(policy, :insurance_type_id)
       }
end
