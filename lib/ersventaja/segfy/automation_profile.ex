defmodule Ersventaja.Segfy.AutomationProfile do
  @moduledoc false

  # Fluxo do app Segfy (HAR): POST upfygate/automation/api/profile/.../list-by-intranet
  # com cookie do gate + intranet_id → profiles[].token (hex) usado em config.token na api.automation.

  require Logger

  @path "/automation/api/profile/version/1.0/list-by-intranet"
  @cache_key :segfy_automation_profile_token
  @recv_timeout 45_000
  @connect_timeout 15_000

  @doc """
  Token opaco de automação vindo do Upfy Gate (`list-by-intranet`), com cache no TTL da sessão.
  Retorna `{:ok, token}` | {:error, reason} | :not_configured (sem intranet_id).
  """
  def ensure do
    case Ersventaja.Segfy.resolved_intranet_id() do
      {:ok, id} when is_integer(id) and id > 0 ->
        case read_cache(id) do
          {:ok, t} -> {:ok, t}
          :miss -> fetch_and_cache(id)
        end

      _ ->
        :not_configured
    end
  end

  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp read_cache(intranet_id) do
    now = System.system_time(:second)

    case :persistent_term.get(@cache_key, :none) do
      {t, exp, ^intranet_id} when is_binary(t) and is_integer(exp) and exp > now ->
        {:ok, t}

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp write_cache(token, intranet_id, ttl_sec)
       when is_binary(token) and is_integer(intranet_id) and is_integer(ttl_sec) do
    exp = System.system_time(:second) + ttl_sec
    :persistent_term.put(@cache_key, {token, exp, intranet_id})
  end

  defp fetch_and_cache(intranet_id) do
    with {:ok, cookie} <- Ersventaja.Segfy.Auth.gate_cookie() do
      base = Ersventaja.Segfy.upfy_gate_base_url() |> String.trim_trailing("/")
      url = base <> @path

      body =
        Jason.encode!(%{
          "config" => %{
            "intranet_id" => intranet_id
          }
        })

      headers = [
        {"Content-Type", "application/json"},
        {"Accept", "application/json"},
        {"Cookie", cookie},
        {"Origin", "https://app.segfy.com"}
      ]

      opts = [:with_body, recv_timeout: @recv_timeout, connect_timeout: @connect_timeout]

      case :hackney.post(url, headers, body, opts) do
        {:ok, status, _rh, resp_body} when status in 200..299 ->
          case parse_profiles_response(resp_body) do
            {:ok, profiles} ->
              case pick_profile_token(profiles) do
                {:ok, token} ->
                  ttl = session_ttl_seconds()
                  write_cache(token, intranet_id, ttl)
                  {:ok, token}

                {:error, _} = e ->
                  e
              end

            {:error, _} = e ->
              Logger.warning("[Segfy AutomationProfile] JSON inesperado: #{truncate(resp_body)}")
              e
          end

        {:ok, 401, _, _} ->
          Ersventaja.Segfy.Auth.clear_cache()
          {:error, :unauthorized}

        {:ok, status, _, resp_body} ->
          Logger.warning("[Segfy AutomationProfile] HTTP #{status}: #{truncate(resp_body)}")
          {:error, {:http, status}}

        {:error, reason} ->
          Logger.warning("[Segfy AutomationProfile] request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp session_ttl_seconds do
    case Ersventaja.Segfy.Auth.session_ttl_seconds_remaining() do
      n when is_integer(n) and n > 120 -> n - 60
      _ -> 2700
    end
  end

  defp parse_profiles_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"profiles" => list}} when is_list(list) ->
        {:ok, list}

      {:ok, %{"data" => %{"profiles" => list}}} when is_list(list) ->
        {:ok, list}

      {:ok, other} ->
        {:error, {:unexpected_keys, Map.keys(other)}}

      _ ->
        {:error, :invalid_json}
    end
  end

  defp pick_profile_token(profiles) do
    name_filter = Ersventaja.Segfy.automation_profile_name()

    cond do
      is_binary(name_filter) and String.trim(name_filter) != "" ->
        target = String.downcase(String.trim(name_filter))

        case Enum.find(profiles, fn p ->
               n = profile_name(p)
               is_binary(n) and String.downcase(String.trim(n)) == target
             end) do
          nil -> {:error, :profile_name_not_found}
          p -> token_from_profile(p)
        end

      true ->
        preferred =
          Enum.find(profiles, fn p ->
            n = profile_name(p) || ""

            String.upcase(n) != "GERAL" and
              (Map.get(p, "broker_id") != nil or Map.get(p, "user_id") != nil)
          end)

        case preferred || List.first(profiles) do
          nil -> {:error, :no_profiles}
          p -> token_from_profile(p)
        end
    end
  end

  defp profile_name(p) when is_map(p), do: Map.get(p, "name") || Map.get(p, :name)

  defp token_from_profile(p) when is_map(p) do
    case Map.get(p, "token") || Map.get(p, :token) do
      t when is_binary(t) and t != "" -> {:ok, t}
      _ -> {:error, :token_missing_in_profile}
    end
  end

  defp truncate(s) when is_binary(s) and byte_size(s) > 400, do: binary_part(s, 0, 400) <> "..."
  defp truncate(s), do: to_string(s)
end
