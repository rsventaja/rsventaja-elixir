defmodule ErsventajaWeb.Plugs.WhatsappRawBody do
  @moduledoc """
  For POST /api/whatsapp/webhook, reads the raw body before Plug.Parsers consumes it,
  so we can verify the X-Hub-Signature-256 from Meta.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.request_path == "/api/whatsapp/webhook" and conn.method == "POST" do
      case read_body(conn) do
        {:ok, body, conn} ->
          conn
          |> put_private(:whatsapp_raw_body, body)

        {:more, _body, conn} ->
          conn
          |> send_resp(413, "Payload too large")
          |> halt()
      end
    else
      conn
    end
  end
end
