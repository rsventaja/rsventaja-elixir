defmodule Ersventaja.Segfy.AutomationToken do
  @moduledoc false

  # Mesmo fluxo do front (bundles.segfy.com/.../auto-bundle.js): POST {base}/auths/token
  # com Authorization: Basic base64(client_id:client_secret) → JWT curto em data.token.

  require Logger

  @cache_key :segfy_automation_cc_token
  @recv_timeout 30_000
  @connect_timeout 15_000

  @doc """
  JWT de automação obtido por client credentials (`/auths/token`), com cache até ~exp do JWT.

  Credenciais: `SEGFY_AUTOMATION_CLIENT_ID`/`SECRET` ou par extraído do GET do `auto-bundle.js`
  (`Ersventaja.Segfy.AutomationBundle`).

  Retorna `{:ok, token}` | {:error, reason} | :not_configured
  """
  def ensure do
    case read_cache() do
      {:ok, t} ->
        {:ok, t}

      :miss ->
        case Ersventaja.Segfy.AutomationBundle.resolve_client_pair() do
          {:ok, id, sec} ->
            fetch_and_cache(id, sec)

          {:error, reason} ->
            Logger.warning("[Segfy AutomationToken] sem client_id:secret: #{inspect(reason)}")
            :not_configured
        end
    end
  end

  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp read_cache do
    now = System.system_time(:second)

    case :persistent_term.get(@cache_key, :none) do
      {t, exp} when is_binary(t) and is_integer(exp) and exp > now ->
        {:ok, t}

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp write_cache(token, ttl_sec) when is_binary(token) and is_integer(ttl_sec) do
    exp = System.system_time(:second) + ttl_sec
    :persistent_term.put(@cache_key, {token, exp})
  end

  defp fetch_and_cache(id, sec) when is_binary(id) and is_binary(sec) do
    base = Ersventaja.Segfy.automation_base_url() |> String.trim_trailing("/")
    url = base <> "/auths/token"

    basic = Base.encode64(id <> ":" <> sec)
    json = "{}"

    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Basic " <> basic}
    ]

    opts = [:with_body, recv_timeout: @recv_timeout, connect_timeout: @connect_timeout]

    case :hackney.post(url, headers, json, opts) do
      {:ok, status, _rh, resp_body} when status in 200..299 ->
        case parse_token_response(resp_body) do
          {:ok, token} ->
            ttl = ttl_from_jwt_or_default(token)
            write_cache(token, ttl)
            {:ok, token}

          {:error, _} = e ->
            Logger.warning("[Segfy AutomationToken] resposta sem token: #{truncate(resp_body)}")
            e
        end

      {:ok, status, _, resp_body} ->
        Logger.warning("[Segfy AutomationToken] HTTP #{status} #{url}: #{truncate(resp_body)}")
        {:error, {:http, status, resp_body}}

      {:error, reason} ->
        Logger.warning("[Segfy AutomationToken] request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_token_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => %{"token" => t}}} when is_binary(t) and t != "" ->
        {:ok, t}

      {:ok, %{"data" => t}} when is_binary(t) and t != "" ->
        {:ok, t}

      {:ok, %{"token" => t}} when is_binary(t) and t != "" ->
        {:ok, t}

      {:ok, %{"access_token" => t}} when is_binary(t) and t != "" ->
        {:ok, t}

      {:ok, other} ->
        Logger.warning("[Segfy AutomationToken] JSON inesperado keys=#{inspect(Map.keys(other))}")
        {:error, :token_not_in_response}

      _ ->
        {:error, :invalid_json}
    end
  end

  defp ttl_from_jwt_or_default(token) when is_binary(token) do
    case jwt_exp_unix(token) do
      {:ok, exp} ->
        now = System.system_time(:second)
        # margem 2 min; mínimo 5 min; máx 55 min
        min(max(exp - now - 120, 300), 3300)

      _ ->
        2700
    end
  end

  defp jwt_exp_unix(token) when is_binary(token) do
    parts = String.split(token, ".")

    with [_, pl, _] <- parts,
         {:ok, bin} <- Base.url_decode64(pl, padding: true),
         {:ok, %{"exp" => exp}} when is_integer(exp) <- Jason.decode(bin) do
      {:ok, exp}
    else
      _ -> :error
    end
  end

  defp truncate(s) when is_binary(s) and byte_size(s) > 400, do: binary_part(s, 0, 400) <> "..."
  defp truncate(s), do: to_string(s)
end
