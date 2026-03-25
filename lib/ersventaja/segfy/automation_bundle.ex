defmodule Ersventaja.Segfy.AutomationBundle do
  @moduledoc false

  # Credenciais para Basic em POST …/auths/token: GET do auto-bundle.js (mesmo asset do Gestão),
  # ou par explícito em SEGFY_AUTOMATION_CLIENT_ID / SECRET. Sem outros fallbacks.

  @recv_timeout 60_000
  @connect_timeout 15_000

  @pair_re ~r/const e="([0-9a-fA-F]{8}-[0-9a-fA-F-]{4}-[0-9a-fA-F-]{4}-[0-9a-fA-F-]{4}-[0-9a-fA-F]{12}:[a-fA-F0-9]{64,})"/

  @doc """
  Retorna `{client_id, client_secret}` para `/auths/token`:

  - Se `SEGFY_AUTOMATION_CLIENT_ID` e `SEGFY_AUTOMATION_CLIENT_SECRET` estiverem definidos, usa-os.
  - Senão: **GET** de `SEGFY_AUTO_BUNDLE_JS_URL` com `Origin`/`Referer` de `SEGFY_AUTOMATION_ORIGIN`
    e extrai `const e="uuid:hex"` do JS.
  """
  def resolve_client_pair do
    case env_client_pair() do
      {:ok, id, sec} ->
        {:ok, id, sec}

      :none ->
        fetch_pair_from_bundle_url()
    end
  end

  @doc false
  def parse_pair_from_js(js) when is_binary(js) do
    case Regex.run(@pair_re, js) do
      [_, pair] ->
        case String.split(pair, ":", parts: 2) do
          [id, sec] when byte_size(id) > 0 and byte_size(sec) > 0 -> {:ok, id, sec}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp env_client_pair do
    id = Ersventaja.Segfy.automation_client_id()
    sec = Ersventaja.Segfy.automation_client_secret()

    if is_binary(id) and id != "" and is_binary(sec) and sec != "" do
      {:ok, id, sec}
    else
      :none
    end
  end

  defp fetch_pair_from_bundle_url do
    url = Ersventaja.Segfy.auto_bundle_js_url() |> String.trim()
    o = Ersventaja.Segfy.automation_request_origin() |> String.trim() |> String.trim_trailing("/")

    o =
      if o == "" do
        "https://gestao.segfy.com"
      else
        o
      end

    headers = [
      {"Accept", "*/*"},
      {"Origin", o},
      {"Referer", o <> "/"}
    ]

    opts = [:with_body, recv_timeout: @recv_timeout, connect_timeout: @connect_timeout]

    case :hackney.get(url, headers, <<>>, opts) do
      {:ok, status, _, body} when status in 200..299 and is_binary(body) ->
        if byte_size(body) < 500 do
          {:error, :bundle_body_too_short}
        else
          case parse_pair_from_js(body) do
            {:ok, id, sec} -> {:ok, id, sec}
            :error -> {:error, :pair_pattern_not_found}
          end
        end

      {:ok, status, _, body} ->
        {:error, {:http, status, truncate(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp truncate(s) when is_binary(s) and byte_size(s) > 200,
    do: binary_part(s, 0, 200) <> "..."

  defp truncate(s), do: to_string(s)
end
