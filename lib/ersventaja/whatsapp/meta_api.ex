defmodule Ersventaja.Whatsapp.MetaApi do
  @base_url "https://graph.facebook.com/v21.0"

  def send_text(phone_number_id, to_wa_id, body) do
    access_token = Application.get_env(:ersventaja, :whatsapp)[:access_token]
    if is_nil(access_token) or access_token == "", do: {:error, :no_token}

    url = "#{@base_url}/#{phone_number_id}/messages"
    # to must be without + prefix
    to = String.replace(to_wa_id, "+", "")

    payload = %{
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: to,
      type: "text",
      text: %{preview_url: false, body: body}
    }

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"}
    ]

    case :hackney.post(url, headers, Jason.encode!(payload), [:with_body]) do
      {:ok, status, _headers, body} when status in 200..299 ->
        {:ok, Jason.decode!(body)}

      {:ok, status, _headers, body} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
