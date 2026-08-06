defmodule Ersventaja.Policies.Adapters.ResponseAdapter do
  @moduledoc false

  @spec get_policy_response(list()) :: list()
  def get_policy_response(list),
    do: Enum.map(list, &policy_response(&1))

  defp policy_response(
         %{
           calculated: calculated,
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
       ) do
    customer = Map.get(policy, :customer)

    %{
      calculated: calculated,
      customer_name: customer_name_from(customer),
      detail: detail,
      end_date: end_date,
      file_name: file_name,
      id: id,
      insurer_id: insurer_id,
      insurer: insurer_name,
      start_date: start_date,
      customer_id: Map.get(policy, :customer_id),
      customer_cpf_or_cnpj: customer_cpf_from(customer),
      customer_phone: customer_phone_from(customer),
      customer_email: customer_email_from(customer),
      license_plate: Map.get(policy, :license_plate),
      insurance_type:
        case Map.get(policy, :insurance_type) do
          %{name: name} -> name
          _ -> nil
        end,
      insurance_type_id: Map.get(policy, :insurance_type_id)
    }
  end

  defp customer_name_from(%{name: name}), do: name
  defp customer_name_from(_), do: nil

  defp customer_cpf_from(%{cpf_cnpj: cpf_cnpj}), do: cpf_cnpj
  defp customer_cpf_from(_), do: nil

  defp customer_phone_from(%{phone: phone}), do: phone
  defp customer_phone_from(_), do: nil

  defp customer_email_from(%{email: email}), do: email
  defp customer_email_from(_), do: nil
end
