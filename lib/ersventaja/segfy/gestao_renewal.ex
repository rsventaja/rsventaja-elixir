defmodule Ersventaja.Segfy.GestaoRenewal do
  @moduledoc false

  # Fluxo observado (ex.: inicia_renovacao.har):
  # - App: app.segfy.com/multicalculo/orcamento-renovacao?q=0 — q=0 = funil "renovações não iniciadas".
  # - Iframe legado: GET …/OrcamentosRenovacao?novoOrcamento=true&cod=0 — cod=0 é o mesmo estágio.
  # O POST upfygate …/bgt/api/budget/list nem sempre aparece no HAR (lista pode vir só do HTML ou XHR no iframe).

  require Logger

  @recv_timeout 90_000
  @connect_timeout 15_000

  # Mesmo URL que o iframe do app (HAR / DevTools): host + // + path
  @list_query "//OrcamentosRenovacao?novoOrcamento=true&cod=0"

  @doc """
  Baixa a página de renovações no **gestão legado** e extrai linhas da tabela.

  Cada item tem chaves compatíveis com `Ersventaja.Segfy.Budget.find_matching_item/2`:
  `nomeCliente`, `dataFim` (dd/mm/aaaa), `numeroApolice`, `origem` → `"gestao_html"`.

  O `quotation_id` (UUID) **não** vem dessa tela — use `Budget.list_page/1` com `search`
  pelo número da apólice depois do match (`Ersventaja.Segfy.Renewal`).
  """
  def list_table_rows do
    with {:ok, cookie} <- Ersventaja.Segfy.Auth.gate_cookie(),
         {:ok, html} <- fetch_html(cookie) do
      rows = parse_rows(html)
      Logger.info("[Segfy GestaoRenewal] #{length(rows)} linha(s) na tabela de renovações")
      {:ok, rows}
    end
  end

  defp fetch_html(cookie) when is_binary(cookie) do
    base = Ersventaja.Segfy.gestao_base_url() |> String.trim_trailing("/")
    url = base <> @list_query
    referer = Ersventaja.Segfy.gate_request_origin() <> "/"

    headers = [
      {"Cookie", cookie},
      {"Accept",
       "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"},
      {"Accept-Language", "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7"},
      {"Referer", referer},
      {"Upgrade-Insecure-Requests", "1"},
      {"Sec-Fetch-Dest", "iframe"},
      {"Sec-Fetch-Mode", "navigate"},
      {"Sec-Fetch-Site", "same-site"}
    ]

    # follow_redirect: false — sessão SSO do app nem sempre aceita no domínio gestão legado;
    # evita loop 302 → /Autenticacao (max_redirect_overflow no Hackney).
    opts = [
      :with_body,
      recv_timeout: @recv_timeout,
      connect_timeout: @connect_timeout,
      follow_redirect: false
    ]

    case :hackney.get(url, headers, [], opts) do
      {:ok, status, _rh, body} when status in 200..299 ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, 302, _, _} ->
        Logger.debug(
          "[Segfy GestaoRenewal] 302 — sessão ASP.NET no HTML legado indisponível (esperado sem browser); fallback Gate"
        )

        {:error, :gestao_requires_browser_session}

      {:ok, status, _, body} ->
        Logger.warning("[Segfy GestaoRenewal] HTTP #{status} #{url}")
        {:error, {:http, status, truncate(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp truncate(b) when is_binary(b) and byte_size(b) > 400, do: binary_part(b, 0, 400) <> "..."
  defp truncate(b), do: to_string(b)

  defp parse_rows(html) when is_binary(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.find(
          "#ContentPlaceHolderMaster_CphMasterAutenticado_upOrcamentoRenovacao tbody tr"
        )
        |> then(fn rows ->
          if rows == [] do
            Floki.find(doc, "table tbody tr")
          else
            rows
          end
        end)
        |> Enum.map(&parse_row/1)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp parse_row(tr) do
    vig = span_text(tr, "lblFinalVigencia")
    apol = span_text(tr, "lblApolice")
    nome = span_text(tr, "lblSegurado")

    if nome != "" and apol != "" do
      %{
        "nomeCliente" => String.trim(nome),
        "numeroApolice" => String.trim(apol),
        "dataFim" => String.trim(vig),
        "origem" => "gestao_html"
      }
    end
  end

  defp span_text(tr, id_part) do
    case Floki.find(tr, "span[id*='#{id_part}']") do
      [] -> ""
      nodes -> nodes |> Floki.text() |> String.trim()
    end
  end
end
