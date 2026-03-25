defmodule Ersventaja.Segfy.UpfyGate do
  @moduledoc false
  require Logger

  @recv_timeout 90_000
  @connect_timeout 15_000

  @doc """
  POST JSON no domínio `upfygate.segfy.com` (ex.: `/bgt/api/budget/list`).

  Cookie de sessão via `Ersventaja.Segfy.Auth` (Firebase + SSO).
  """
  def post(path, body) when is_binary(path) and is_map(body) do
    if Ersventaja.Segfy.upfy_gate_configured?() do
      do_post(path, body, retry_on_unauthorized: true)
    else
      {:error, :missing_upfy_gate_auth}
    end
  end

  defp do_post(path, body, opts) do
    url = String.trim_trailing(Ersventaja.Segfy.upfy_gate_base_url(), "/") <> path

    case build_headers() do
      {:error, reason} ->
        {:error, reason}

      {:ok, headers} ->
        json = Jason.encode!(body)

        hackney_opts = [
          :with_body,
          recv_timeout: @recv_timeout,
          connect_timeout: @connect_timeout
        ]

        send_gate_request(url, headers, json, path, body, opts, hackney_opts)
    end
  end

  defp send_gate_request(url, headers, json, path, body, opts, hackney_opts) do
    case :hackney.post(url, headers, json, hackney_opts) do
      {:ok, status, _headers, resp_body} when status in 200..299 ->
        decode_json(resp_body)

      {:ok, 401, _, _} = err ->
        maybe_retry_after_401(path, body, opts, err)

      {:ok, status, _headers, resp_body} ->
        Logger.warning("[Segfy UpfyGate] HTTP #{status} #{path}: #{truncate(resp_body)}")
        {:error, {:http, status, resp_body}}

      {:error, reason} ->
        Logger.warning("[Segfy UpfyGate] request failed #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_retry_after_401(path, body, %{retry_on_unauthorized: true}, _err) do
    Ersventaja.Segfy.Auth.clear_cache()
    do_post(path, body, %{retry_on_unauthorized: false})
  end

  defp maybe_retry_after_401(_path, _body, %{retry_on_unauthorized: false}, _err) do
    {:error, {:http, 401, "unauthorized"}}
  end

  defp build_headers do
    case Ersventaja.Segfy.Auth.gate_cookie() do
      {:error, _} = e ->
        e

      {:ok, cookie} ->
        h = [{"Content-Type", "application/json"}, {"Cookie", cookie}]
        {:ok, h}
    end
  end

  defp decode_json(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, {:invalid_json, resp_body}}
    end
  end

  defp truncate(s) when is_binary(s) and byte_size(s) > 500, do: binary_part(s, 0, 500) <> "..."
  defp truncate(s), do: s
end
