defmodule Ersventaja.Segfy.Auth do
  @moduledoc """
  Login programático na Segfy via **Firebase** (`verifyPassword`) + **`api.sso.segfy.com/login`**.

  Gera o header `Cookie` para o Upfy Gate após Firebase `verifyPassword` e `api.sso.segfy.com/login`.

  O JWT em `Set-Cookie: segfy_sessiontoken=...` é guardado para o gate e para claims (ex.: intranet).

  O token usado em `config.token` na `api.automation.segfy.com` deve ser, em geral, o **token opaco**
  devolvido por `POST …/automation/api/profile/.../list-by-intranet` no Upfy Gate (ver
  `Ersventaja.Segfy.AutomationProfile`). O JWT do SSO sozinho costuma **não** bastar.

  Variáveis: `SEGFY_FIREBASE_WEB_API_KEY`, `SEGFY_LOGIN_EMAIL`, `SEGFY_LOGIN_PASSWORD`.

  Cookie e token (JWT SSO ou JSON) são guardados em `:persistent_term` com TTL derivado de
  `expiresIn` do Firebase (com margem).
  """

  require Logger

  @verify_url "https://www.googleapis.com/identitytoolkit/v3/relyingparty/verifyPassword"
  @sso_login_url "https://api.sso.segfy.com/login"

  @cache_key :segfy_gate_cookie_cache

  @recv_timeout 60_000
  @connect_timeout 15_000

  @doc """
  Retorna o valor do header `Cookie` para `upfygate.segfy.com`, usando cache quando válido.
  """
  def gate_cookie do
    case read_cache() do
      {:ok, cookie, _, _} -> {:ok, cookie}
      :miss -> login_and_cache_return_cookie()
    end
  end

  @doc """
  Token de automação (`config.token` na API automation), se vier no login SSO ou já em cache.
  Garante sessão (mesmo fluxo que `gate_cookie/0`).
  """
  def automation_token_from_session do
    case read_cache() do
      {:ok, _cookie, at, _} when is_binary(at) and at != "" ->
        {:ok, at}

      :miss ->
        case login_and_cache_return_cookie() do
          {:ok, _} ->
            case read_cache() do
              {:ok, _c, at, _} when is_binary(at) and at != "" -> {:ok, at}
              _ -> {:error, :missing_automation_token}
            end

          {:error, _} = e ->
            e
        end

      {:ok, _, _, _} ->
        {:error, :missing_automation_token}
    end
  end

  @doc """
  Lê o token de automação já em cache (JWT `segfy_sessiontoken` do SSO ou corpo JSON), sem novo login.
  """
  def peek_automation_token_cached do
    case read_cache() do
      {:ok, _cookie, at, _} when is_binary(at) and at != "" -> {:ok, at}
      _ -> :miss
    end
  end

  @doc """
  `idToken` do Firebase (`verifyPassword`), guardado no mesmo TTL do cache de sessão.

  Alguns endpoints em `api.automation.segfy.com` aceitam `Authorization: Bearer` com este token
  quando o JWT do SSO (`segfy_sessiontoken`) retorna 401.
  """
  def peek_firebase_id_token_cached do
    case read_cache() do
      {:ok, _cookie, _at, fb} when is_binary(fb) and fb != "" -> {:ok, fb}
      _ -> :miss
    end
  end

  @doc """
  Limpa o cookie em cache (útil após 401 ou troca de senha).
  """
  def clear_cache do
    :persistent_term.erase(@cache_key)
    Ersventaja.Segfy.AutomationProfile.clear_cache()
    Ersventaja.Segfy.AutomationToken.clear_cache()
    :ok
  end

  @doc false
  def session_ttl_seconds_remaining do
    now = System.system_time(:second)

    case :persistent_term.get(@cache_key, :none) do
      {:segfy_auth, _, _, exp, _} when is_integer(exp) -> max(exp - now, 0)
      {:segfy_auth, _, _, exp} when is_integer(exp) -> max(exp - now, 0)
      {:segfy_cookie, _, exp} when is_integer(exp) -> max(exp - now, 0)
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  `intranet_id` para `list-by-intranet` no gate: vindo do JWT SSO (claims / `segfy`) se possível.
  """
  def intranet_id_from_sso_jwt do
    with {:ok, jwt} <- peek_automation_token_cached(),
         {:ok, claims} <- jwt_payload_map(jwt),
         {:ok, n} <- extract_intranet_id_from_claims(claims) do
      {:ok, n}
    else
      _ -> :error
    end
  end

  defp extract_intranet_id_from_claims(claims) when is_map(claims) do
    keys = ["intranet_id", "intranetId", "IntranetId"]

    case pick_intranet_in_map(claims, keys) do
      {:ok, n} ->
        {:ok, n}

      :miss ->
        case Map.get(claims, "segfy") do
          %{} = seg ->
            case pick_intranet_in_map(seg, keys) do
              {:ok, n} -> {:ok, n}
              _ -> :error
            end

          _ ->
            :error
        end
    end
  end

  defp pick_intranet_in_map(map, keys) when is_map(map) do
    found =
      Enum.find_value(keys, fn k ->
        case Map.get(map, k) do
          n when is_integer(n) and n > 0 ->
            {:ok, n}

          s when is_binary(s) ->
            case Integer.parse(String.trim(s)) do
              {i, ""} when i > 0 -> {:ok, i}
              _ -> nil
            end

          _ ->
            nil
        end
      end)

    case found do
      {:ok, _} = ok -> ok
      _ -> :miss
    end
  end

  defp read_cache do
    now = System.system_time(:second)

    case :persistent_term.get(@cache_key, :none) do
      {:segfy_auth, cookie, atoken, exp, firebase_id_token}
      when is_integer(exp) and is_binary(cookie) ->
        fb =
          if is_binary(firebase_id_token) and firebase_id_token != "",
            do: firebase_id_token,
            else: nil

        if now < exp, do: {:ok, cookie, atoken, fb}, else: :miss

      {:segfy_auth, cookie, atoken, exp} when is_integer(exp) and is_binary(cookie) ->
        if now < exp, do: {:ok, cookie, atoken, nil}, else: :miss

      # legado: só cookie
      {:segfy_cookie, cookie, exp} when is_integer(exp) and is_binary(cookie) ->
        if now < exp, do: {:ok, cookie, nil, nil}, else: :miss

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp write_cache(cookie, automation_token, ttl_sec, firebase_id_token)
       when is_binary(cookie) and is_integer(ttl_sec) do
    exp = System.system_time(:second) + ttl_sec

    at =
      if is_binary(automation_token) and automation_token != "", do: automation_token, else: nil

    fb =
      if is_binary(firebase_id_token) and firebase_id_token != "",
        do: firebase_id_token,
        else: nil

    :persistent_term.put(@cache_key, {:segfy_auth, cookie, at, exp, fb})
  end

  defp login_and_cache_return_cookie do
    case login_and_cache() do
      {:ok, cookie, _} -> {:ok, cookie}
      {:error, _} = e -> e
    end
  end

  defp login_and_cache do
    with {:ok, api_key, email, password} <- firebase_credentials(),
         {:ok, id_token, ttl_sec} <- firebase_verify_password(api_key, email, password),
         {:ok, cookie, atoken} <- segfy_sso_login(id_token),
         cookie <- upfy_gate_auth_login_merge_cookies(cookie) do
      # TTL do cache: menor entre expiração do idToken e ~50 min
      cache_ttl = min(max(ttl_sec - 120, 300), 3000)
      write_cache(cookie, atoken, cache_ttl, id_token)
      {:ok, cookie, atoken}
    end
  end

  defp firebase_credentials do
    cfg = Ersventaja.Segfy.config()
    k = Keyword.get(cfg, :firebase_web_api_key)
    e = Keyword.get(cfg, :login_email)
    p = Keyword.get(cfg, :login_password)

    cond do
      not (is_binary(k) and k != "") ->
        {:error, :missing_firebase_api_key}

      not (is_binary(e) and e != "") ->
        {:error, :missing_login_email}

      not (is_binary(p) and p != "") ->
        {:error, :missing_login_password}

      true ->
        {:ok, k, e, p}
    end
  end

  defp firebase_verify_password(api_key, email, password) do
    url = @verify_url <> "?key=" <> URI.encode_www_form(api_key)

    body =
      Jason.encode!(%{
        "email" => email,
        "password" => password,
        "returnSecureToken" => true
      })

    headers = [{"Content-Type", "application/json"}]
    opts = [:with_body, recv_timeout: @recv_timeout, connect_timeout: @connect_timeout]

    case :hackney.post(url, headers, body, opts) do
      {:ok, status, _headers, resp_body} when status in 200..299 ->
        case Jason.decode(resp_body) do
          {:ok, %{"idToken" => id} = map} ->
            {:ok, id, parse_expires_in(map)}

          {:ok, %{"error" => err}} ->
            Logger.warning("[Segfy Auth] Firebase verifyPassword error: #{inspect(err)}")
            {:error, {:firebase, err}}

          {:ok, other} ->
            Logger.warning(
              "[Segfy Auth] Firebase response without idToken: #{inspect(Map.keys(other))}"
            )

            {:error, :firebase_no_id_token}

          {:error, _} ->
            {:error, {:invalid_json, resp_body}}
        end

      {:ok, status, _, resp_body} ->
        Logger.warning("[Segfy Auth] Firebase HTTP #{status}: #{truncate(resp_body)}")
        {:error, {:http, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # HAR renovacao.har: após SSO o app chama POST upfygate …/auth/login com {"email":"","password":""}
  # (Origin app.segfy.com). Sem isso, cookie do gate fica incompleto e Gestão/HTML pode redirecionar a logoff.
  defp upfy_gate_auth_login_merge_cookies(cookie) when is_binary(cookie) and cookie != "" do
    base = Ersventaja.Segfy.upfy_gate_base_url() |> String.trim_trailing("/")
    url = base <> "/auth/login"
    body = Jason.encode!(%{"email" => "", "password" => ""})
    o = Ersventaja.Segfy.gate_request_origin() |> String.trim() |> String.trim_trailing("/")

    headers = [
      {"Content-Type", "application/json;charset=UTF-8"},
      {"Cookie", cookie},
      {"Origin", o},
      {"Referer", o <> "/"}
    ]

    opts = [:with_body, recv_timeout: @recv_timeout, connect_timeout: @connect_timeout]

    case :hackney.post(url, headers, body, opts) do
      {:ok, status, resp_headers, resp_body} when status in 200..299 ->
        extra = parse_set_cookies(resp_headers)

        cookie1 =
          if extra != "" do
            merge_cookie_header_strings(cookie, extra)
          else
            cookie
          end

        merge_vuex_cookie_from_auth_login_body(cookie1, resp_body)

      {:ok, status, _, resp_body} ->
        Logger.warning(
          "[Segfy Auth] upfygate /auth/login HTTP #{status}: #{truncate(to_string(resp_body))} — usando só cookie SSO"
        )

        cookie

      {:error, reason} ->
        Logger.warning(
          "[Segfy Auth] upfygate /auth/login falhou: #{inspect(reason)} — usando só cookie SSO"
        )

        cookie
    end
  end

  defp upfy_gate_auth_login_merge_cookies(cookie), do: cookie

  defp merge_vuex_cookie_from_auth_login_body(cookie, resp_body) when is_binary(cookie) do
    case Jason.decode(resp_body) do
      {:ok, %{"data" => %{} = data}} ->
        if is_binary(data["token"]) and data["token"] != "" do
          try do
            vuex_json = Ersventaja.Segfy.VuexCookie.build_from_gate_login_data(data)
            # Evita que `;` no JSON quebre o split em merge_cookie_header_strings/2
            enc = String.replace(vuex_json, ";", "%3B")
            merge_cookie_header_strings(cookie, "vuex=" <> enc)
          rescue
            _ -> cookie
          end
        else
          cookie
        end

      _ ->
        cookie
    end
  end

  defp merge_vuex_cookie_from_auth_login_body(cookie, _), do: cookie

  defp merge_cookie_header_strings(existing, addition)
       when is_binary(existing) and is_binary(addition) do
    m = Map.merge(cookie_header_to_map(existing), cookie_header_to_map(addition))
    map_to_cookie_header(m)
  end

  defp cookie_header_to_map(s) when is_binary(s) do
    s
    |> String.split(";")
    |> Enum.reduce(%{}, fn part, acc ->
      part = String.trim(part)

      case String.split(part, "=", parts: 2) do
        [k, v] when k != "" -> Map.put(acc, String.trim(k), String.trim(v))
        _ -> acc
      end
    end)
  end

  defp map_to_cookie_header(map) when map == %{}, do: ""

  defp map_to_cookie_header(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("; ", fn {k, v} -> k <> "=" <> v end)
  end

  defp segfy_sso_login(id_token) do
    body = Jason.encode!(%{"idToken" => id_token})
    headers = [{"Content-Type", "application/json"}]

    opts = [
      :with_body,
      recv_timeout: @recv_timeout,
      connect_timeout: @connect_timeout,
      follow_redirect: true
    ]

    case :hackney.post(@sso_login_url, headers, body, opts) do
      {:ok, status, resp_headers, resp_body} when status in 200..299 ->
        cookie = parse_set_cookies(resp_headers)

        atoken =
          parse_automation_token_from_sso_body(resp_body) ||
            segfy_session_token_from_set_cookie_headers(resp_headers)

        if cookie != "" do
          {:ok, cookie, atoken}
        else
          Logger.warning(
            "[Segfy Auth] SSO login OK mas sem Set-Cookie; body: #{truncate(to_string(resp_body))}"
          )

          {:error, :sso_no_set_cookie}
        end

      {:ok, status, _, resp_body} ->
        Logger.warning("[Segfy Auth] SSO HTTP #{status}: #{truncate(resp_body)}")
        {:error, {:http, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_automation_token_from_sso_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> find_automation_token_in_map(map, 0)
      _ -> nil
    end
  end

  defp parse_automation_token_from_sso_body(_), do: nil

  @token_keys ~w(token automationToken automation_token tokenAutomacao TokenAutomacao token_automacao brokerToken)

  defp find_automation_token_in_map(_map, depth) when depth > 8, do: nil

  defp find_automation_token_in_map(map, depth) when is_map(map) do
    Enum.find_value(@token_keys, fn k ->
      case Map.get(map, k) do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end) ||
      Enum.find_value(map, fn
        {_k, v} when is_map(v) -> find_automation_token_in_map(v, depth + 1)
        {_k, v} when is_list(v) -> Enum.find_value(v, &find_in_list/1)
        _ -> nil
      end)
  end

  defp find_automation_token_in_map(_, _), do: nil

  defp find_in_list(list) when is_list(list) do
    Enum.find_value(list, fn
      v when is_map(v) -> find_automation_token_in_map(v, 0)
      _ -> nil
    end)
  end

  defp find_in_list(_), do: nil

  # JWT enviado no Set-Cookie: segfy_sessiontoken=eyJ... (usado como config.token na API automation)
  defp segfy_session_token_from_set_cookie_headers(headers) when is_list(headers) do
    headers
    |> Enum.filter(fn {k, _} -> String.downcase(to_string(k)) == "set-cookie" end)
    |> Enum.map(fn {_, v} -> v end)
    |> Enum.find_value(&parse_segfy_session_token_pair/1)
  end

  defp segfy_session_token_from_set_cookie_headers(_), do: nil

  defp parse_segfy_session_token_pair(header) when is_binary(header) do
    header
    |> String.split(";")
    |> List.first()
    |> case do
      nil ->
        nil

      pair ->
        case String.split(String.trim(pair), "=", parts: 2) do
          [name, value]
          when is_binary(name) and is_binary(value) and value != "" ->
            if String.downcase(String.trim(name)) == "segfy_sessiontoken" do
              String.trim(value)
            else
              nil
            end

          _ ->
            nil
        end
    end
  end

  defp parse_segfy_session_token_pair(_), do: nil

  defp parse_set_cookies(headers) when is_list(headers) do
    headers
    |> Enum.filter(fn {k, _} ->
      String.downcase(to_string(k)) == "set-cookie"
    end)
    |> Enum.map(fn {_, v} -> cookie_name_value(v) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join("; ")
  end

  defp parse_set_cookies(_), do: ""

  defp cookie_name_value(set_cookie) when is_binary(set_cookie) do
    set_cookie
    |> String.split(";")
    |> List.first()
    |> case do
      nil -> nil
      pair -> String.trim(pair)
    end
  end

  defp cookie_name_value(_), do: nil

  defp truncate(s) when is_binary(s) and byte_size(s) > 400, do: binary_part(s, 0, 400) <> "..."
  defp truncate(s), do: to_string(s)

  defp parse_expires_in(%{"expiresIn" => n}) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 3600
    end
  end

  defp parse_expires_in(%{"expiresIn" => n}) when is_integer(n), do: n
  defp parse_expires_in(_), do: 3600

  @doc """
  Tenta obter o id numérico do usuário a partir do JWT `segfy_sessiontoken` em cache.

  O `POST /bgt/api/budget/list` costuma mandar `usuarioId` do corretor; `0` pode fazer a lista vir
  vazia mesmo com `qtdeRenovacaoNaoInciada` > 0 no agregado.
  """
  def budget_usuario_id_from_session do
    with {:ok, jwt} <- peek_automation_token_cached(),
         {:ok, %{} = claims} <- jwt_payload_map(jwt) do
      pick_usuario_id_from_claims(claims)
    else
      _ -> nil
    end
  end

  defp pick_usuario_id_from_claims(claims) do
    keys = [
      "usuarioId",
      "UsuarioId",
      "idUsuario",
      "IdUsuario",
      "userId",
      "UserId",
      "user_id",
      "brokerUsuarioId",
      "BrokerUsuarioId",
      "nameid",
      "sub"
    ]

    Enum.find_value(keys, fn k ->
      case Map.get(claims, k) do
        n when is_integer(n) and n > 0 ->
          n

        s when is_binary(s) ->
          t = String.trim(s)

          # UUID ou texto com prefixo numérico: Integer.parse("633e72f2-...") daria 633 — inválido
          case Integer.parse(t) do
            {i, ""} when i > 0 -> i
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp jwt_payload_map(jwt) when is_binary(jwt) do
    parts = String.split(jwt, ".")

    if length(parts) != 3 do
      {:error, :not_jwt}
    else
      payload = Enum.at(parts, 1)

      case Base.url_decode64(payload, padding: true) do
        {:ok, bin} ->
          case Jason.decode(bin) do
            {:ok, %{} = m} -> {:ok, m}
            _ -> {:error, :invalid_claims_json}
          end

        :error ->
          {:error, :invalid_jwt_payload}
      end
    end
  end

  defp jwt_payload_map(_), do: {:error, :not_jwt}
end
