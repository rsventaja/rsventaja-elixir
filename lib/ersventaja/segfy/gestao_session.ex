defmodule Ersventaja.Segfy.GestaoSession do
  @moduledoc false
  # Aquecimento de sessão ASP.NET + iframe (scripts/segfy_chain_probe.py `_warm_session_for_gestao`).

  require Logger

  alias Ersventaja.Segfy.Client

  @doc """
  GET app.segfy.com + multicalculo renovação + `/Home` no gestão para alinhar cookies ao fluxo browser.

  Devolve o **cookie acumulado** (mescla `Set-Cookie` de cada resposta), como o browser faria.

  O GET `/Home` segue redirects manualmente (302 → `/Autenticacao` → 302 `/Home`) para estabelecer
  a sessão ASP.NET no gestão legado — equivalente ao `_warm_session_for_gestao` no probe Python.
  """
  def warm(cookie) when is_binary(cookie) do
    go = Ersventaja.Segfy.gate_request_origin() |> String.trim_trailing("/")
    gb = Ersventaja.Segfy.gestao_base_url() |> String.trim_trailing("/")

    warm_opts = [follow_redirect: false]

    with {:ok, c1, _, _} <-
           Client.get_url_and_merge_cookies(
             go <> "/",
             cookie,
             [{"Referer", go <> "/"}],
             warm_opts
           ),
         {:ok, c2, _, _} <-
           Client.get_url_and_merge_cookies(
             go <> "/multicalculo/orcamento-renovacao?q=0",
             c1,
             [
               {"Referer", go <> "/"},
               {"Sec-Fetch-Site", "same-origin"}
             ],
             warm_opts
           ),
         {:ok, c3, st, html} <-
           Client.get_follow_redirects(
             gb <> "/Home",
             c2,
             [
               {"Referer", go <> "/"},
               {"Sec-Fetch-Dest", "iframe"},
               {"Sec-Fetch-Site", "same-site"}
             ]
           ) do
      html = html || ""
      down = String.downcase(html)

      if st == 200 and String.contains?(down, "login segfy") do
        Logger.warning(
          "[Segfy GestaoSession] warm GET /Home devolveu 200 com tela de login — sessão ASP.NET/vuex pode estar incompleta"
        )
      end

      if st == 200 and String.contains?(down, "logoff") do
        Logger.warning(
          "[Segfy GestaoSession] warm GET /Home ainda sugere logoff — confira cookie vuex após auth/login"
        )
      end

      c3
    else
      {:error, reason} ->
        Logger.warning("[Segfy GestaoSession] warm: #{inspect(reason)}")
        cookie
    end
  end
end
