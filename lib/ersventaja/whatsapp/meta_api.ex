defmodule Ersventaja.Whatsapp.MetaApi do
  @moduledoc """
  WhatsApp Cloud API client (Graph API v21.0).

  Supports text, interactive buttons, interactive lists, media upload, and
  document messages.
  """
  @base_url "https://graph.facebook.com/v21.0"
  require Logger

  # ---------------------------------------------------------------------------
  # Text message
  # ---------------------------------------------------------------------------

  def send_text(phone_number_id, to_wa_id, body) do
    payload = %{
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: sanitize_phone(to_wa_id),
      type: "text",
      text: %{preview_url: false, body: body}
    }

    post_message(phone_number_id, payload)
  end

  # ---------------------------------------------------------------------------
  # Interactive reply buttons (max 3)
  # ---------------------------------------------------------------------------

  @doc """
  Sends an interactive message with reply buttons (max 3).

  ## Examples

      iex> send_interactive_buttons(phone_id, "5511999999999", "Autoriza?",
      ...>   [%{id: "sim", title: "Sim"}, %{id: "nao", title: "Não"}])
      {:ok, %{"messages" => [...]}}

  Each button is a map with `:id` (unique, max 256 chars) and `:title` (label, max 20 chars).
  Optional `opts` keys: `:header` (string, max 60 chars), `:footer` (string, max 60 chars).
  """
  def send_interactive_buttons(phone_number_id, to_wa_id, body_text, buttons, opts \\ []) do
    header_text = Keyword.get(opts, :header)
    footer_text = Keyword.get(opts, :footer)

    interactive = %{
      type: "button",
      body: %{text: body_text},
      action: %{
        buttons: Enum.map(buttons, fn %{id: id, title: title} ->
          %{type: "reply", reply: %{id: id, title: title}}
        end)
      }
    }

    interactive =
      if header_text,
        do: Map.put(interactive, :header, %{type: "text", text: header_text}),
        else: interactive

    interactive =
      if footer_text,
        do: Map.put(interactive, :footer, %{text: footer_text}),
        else: interactive

    payload = %{
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: sanitize_phone(to_wa_id),
      type: "interactive",
      interactive: interactive
    }

    post_message(phone_number_id, payload)
  end

  # ---------------------------------------------------------------------------
  # Interactive list message (max 10 items across all sections)
  # ---------------------------------------------------------------------------

  @doc """
  Sends an interactive list message with sections and rows.

  `sections` is a list of maps:
      %{title: "Section Title", rows: [%{id: "1", title: "Option", description: "Desc"}]}

  - Max 10 sections
  - Max 10 rows total across all sections
  - Row title: max 24 chars
  - Row description: max 72 chars (optional)
  """
  def send_interactive_list(phone_number_id, to_wa_id, body_text, button_text, sections, opts \\ []) do
    header_text = Keyword.get(opts, :header)
    footer_text = Keyword.get(opts, :footer)

    interactive = %{
      type: "list",
      body: %{text: body_text},
      action: %{
        button: button_text,
        sections:
          Enum.map(sections, fn %{title: sec_title, rows: rows} ->
            %{
              title: sec_title,
              rows:
                Enum.map(rows, fn row ->
                  row_map = %{id: row.id, title: row.title}
                  if Map.has_key?(row, :description),
                    do: Map.put(row_map, :description, row.description),
                    else: row_map
                end)
            }
          end)
      }
    }

    interactive =
      if header_text,
        do: Map.put(interactive, :header, %{type: "text", text: header_text}),
        else: interactive

    interactive =
      if footer_text,
        do: Map.put(interactive, :footer, %{text: footer_text}),
        else: interactive

    payload = %{
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: sanitize_phone(to_wa_id),
      type: "interactive",
      interactive: interactive
    }

    post_message(phone_number_id, payload)
  end

  # ---------------------------------------------------------------------------
  # Media upload
  # ---------------------------------------------------------------------------

  @doc """
  Uploads binary media to WhatsApp and returns a media ID.

  The media ID is valid for 30 days and can be reused across recipients.

  ## Examples

      iex> upload_media(phone_id, pdf_binary, "application/pdf")
      {:ok, "4490709327384033"}

  """
  def upload_media(phone_number_id, file_binary, mime_type) do
    access_token = get_access_token()
    if is_nil(access_token), do: throw({:error, :no_token})

    url = "#{@base_url}/#{phone_number_id}/media"

    boundary = "WhatsAppBoundary#{:rand.uniform(9_999_999)}"

    body =
      [
        "--#{boundary}\r\n",
        "Content-Disposition: form-data; name=\"messaging_product\"\r\n\r\n",
        "whatsapp\r\n",
        "--#{boundary}\r\n",
        "Content-Disposition: form-data; name=\"file\"; filename=\"policy.pdf\"\r\n",
        "Content-Type: #{mime_type}\r\n\r\n",
        file_binary,
        "\r\n--#{boundary}--\r\n"
      ]

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "multipart/form-data; boundary=#{boundary}"}
    ]

    case :hackney.post(url, headers, IO.iodata_to_binary(body), [:with_body]) do
      {:ok, status, _headers, resp_body} when status in 200..299 ->
        decoded = Jason.decode!(resp_body)
        Logger.info("[WhatsApp] Media uploaded OK, id: #{decoded["id"]}")
        {:ok, decoded["id"]}

      {:ok, status, _headers, resp_body} ->
        Logger.warning("[WhatsApp] Media upload failed HTTP #{status}: #{inspect(resp_body)}")
        {:error, {:http, status, resp_body}}

      {:error, reason} ->
        Logger.warning("[WhatsApp] Media upload failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Document message
  # ---------------------------------------------------------------------------

  @doc """
  Sends a document (PDF) to a WhatsApp user.

  Accepts either:
  - `{:media_id, id}` — a previously uploaded media ID
  - `{:link, url}` — a publicly-accessible HTTPS URL

  Options: `:caption` (string), `:filename` (string, displayed to recipient)
  """
  def send_document(phone_number_id, to_wa_id, media_source, opts \\ []) do
    filename = Keyword.get(opts, :filename, "documento.pdf")
    caption = Keyword.get(opts, :caption)

    document =
      case media_source do
        {:media_id, id} ->
          %{id: id, filename: filename}

        {:link, url} ->
          %{link: url, filename: filename}
      end

    document = if caption, do: Map.put(document, :caption, caption), else: document

    payload = %{
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: sanitize_phone(to_wa_id),
      type: "document",
      document: document
    }

    post_message(phone_number_id, payload)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp get_access_token do
    token = Application.get_env(:ersventaja, :whatsapp)[:access_token]
    if is_nil(token) or token == "" do
      Logger.warning("[WhatsApp] WHATSAPP_ACCESS_TOKEN not set")
      nil
    else
      token
    end
  end

  defp sanitize_phone(phone), do: String.replace(phone, "+", "")

  defp post_message(phone_number_id, payload) do
    access_token = get_access_token()

    if is_nil(access_token) or access_token == "" do
      Logger.warning("[WhatsApp] Send failed: WHATSAPP_ACCESS_TOKEN not set")
      {:error, :no_token}
    else
      url = "#{@base_url}/#{phone_number_id}/messages"

      headers = [
        {"Authorization", "Bearer #{access_token}"},
        {"Content-Type", "application/json"}
      ]

      case :hackney.post(url, headers, Jason.encode!(payload), [:with_body]) do
        {:ok, status, _headers, resp_body} when status in 200..299 ->
          decoded = Jason.decode!(resp_body)
          Logger.info("[WhatsApp] Message sent OK, response: #{inspect(decoded)}")
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
