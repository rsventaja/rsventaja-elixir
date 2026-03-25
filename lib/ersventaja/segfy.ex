defmodule Ersventaja.Segfy do
  require Logger

  @moduledoc """
  Integração com a API de automação Segfy (multicálculo veículo).

  **Referência:** o fluxo deve seguir `scripts/segfy_chain_probe.py` (HAR / browser): ordem de credenciais,
  token opaco vs JWT Bearer, Gate, Gestão e `SalvaCotacaoAutomation`.

  Configuração via `config :ersventaja, :segfy` (variáveis em `runtime.exs`):

  - `:automation_base_url` — padrão `https://api.automation.segfy.com`
  - `:gestao_base_url` — padrão `https://gestao.segfy.com`
  - `:automation_token` — opcional; token **opaco** fixo (`SEGFY_AUTOMATION_TOKEN`), mesmo papel do `profiles[].token`
    do probe (não use aqui o JWT de `/auths/token`).
  - Sem token fixo: o **token opaco** em `config.token` (calculate/show) e na query de `SalvaCotacaoAutomation` vem do
    Upfy Gate `POST …/list-by-intranet` + `SEGFY_INTRANET_ID` (`AutomationProfile`). **Não** misturar com o JWT de client credentials.
  - **Bearer** no header da `api.automation`: só o JWT HS256 de `POST …/auths/token` (bundle + Basic) ou SSO aceito —
    resolvido em `Client` (`AutomationToken.ensure/0`), igual ao probe após o token opaco estar definido.
  - Fallback último para `resolved_automation_token/0`: JWT SSO (`segfy_sessiontoken`) — o probe não usa isso como
    `config.token`; prefira `SEGFY_INTRANET_ID` + perfil.
  - `SEGFY_AUTOMATION_PROFILE_NAME` — opcional; qual entrada de `profiles[]` usar (match exato no `name`).
  - `SEGFY_AUTOMATION_ORIGIN` — opcional; `Origin`/`Referer` nas chamadas à api.automation (padrão `https://app.segfy.com`; no HAR às vezes `https://gestao.segfy.com`).
  - `SEGFY_SKIP_GESTAO_HTML_LIST` — padrão `1`: não chama `GET …/OrcamentosRenovacao` (HTML legado costuma 302); usa direto `POST …/budget/list` no Gate. `0` para tentar o HTML antes.
  - `:upfy_gate_base_url` — API do gate (listagem de orçamentos), padrão `https://upfygate.segfy.com`
  - `SEGFY_GATE_ORIGIN` — `Referer` ao GET `gestao.segfy.com//OrcamentosRenovacao` (iframe do app), padrão `https://app.segfy.com`
  - `:firebase_web_api_key`, `:login_email`, `:login_password` — **único** fluxo do gate: Firebase + SSO (`SEGFY_FIREBASE_WEB_API_KEY`, `SEGFY_LOGIN_EMAIL`, `SEGFY_LOGIN_PASSWORD`)

  Módulos:

  - `Ersventaja.Segfy.Vehicle` — `show`, `calculate`, listas auxiliares
  - `Ersventaja.Segfy.Gestao` — persistir cotação (`SalvaCotacaoAutomation`)
  - `Ersventaja.Segfy.AutoPolicyExtractor` — texto do PDF (via `OCR.extract_text_from_pdf/1`) → **só** LLM; campos estruturados não vêm de heurística no OCR
  - `Ersventaja.Segfy.Budget` — listar orçamentos no gate (match cliente/vigência)
  - `Ersventaja.Segfy.GestaoRenewal` — lista de renovações no gestão legado (HTML), alinhado ao HAR
  - `Ersventaja.Segfy.Renewal` — Gestão HTML (e fallback Gate) → casar → quotation_id → show → calculate (fluxo legado)
  - `Ersventaja.Segfy.Quotation` — vuex + Prosseguir → `cod` → calculate **RENOVATION** + **NEW_QUOTATION** → SalvaCotacaoAutomation + link `app.segfy.com/.../hfy-auto?q=`
  - `Ersventaja.Segfy.GestaoProsseguir` — POST ASP.NET Prosseguir (UpdatePanel)
  - `Ersventaja.Segfy.GestaoSession` — aquecimento de sessão Gestão
  - `Ersventaja.Segfy.Auth` — Firebase `verifyPassword` + `api.sso.segfy.com/login` (cookie do gate)
  - `Ersventaja.Segfy.AutomationBundle` — GET `auto-bundle.js` → par para Basic em `/auths/token`
  """

  @doc false
  def config do
    Application.get_env(:ersventaja, :segfy, [])
  end

  @doc "Retorna true se SEGFY_ENABLED=true/1/yes."
  def enabled? do
    Keyword.get(config(), :enabled, false) == true
  end

  @doc false
  def automation_token do
    Keyword.get(config(), :automation_token)
  end

  @doc """
  Token colocado em `config.token` no JSON da api.automation e na query `token` de `SalvaCotacaoAutomation`.

  Ordem **igual ao probe** (`segfy_chain_probe.py`): override env → `list-by-intranet` (opaco) → fallback SSO.
  O JWT de `/auths/token` **não** entra aqui — só no header `Authorization` via `Client` / `AutomationToken`.
  """
  def resolved_automation_token do
    case automation_token() do
      t when is_binary(t) and t != "" ->
        t

      _ ->
        case Ersventaja.Segfy.AutomationProfile.ensure() do
          {:ok, t} when is_binary(t) and t != "" ->
            t

          :not_configured ->
            Logger.warning(
              "[Segfy] automation_profile: intranet_id ausente ou inválido — defina SEGFY_INTRANET_ID " <>
                "(probe: token opaco vem de list-by-intranet, não do JWT de /auths/token)"
            )

            sso_token_after_gate_login()

          {:error, reason} ->
            Logger.warning(
              "[Segfy] automation_profile falhou (#{inspect(reason)}); fallback SSO (probe: corrigir gate/list-by-intranet)"
            )

            sso_token_after_gate_login()
        end
    end
  end

  defp sso_token_after_gate_login do
    case Ersventaja.Segfy.Auth.peek_automation_token_cached() do
      {:ok, t} ->
        t

      _ ->
        case Ersventaja.Segfy.Auth.gate_cookie() do
          {:ok, _} ->
            case Ersventaja.Segfy.Auth.peek_automation_token_cached() do
              {:ok, t} -> t
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  @doc false
  def intranet_id_env do
    Keyword.get(config(), :intranet_id)
  end

  @doc false
  def automation_profile_name do
    Keyword.get(config(), :automation_profile_name)
  end

  @doc false
  def automation_request_origin do
    Keyword.get(config(), :automation_request_origin, "https://app.segfy.com")
  end

  @doc false
  def skip_gestao_html_list? do
    Keyword.get(config(), :skip_gestao_html_list, true)
  end

  @doc false
  def gate_request_origin do
    Keyword.get(config(), :gate_request_origin, "https://app.segfy.com")
    |> to_string()
    |> String.trim()
    |> String.trim_trailing("/")
  end

  @doc """
  Comissão padrão no `POST …/calculate`:

  - `data.commission_all` — **inteiro JSON** `25` (HAR `novo.har` após “Todas → 25”; string `"25"` não bate e a UI pode ignorar)
  - `config.insurers[].commission` — inteiro (igual)

  HARs antigos às vezes trazem `"20"` como string; preferimos inteiro alinhado ao browser.
  """
  def calculate_default_commission_percent, do: 25

  @doc false
  def calculate_default_commission_all_integer, do: calculate_default_commission_percent()

  @doc false
  def calculate_default_commission_all_string do
    calculate_default_commission_percent() |> Integer.to_string()
  end

  @doc false
  def resolved_intranet_id do
    case parse_intranet_env(intranet_id_env()) do
      {:ok, n} ->
        {:ok, n}

      :none ->
        case Ersventaja.Segfy.Auth.intranet_id_from_sso_jwt() do
          {:ok, n} -> {:ok, n}
          _ -> :error
        end
    end
  end

  defp parse_intranet_env(nil), do: :none
  defp parse_intranet_env(""), do: :none

  defp parse_intranet_env(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {i, ""} when i > 0 -> {:ok, i}
      _ -> :none
    end
  end

  defp parse_intranet_env(_), do: :none

  @doc false
  def automation_client_id do
    Keyword.get(config(), :automation_client_id)
  end

  @doc false
  def automation_client_secret do
    Keyword.get(config(), :automation_client_secret)
  end

  @doc false
  def auto_bundle_js_url do
    Keyword.get(
      config(),
      :auto_bundle_js_url,
      "https://bundles.segfy.com/auto-bundle.js"
    )
  end

  @doc false
  def automation_base_url do
    Keyword.get(config(), :automation_base_url, "https://api.automation.segfy.com")
  end

  @doc false
  def gestao_base_url do
    Keyword.get(config(), :gestao_base_url, "https://gestao.segfy.com")
  end

  @doc false
  def upfy_gate_base_url do
    Keyword.get(config(), :upfy_gate_base_url, "https://upfygate.segfy.com")
  end

  @doc false
  def firebase_web_api_key do
    Keyword.get(config(), :firebase_web_api_key)
  end

  @doc false
  def login_email do
    Keyword.get(config(), :login_email)
  end

  @doc false
  def login_password do
    Keyword.get(config(), :login_password)
  end

  @doc false
  def firebase_login_configured? do
    k = firebase_web_api_key()
    e = login_email()
    p = login_password()
    is_binary(k) and k != "" and is_binary(e) and e != "" and is_binary(p) and p != ""
  end

  @doc false
  def upfy_gate_configured? do
    firebase_login_configured?()
  end

  @doc false
  def multicalculo_socket_enabled? do
    Keyword.get(config(), :multicalculo_socket_enabled, true) == true
  end

  @doc false
  def socket_io_websocket_url do
    Keyword.get(
      config(),
      :socket_io_websocket_url,
      "wss://socket-io.segfy.com/socket.io/?EIO=4&transport=websocket"
    )
  end

  @doc false
  def socket_io_origin do
    case Keyword.get(config(), :socket_io_origin) do
      o when is_binary(o) and o != "" -> o
      _ -> gestao_base_url()
    end
  end
end
