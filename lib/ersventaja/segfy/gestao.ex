defmodule Ersventaja.Segfy.Gestao do
  @moduledoc """
  Chamadas ao domínio `gestao.segfy.com` relacionadas a orçamento.

  `SalvaCotacaoAutomation` persiste o estado da cotação após o cálculo (equivalente ao fluxo do browser).
  """

  alias Ersventaja.Segfy.Client

  @doc """
  GET `HfyAuto?cod=...` para aquecer a sessão ASP.NET antes de `SalvaCotacaoAutomation`
  (evita HTTP 500 sem este passo — ver probe Python).
  """
  def warm_hfy_auto_session(codigo_orcamento, cookie)
      when is_binary(codigo_orcamento) and is_binary(cookie) do
    gb = Ersventaja.Segfy.gestao_base_url() |> String.trim_trailing("/")

    url =
      if codigo_orcamento == "" do
        gb <> "/HfyAuto"
      else
        gb <> "/HfyAuto?" <> URI.encode_query(%{"cod" => codigo_orcamento})
      end

    case Client.get_follow_redirects(url, cookie, [{"Referer", gb <> "/"}]) do
      {:ok, merged_cookie, _st, _html} -> {:ok, merged_cookie}
      {:error, _} = e -> e
    end
  end

  @doc """
  POST `/api/Orcamento/SalvaCotacaoAutomation`.

  Parâmetros de query: `codigo_orcamento` e `token` — o mesmo token **opaco** do `list-by-intranet` usado em
  `config.token` no calculate (`scripts/segfy_chain_probe.py`), não o JWT de `/auths/token`.

  `body` deve incluir os campos esperados pelo gestão, ex.:

  - `quotation_id`, `token`, `data`, `config`, `tipo_multicalculo` (`"Auto"`).

  Opções: `:cookie` (sessão Gestão), `:referer`, `:origin` — alinhados ao browser / probe.
  """
  def salva_cotacao_automation(codigo_orcamento, token, body, opts \\ [])
      when is_binary(codigo_orcamento) and is_binary(token) and is_map(body) and is_list(opts) do
    path =
      "/api/Orcamento/SalvaCotacaoAutomation?" <>
        URI.encode_query(%{
          "codigoOrcamento" => codigo_orcamento,
          "token" => token
        })

    gb = Ersventaja.Segfy.gestao_base_url() |> String.trim_trailing("/")

    qopts =
      Keyword.merge(
        [
          referer: gb <> "/HfyAuto?" <> URI.encode_query(%{"cod" => codigo_orcamento}),
          origin: gb
        ],
        opts
      )

    Client.post_gestao(path, body, qopts)
  end
end
