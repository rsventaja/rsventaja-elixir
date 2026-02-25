defmodule Ersventaja.Whatsapp.MetaApi do
  @moduledoc false
  @base_url "https://graph.facebook.com/v21.0"
  require Logger

  def send_text(phone_number_id, to_wa_id, body) do
    access_token = Application.get_env(:ersventaja, :whatsapp)[:access_token]

    if is_nil(access_token) or access_token == "" do
      Logger.warning("[WhatsApp] Send failed: WHATSAPP_ACCESS_TOKEN not set")
      {:error, :no_token}
    else
      url = "#{@base_url}/#{phone_number_id}/messages"
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
        {:ok, status, _headers, resp_body} when status in 200..299 ->
          decoded = Jason.decode!(resp_body)
          Logger.info("[WhatsApp] Message sent OK to #{to}, response: #{inspect(decoded)}")
          {:ok, decoded}

        {:ok, status, _headers, resp_body} ->
          Logger.warning("[WhatsApp] Send failed HTTP #{status}: #{inspect(resp_body)}")
          {:error, {:http, status, resp_body}}

        {:error, reason} ->
          Logger.warning("[WhatsApp] Send failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end
