defmodule ErsventajaWeb.WhatsappWebhookController do
  use ErsventajaWeb, :controller

  def verify(conn, params) do
    verify_token = Application.get_env(:ersventaja, :whatsapp)[:verify_token]

    cond do
      params["hub.mode"] != "subscribe" ->
        conn |> put_status(403) |> json(%{error: "invalid mode"})

      params["hub.verify_token"] != verify_token ->
        conn |> put_status(403) |> json(%{error: "invalid token"})

      true ->
        conn |> put_status(200) |> text(params["hub.challenge"])
    end
  end

  def webhook(conn, _params) do
    raw_body = conn.private[:whatsapp_raw_body]

    if is_nil(raw_body) do
      conn |> put_status(400) |> json(%{error: "missing body"})
    else
      if verify_signature(conn, raw_body) do
        payload = Jason.decode!(raw_body)
        Ersventaja.WhatsappBot.process_webhook(payload)
        conn |> put_status(200) |> json(%{ok: true})
      else
        conn |> put_status(401) |> json(%{error: "invalid signature"})
      end
    end
  end

  defp verify_signature(conn, body) do
    signature = get_req_header(conn, "x-hub-signature-256") |> List.first()
    app_secret = Application.get_env(:ersventaja, :whatsapp)[:app_secret]

    if is_nil(signature) or is_nil(app_secret) or app_secret == "" do
      false
    else
      expected =
        "sha256=" <>
          (:crypto.mac(:hmac, :sha256, app_secret, body) |> Base.encode16(case: :lower))

      Plug.Crypto.secure_compare(signature, expected)
    end
  end
end
