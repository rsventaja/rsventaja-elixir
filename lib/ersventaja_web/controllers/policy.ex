defmodule ErsventajaWeb.PolicyController do
  use ErsventajaWeb, :controller

  alias Ersventaja.Policies
  alias Ersventaja.Policies.OCR
  use OpenApiSpex.ControllerSpecs

  alias ErsventajaWeb.Schemas.{
    CreatePolicyRequest,
    CreatePolicyResponse,
    CreatePolicyResponseList,
    UpdatePolicyStatusRequest
  }

  operation :create,
    description: "Create policy",
    tags: ["policy"],
    responses: %{
      200 => {"Policy", "application/json", CreatePolicyResponse}
    },
    security: [%{"bearerAuth" => []}],
    request_body: {"Policy params", "application/json", CreatePolicyRequest}

  def create(conn, attrs) do
    resp_json(conn, Policies.add_policy(attrs))
  end

  operation :last_30_days,
    description: "Get policies in last 30 days",
    tags: ["policy"],
    responses: %{
      200 => {"Policies list", "application/json", CreatePolicyResponseList}
    },
    security: [%{"bearerAuth" => []}]

  def last_30_days(conn, _attrs) do
    resp_json(conn, Policies.last_30_days())
  end

  operation :get_policies,
    description: "Get policies filtered",
    tags: ["policy"],
    parameters: [
      current_only: [
        in: :query,
        description: "Current policies only",
        type: :boolean
      ],
      name: [
        in: :query,
        description: "Policy name",
        type: :string
      ]
    ],
    responses: %{
      200 => {"Policies list", "application/json", CreatePolicyResponseList}
    },
    security: [%{"bearerAuth" => []}]

  def get_policies(conn, %{"current_only" => current_only, "name" => name}) do
    resp_json(conn, Policies.get_policies(current_only, name))
  end

  operation :delete,
    description: "Delete policy",
    tags: ["policy"],
    responses: %{
      200 => {"Policy", "application/json", CreatePolicyResponse}
    },
    security: [%{"bearerAuth" => []}],
    parameters: [
      id: [
        in: :path,
        description: "Policy ID",
        type: :integer,
        example: 1
      ]
    ]

  def delete(conn, %{"id" => id}) do
    resp_json(conn, Policies.delete_policy(id))
  end

  operation :update_status,
    description: "Update policy status",
    tags: ["policy"],
    responses: %{
      200 => {"Policy", "application/json", CreatePolicyResponse}
    },
    security: [%{"bearerAuth" => []}],
    parameters: [
      id: [
        in: :path,
        description: "Policy ID",
        type: :integer,
        example: 1
      ]
    ],
    request_body: {"Policy status", "application/json", UpdatePolicyStatusRequest}

  def update_status(conn, %{"id" => id, "status" => status}) do
    resp_json(conn, Policies.update_status(id, status))
  end

  operation :extract_ocr,
    description: "Extract policy information from PDF using OCR",
    tags: ["policy"],
    responses: %{
      200 => {"Extracted policy information", "application/json", %{}}
    },
    security: [%{"bearerAuth" => []}],
    request_body:
      {"Base64 encoded PDF file", "application/json",
       %{
         type: :object,
         properties: %{
           encoded_file: %{
             type: :string,
             description: "Base64 encoded PDF file content"
           }
         },
         required: [:encoded_file]
       }}

  def extract_ocr(conn, %{"encoded_file" => encoded_file}) do
    case OCR.extract_policy_info(encoded_file) do
      {:ok, info} ->
        # Convert Date structs to ISO8601 strings for JSON response, handle nil values
        json_info =
          info
          |> Enum.map(fn
            {key, %Date{} = date} -> {key, Date.to_iso8601(date)}
            {key, value} -> {key, value}
          end)
          |> Map.new()

        resp_json(conn, json_info)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to extract information from PDF", reason: inspect(reason)})
    end
  end

  def extract_ocr(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing encoded_file parameter"})
  end

  def download_by_token(conn, %{"token" => token}) do
    case Policies.verify_download_token(token) do
      nil ->
        conn
        |> put_status(403)
        |> json(%{error: "Link inválido ou expirado"})

      policy_id ->
        policy = Policies.get_policy(policy_id)

        if is_nil(policy) do
          conn |> put_status(404) |> json(%{error: "Apólice não encontrada"})
        else
          send_policy_pdf(conn, policy[:file_name])
        end
    end
  end

  def download_by_token(conn, _),
    do: conn |> put_status(400) |> json(%{error: "Token obrigatório"})

  defp send_policy_pdf(conn, file_name) do
    case Policies.download_policy_file(file_name) do
      {:ok, body} ->
        conn
        |> put_resp_content_type("application/pdf")
        |> put_resp_header("content-disposition", "attachment; filename=\"apolice.pdf\"")
        |> send_resp(200, body)

      {:error, _} ->
        conn |> put_status(404) |> json(%{error: "Arquivo não encontrado"})
    end
  end
end
