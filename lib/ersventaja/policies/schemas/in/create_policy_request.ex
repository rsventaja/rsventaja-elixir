defmodule Ersventaja.Policies.Schemas.In.CreatePolicyRequest do
  @moduledoc false
  @derive Jason.Encoder

  @fields quote(
            do: [
              name: String.t(),
              detail: String.t(),
              start_date: Date.t(),
              end_date: Date.t(),
              insurer_id: integer(),
              encoded_file: String.t(),
              customer_cpf_or_cnpj: String.t() | nil,
              customer_phone: String.t() | nil,
              customer_email: String.t() | nil,
              license_plate: String.t() | nil,
              insurance_type_id: integer() | nil
            ]
          )

  defstruct Keyword.keys(@fields)

  @type t() :: %__MODULE__{unquote_splicing(@fields)}
end
