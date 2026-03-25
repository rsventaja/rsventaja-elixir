defmodule Ersventaja.Segfy.Client do
  @moduledoc false
  require Logger

  alias Ersventaja.Segfy.Cookies

  @recv_timeout 120_000
  @connect_timeout 15_000

  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

  def user_agent, do: @user_agent

  @doc """
  POST JSON para a API de automação Segfy.

  `path` deve começar com `/` (ex: `/api/vehicle/version/1.0/calculate`).

  Alinhado ao `scripts/segfy_chain_probe.py`: token **opaco** de `list-by-intranet` em `config.token`;
  header `Authorization: Bearer` = JWT **HS256** de `POST /auths/token` (via `AutomationToken.ensure/0` quando o SSO
  não serve). `resolved_automation_token/0` **não** devolve o JWT de client credentials — só opaco ou override env.
  """
  def post_automation(path, body) when is_binary(path) and is_map(body) do
    case resolve_automation_token(body) do
      {:ok, token} ->
        url = Ersventaja.Segfy.automation_base_url() <> path
        extra = automation_headers(token)

        case do_post_json(url, body, extra) do
          {:error, {:http, 401, _}} = e ->
            maybe_retry_automation_401(path, body, e)

          other ->
            other
        end

      {:error, _} = err ->
        err
    end
  end

  # Refetch do token opaco (list-by-intranet). Não usar idToken Firebase no Bearer — api.automation
  # valida algoritmo do JWT no header e responde 422 ("Expected a different algorithm").
  defp maybe_retry_automation_401(path, body, err) do
    fixed_env = Ersventaja.Segfy.automation_token()

    if is_binary(fixed_env) and fixed_env != "" do
      err
    else
      case Ersventaja.Segfy.resolved_intranet_id() do
        {:ok, _} ->
          Logger.debug(
            "[Segfy] api.automation 401 — refresh token profile (list-by-intranet) e nova tentativa"
          )

          Ersventaja.Segfy.AutomationProfile.clear_cache()
          _ = Ersventaja.Segfy.Auth.gate_cookie()

          case Ersventaja.Segfy.AutomationProfile.ensure() do
            {:ok, new_token} ->
              body2 = put_config_token(body, new_token)
              url = Ersventaja.Segfy.automation_base_url() <> path
              extra = automation_headers(new_token)

              case do_post_json(url, body2, extra) do
                {:ok, _} = ok ->
                  ok

                {:error, {:http, 401, _}} = e2 ->
                  Logger.warning(
                    "[Segfy] api.automation 401 após novo token de profile — teste " <>
                      "SEGFY_AUTOMATION_ORIGIN=https://gestao.segfy.com ou " <>
                      "SEGFY_AUTOMATION_PROFILE_NAME; o UUID da cotação pode ser de outro perfil/corretora"
                  )

                  e2

                other ->
                  other
              end

            _ ->
              Logger.warning(
                "[Segfy] retry após 401 falhou; confira SEGFY_INTRANET_ID / SEGFY_AUTOMATION_PROFILE_NAME"
              )

              err
          end

        _ ->
          Logger.warning(
            "[Segfy] api.automation 401 sem intranet_id — defina SEGFY_INTRANET_ID (ex.: valor do HAR em list-by-intranet)"
          )

          err
      end
    end
  end

  defp automation_headers(token) when is_binary(token) do
    automation_authorization_headers(token) ++ automation_origin_headers()
  end

  defp automation_origin_headers do
    o = Ersventaja.Segfy.automation_request_origin() |> String.trim_trailing("/")

    if o != "" do
      [{"Origin", o}, {"Referer", o <> "/"}]
    else
      []
    end
  end

  defp put_config_token(body, token) when is_map(body) and is_binary(token) do
    cond do
      Map.has_key?(body, :config) ->
        cfg = Map.get(body, :config) || %{}
        Map.put(body, :config, Map.put(cfg, :token, token))

      Map.has_key?(body, "config") ->
        cfg = Map.get(body, "config") || %{}
        Map.put(body, "config", Map.put(cfg, "token", token))

      true ->
        Map.put(body, :config, %{token: token})
    end
  end

  defp automation_authorization_headers(body_token) when is_binary(body_token) do
    case bearer_for_automation_request(body_token) do
      jwt when is_binary(jwt) and jwt != "" ->
        [{"Authorization", "Bearer " <> jwt}]

      _ ->
        []
    end
  end

  # Opaco no body → Bearer: SSO se for JWT “Segfy” (ex. HS256); senão JWT de /auths/token (AutomationToken).
  # JWT no body (ex. resposta de /auths/token) → mesmo valor no header.
  defp bearer_for_automation_request(body_token) when is_binary(body_token) do
    cond do
      opaque_profile_token?(body_token) ->
        sso_jwt =
          case Ersventaja.Segfy.Auth.peek_automation_token_cached() do
            {:ok, jwt} when is_binary(jwt) and jwt != "" ->
              if segfy_bearer_jwt?(jwt), do: jwt, else: nil

            _ ->
              nil
          end

        cond do
          is_binary(sso_jwt) and sso_jwt != "" ->
            sso_jwt

          true ->
            case Ersventaja.Segfy.AutomationToken.ensure() do
              {:ok, jwt} when is_binary(jwt) and jwt != "" -> jwt
              _ -> nil
            end
        end

      segfy_bearer_jwt?(body_token) ->
        body_token

      true ->
        nil
    end
  end

  defp segfy_bearer_jwt?(t) when is_binary(t) do
    cond do
      opaque_profile_token?(t) -> false
      length(String.split(t, ".")) != 3 -> false
      jwt_header_alg(t) == {:ok, "RS256"} -> false
      match?({:ok, _}, jwt_payload_top_level_size(t)) -> true
      true -> false
    end
  end

  defp jwt_header_alg(token) when is_binary(token) do
    parts = String.split(token, ".")

    if length(parts) != 3 do
      :error
    else
      header = Enum.at(parts, 0)

      case Base.url_decode64(header, padding: true) do
        {:ok, bin} ->
          case Jason.decode(bin) do
            {:ok, %{"alg" => alg}} when is_binary(alg) -> {:ok, alg}
            _ -> :error
          end

        :error ->
          :error
      end
    end
  end

  defp opaque_profile_token?(t) when is_binary(t) do
    String.match?(t, ~r/^[a-fA-F0-9]{32}$/)
  end

  defp jwt_payload_top_level_size(token) when is_binary(token) do
    parts = String.split(token, ".")

    if length(parts) != 3 do
      :not_jwt
    else
      payload = Enum.at(parts, 1)

      case Base.url_decode64(payload, padding: true) do
        {:ok, bin} ->
          case Jason.decode(bin) do
            {:ok, %{} = m} -> {:ok, map_size(m)}
            _ -> :error
          end

        :error ->
          :error
      end
    end
  end

  defp resolve_automation_token(body) do
    env = Ersventaja.Segfy.automation_token()
    cfg = Map.get(body, :config) || Map.get(body, "config") || %{}
    from_body = Map.get(cfg, :token) || Map.get(cfg, "token")
    resolved = Ersventaja.Segfy.resolved_automation_token()

    cond do
      is_binary(from_body) and from_body != "" -> {:ok, from_body}
      is_binary(env) and env != "" -> {:ok, env}
      is_binary(resolved) and resolved != "" -> {:ok, resolved}
      true -> {:error, :missing_automation_token}
    end
  end

  @doc """
  POST JSON para o domínio gestão (orçamentos). Não exige o token de automação no header;
  o token costuma ir na query string (ver `Ersventaja.Segfy.Gestao`).

  Sem `cookie`: requisição anônima (pode falhar em `SalvaCotacaoAutomation` sem sessão ASP.NET).
  """
  def post_gestao(path, body, opts \\ [])

  def post_gestao(path, body, opts) when is_binary(path) and is_map(body) and is_list(opts) do
    url = Ersventaja.Segfy.gestao_base_url() <> path
    cookie = Keyword.get(opts, :cookie)
    referer = Keyword.get(opts, :referer)
    origin = Keyword.get(opts, :origin)
    more = Keyword.get(opts, :extra_headers, [])

    extra =
      [
        {"User-Agent", @user_agent},
        {"Accept", "application/json, text/plain, */*"}
      ]
      |> then(fn h ->
        if is_binary(cookie) and cookie != "", do: [{"Cookie", cookie} | h], else: h
      end)
      |> then(fn h ->
        if is_binary(referer) and referer != "", do: [{"Referer", referer} | h], else: h
      end)
      |> then(fn h ->
        if is_binary(origin) and origin != "", do: [{"Origin", origin} | h], else: h
      end)
      |> Kernel.++(more)

    do_post_json(url, body, extra)
  end

  @doc """
  GET no domínio gestão (HTML) com Cookie de sessão (mesmo jar que Firebase+SSO+vuex).

  `opts` repassa para `get_url/4` (ex.: `[follow_redirect: false]`).
  """
  def get_gestao(path, cookie, extra_headers \\ [], opts \\ [])
      when is_binary(path) and is_binary(cookie) and is_list(extra_headers) and is_list(opts) do
    url = Ersventaja.Segfy.gestao_base_url() <> path
    get_url(url, cookie, extra_headers, opts)
  end

  @doc """
  GET em URL absoluta (ex.: `https://app.segfy.com/`) para aquecer cookies SameSite / iframe.

  Opções: `follow_redirect: false` evita loop 302 (ex.: `/Home` ↔ `/Autenticacao` no gestão) e
  `max_redirect_overflow` no Hackney — um único 302 já pode gravar `ASP.NET_SessionId`.
  """
  def get_url(url, cookie, extra_headers \\ [], opts \\ [])
      when is_binary(url) and is_binary(cookie) and is_list(extra_headers) and is_list(opts) do
    follow = Keyword.get(opts, :follow_redirect, true)

    headers =
      [
        {"Cookie", cookie},
        {"User-Agent", @user_agent},
        {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
        {"Accept-Language", "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7"}
        | extra_headers
      ]

    hackney_opts = [
      :with_body,
      recv_timeout: @recv_timeout,
      connect_timeout: @connect_timeout,
      follow_redirect: follow
    ]

    case :hackney.get(url, headers, [], hackney_opts) do
      {:ok, status, _rh, body} when status in 200..399 ->
        {:ok, status, IO.iodata_to_binary(body)}

      {:ok, status, _rh, body} ->
        {:error, {:http, status, IO.iodata_to_binary(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Como `get_url/4`, mas devolve `{:ok, cookie_merged, status, body}` aplicando `Set-Cookie` da resposta
  ao cookie enviado (para encadear vários GETs no warm / gestão).
  """
  def get_url_and_merge_cookies(url, cookie, extra_headers \\ [], opts \\ [])
      when is_binary(url) and is_binary(cookie) and is_list(extra_headers) and is_list(opts) do
    follow = Keyword.get(opts, :follow_redirect, true)

    headers =
      [
        {"Cookie", cookie},
        {"User-Agent", @user_agent},
        {"Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
        {"Accept-Language", "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7"}
        | extra_headers
      ]

    hackney_opts = [
      :with_body,
      recv_timeout: @recv_timeout,
      connect_timeout: @connect_timeout,
      follow_redirect: follow
    ]

    case :hackney.get(url, headers, [], hackney_opts) do
      {:ok, status, rh, body} when status in 200..399 ->
        merged = Cookies.merge_set_cookies_into_header(cookie, rh)
        {:ok, merged, status, IO.iodata_to_binary(body)}

      {:ok, status, _rh, body} ->
        {:error, {:http, status, IO.iodata_to_binary(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  POST `application/x-www-form-urlencoded` (ASP.NET UpdatePanel / Prosseguir).
  `post_url` pode ser absoluto (retorno do `<form action>`).
  """
  def post_gestao_form(post_url, cookie, pairs, extra_headers \\ [])
      when is_binary(post_url) and is_binary(cookie) and is_list(pairs) do
    body =
      pairs
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> URI.encode_query()

    headers =
      [
        {"Content-Type", "application/x-www-form-urlencoded; charset=UTF-8"},
        {"Cookie", cookie},
        {"User-Agent", @user_agent},
        {"Accept", "*/*"},
        {"Accept-Language", "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7"},
        {"Cache-Control", "no-cache"},
        {"X-MicrosoftAjax", "Delta=true"},
        {"X-Requested-With", "XMLHttpRequest"}
        | extra_headers
      ]

    opts = [
      :with_body,
      recv_timeout: @recv_timeout,
      connect_timeout: @connect_timeout,
      follow_redirect: false
    ]

    case :hackney.post(post_url, headers, body, opts) do
      {:ok, status, _rh, resp_body} when status in 200..299 ->
        {:ok, status, IO.iodata_to_binary(resp_body)}

      {:ok, status, _rh, resp_body} ->
        {:error, {:http, status, IO.iodata_to_binary(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @max_warm_redirects 12

  @doc """
  GET that follows redirects manually, accumulating `Set-Cookie` at each hop (browser behaviour).

  Returns `{:ok, cookie, status, body}` or `{:error, reason}`.
  Needed for ASP.NET `/Home` → `/Autenticacao` → `/Home` chain that establishes the session.
  """
  def get_follow_redirects(url, cookie, extra_headers \\ [])
      when is_binary(url) and is_binary(cookie) and is_list(extra_headers) do
    do_follow(url, cookie, extra_headers, 0)
  end

  defp do_follow(url, cookie, extra_headers, depth) do
    if depth > @max_warm_redirects do
      {:error, :redirect_limit}
    else
      headers =
        [
          {"Cookie", cookie},
          {"User-Agent", @user_agent},
          {"Accept",
           "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"},
          {"Accept-Language", "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7"}
          | extra_headers
        ]

      opts = [
        :with_body,
        recv_timeout: @recv_timeout,
        connect_timeout: @connect_timeout,
        follow_redirect: false
      ]

      case :hackney.get(url, headers, [], opts) do
        {:ok, status, rh, body} when status in [301, 302, 303, 307, 308] ->
          cookie = Cookies.merge_set_cookies_into_header(cookie, rh)

          case find_location_header(rh) do
            loc when is_binary(loc) and loc != "" ->
              next = resolve_redirect(url, loc)
              do_follow(next, cookie, extra_headers, depth + 1)

            _ ->
              {:ok, cookie, status, IO.iodata_to_binary(body)}
          end

        {:ok, status, rh, body} when status in 200..299 ->
          cookie = Cookies.merge_set_cookies_into_header(cookie, rh)
          {:ok, cookie, status, IO.iodata_to_binary(body)}

        {:ok, status, _rh, body} ->
          {:error, {:http, status, IO.iodata_to_binary(body)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp find_location_header(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} -> if String.downcase(to_string(k)) == "location", do: v, else: nil
      _ -> nil
    end)
  end

  defp resolve_redirect(current_url, location) do
    location = String.trim(location)

    case URI.parse(location) do
      %URI{scheme: s} when s in ["http", "https"] ->
        location

      _ ->
        base = URI.parse(current_url)

        if base.scheme && base.host do
          URI.merge(base, URI.parse(location)) |> URI.to_string()
        else
          location
        end
    end
  end

  defp do_post_json(url, body, extra_headers) do
    headers = [{"Content-Type", "application/json; charset=utf-8"} | extra_headers]
    json = Jason.encode!(body)

    opts = [
      :with_body,
      recv_timeout: @recv_timeout,
      connect_timeout: @connect_timeout
    ]

    case :hackney.post(url, headers, json, opts) do
      {:ok, status, _headers, resp_body} when status in 200..299 ->
        decode_json(resp_body)

      {:ok, status, _headers, resp_body} ->
        if status == 401 do
          Logger.debug("[Segfy] HTTP #{status} #{url}: #{truncate(resp_body)}")
        else
          Logger.warning("[Segfy] HTTP #{status} #{url}: #{truncate(resp_body)}")
        end

        {:error, {:http, status, resp_body}}

      {:error, reason} ->
        Logger.warning("[Segfy] request failed #{url}: #{inspect(reason)}")
        {:error, reason}
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
