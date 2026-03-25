defmodule Ersventaja.Segfy.Budget do
  @moduledoc """
  Listagem de orçamentos via `POST /bgt/api/budget/list` no Upfy Gate.

  O formato exato do JSON varia; normalizamos várias chaves possíveis e fazemos o match
  com a apólice local por nome do cliente, CPF (se houver) e vigência (início/fim).

  **Contrato com HAR:** copie o body do request do DevTools (filtro “budget” ou preserve log;
  ao abrir só `orcamento-renovacao?q=0`, o POST pode não aparecer — a lista às vezes vem do iframe Gestão)
  para `test/fixtures/segfy/budget_list_request.json` e rode
  `mix run --no-start scripts/verify_segfy_budget_request.exs` — o script compara com
  `build_list_request_body([])` e imprime um exemplo com datas da apólice (`list_opts_from_policy/1`).

  No app, `q=0` em `orcamento-renovacao` = funil “renovações não iniciadas”; no Gestão legado o par
  equivalente na URL da tabela é `cod=0` (já usado em `GestaoRenewal`).
  """

  require Logger

  alias Ersventaja.Segfy.UpfyGate

  @log_candidates_max 30

  @list_path "/bgt/api/budget/list"

  @doc """
  Caminho do POST no Upfy Gate (para comparar com HAR: método + path + host).
  """
  def list_path, do: @list_path

  @doc """
  Opções de listagem derivadas de uma apólice local (datas de vigência + nome para `search`),
  no mesmo formato usado pelo fluxo de renovação.
  """
  def list_opts_from_policy(policy) when is_map(policy) do
    start_d = policy[:start_date] || policy["start_date"]
    end_d = policy[:end_date] || policy["end_date"]

    search =
      case policy[:customer_name] || policy["customer_name"] do
        nil -> ""
        s -> s |> to_string() |> String.trim()
      end

    [data_inicio: start_d, data_fim: end_d, search: search]
  end

  @doc """
  Opções que geram o mesmo JSON que `test/fixtures/segfy/budget_list_request.json`
  (`dataInicio`/`dataFim` nulos, `search` vazio, demais defaults) — o que o front costuma mandar
  ao carregar a listagem no DevTools/HAR.
  """
  def list_opts_har_default do
    []
  end

  @doc """
  Monta o JSON de `POST /bgt/api/budget/list` exatamente como enviado ao gate.

  Opções (alinhadas ao que costuma aparecer no HAR do front):

  - `:page_number` (default 1), `:page_size` (default 20 — alinhado ao HAR do app)
  - `:search` — texto de busca (string, default `""`)
  - `:data_inicio`, `:data_fim` — `Date.t()` ou ISO string (default `nil` → JSON `null`)
  - `:usuario_id`, `:status`, `:tipo_data_busca` — inteiros (defaults `0`, `0`, `1`)
  - `:sort_column` (default `"Data"`), `:sort_order` (default `"desc"`)

  Use `Jason.encode!(build_list_request_body(opts))` e compare byte a byte com o request body do HAR.
  """
  def build_list_request_body(opts \\ []) do
    page = Keyword.get(opts, :page_number, 1)
    size = Keyword.get(opts, :page_size, 20)
    search = Keyword.get(opts, :search, "")

    %{
      dataInicio: opt_date_to_value(Keyword.get(opts, :data_inicio)),
      dataFim: opt_date_to_value(Keyword.get(opts, :data_fim)),
      search: search,
      usuarioId: Keyword.get(opts, :usuario_id, 0),
      status: Keyword.get(opts, :status, 0),
      pageNumber: page,
      pageSize: size,
      sortColumn: Keyword.get(opts, :sort_column, "Data"),
      sortOrder: Keyword.get(opts, :sort_order, "desc"),
      tipoDataBusca: Keyword.get(opts, :tipo_data_busca, 1)
    }
  end

  @doc """
  Uma página da listagem. Opções:

  - `:page_number` (default 1)
  - `:page_size` (default 20)
  - `:search` — texto de busca (opcional)
  - `:data_inicio`, `:data_fim` — datas `Date.t()` ou ISO string (opcional)
  - Mesmas opções extras de `build_list_request_body/1`
  """
  def list_page(opts \\ []) do
    body = build_list_request_body(opts)
    page_num = Keyword.get(opts, :page_number, 1)

    case UpfyGate.post(@list_path, body) do
      {:ok, response} ->
        items = normalize_items(response)

        if page_num == 1 and items == [] do
          log_empty_budget_list_response(body, response)
        end

        {:ok, items, response}

      {:error, _} = e ->
        e
    end
  end

  defp empty_list_renewal_hint(%{} = response) do
    q =
      get_in(response, ["data", "qtdeRenovacaoNaoInciada"]) ||
        get_in(response, ["data", "QtdeRenovacaoNaoInciada"])

    if is_integer(q) and q > 0 do
      " — API indica renovação pendente (qtdeRenovacaoNaoInciada=#{q}) mas itemOrcamento vazio; filtro de data/status pode excluir a linha"
    else
      ""
    end
  end

  defp empty_list_renewal_hint(_), do: ""

  defp log_empty_budget_list_response(request_body, response) when is_map(response) do
    top_keys = response |> Map.keys() |> Enum.sort()

    result_info =
      case response["result"] do
        %{} = r -> "result_keys=#{inspect(r |> Map.keys() |> Enum.sort())}"
        list when is_list(list) -> "result_is_list length=#{length(list)}"
        nil -> "result=nil"
        other -> "result_other=#{inspect(other)}"
      end

    sample =
      case Jason.encode(response) do
        {:ok, json} -> String.slice(json, 0, 2500)
        _ -> "(encode error)"
      end

    hint = empty_list_renewal_hint(response)

    Logger.warning(
      "[Segfy Budget] listagem página 1 normalizou 0 itens — request=#{inspect(request_body)} top_keys=#{inspect(top_keys)} #{result_info}#{hint}"
    )

    Logger.warning("[Segfy Budget] resposta JSON (truncada): #{sample}")
  end

  @doc """
  Percorre páginas até `max_pages` ou até uma página vazia.
  Retorna `{:ok, [items...]}`.
  """
  def list_all(opts \\ []) do
    max_pages = Keyword.get(opts, :max_pages, 15)
    page_size = Keyword.get(opts, :page_size, 20)

    Enum.reduce_while(1..max_pages, {:ok, []}, fn page, {:ok, acc} ->
      case list_page(Keyword.merge(opts, page_number: page, page_size: page_size)) do
        {:ok, [], _raw} ->
          {:halt, {:ok, acc}}

        {:ok, items, _raw} when is_list(items) ->
          if items == [] do
            {:halt, {:ok, acc}}
          else
            {:cont, {:ok, acc ++ items}}
          end

        {:error, _} = e ->
          {:halt, e}
      end
    end)
  end

  @doc """
  Encontra o primeiro item da listagem que casa com a apólice (mapa com atom keys como em `Policies.get_policy/1`).
  """
  def find_matching_item(policy, items) when is_map(policy) and is_list(items) do
    pid = policy[:id] || policy["id"]

    Logger.info(
      "[Segfy Budget] find_matching_item policy_id=#{inspect(pid)} items_count=#{length(items)} #{policy_criteria_line(policy)}"
    )

    case Enum.find(items, &matches_policy?(policy, &1)) do
      nil ->
        log_no_segfy_match(policy, items)
        {:error, :no_segfy_match}

      item ->
        Logger.info(
          "[Segfy Budget] match ok policy_id=#{inspect(pid)} #{item_match_summary(item)}"
        )

        {:ok, item}
    end
  end

  defp policy_criteria_line(policy) do
    pn = normalize_name(policy[:customer_name] || policy["customer_name"])
    cpf = digits(policy[:customer_cpf_or_cnpj] || policy["customer_cpf_or_cnpj"])
    ps = policy[:start_date] || policy["start_date"]
    pe = policy[:end_date] || policy["end_date"]
    mode = if cpf != "" and byte_size(cpf) >= 11, do: "cpf+vigencia", else: "nome+vigencia"

    "match_mode=#{mode} policy_nome=#{inspect(pn)} policy_doc_suffix=#{mask_doc_suffix(cpf)} policy_vigencia=#{inspect({as_date(ps), as_date(pe)})}"
  end

  defp log_no_segfy_match(policy, items) do
    n = length(items)

    if n == 0 do
      Logger.warning("[Segfy Budget] no_segfy_match: listagem Segfy veio vazia (0 itens)")
    else
      Logger.warning(
        "[Segfy Budget] no_segfy_match: nenhum dos #{n} itens passou no filtro; primeiros #{min(n, @log_candidates_max)} candidatos abaixo"
      )

      items
      |> Enum.take(@log_candidates_max)
      |> Enum.with_index(1)
      |> Enum.each(fn {item, idx} ->
        Logger.info("[Segfy Budget] candidate #{idx}/#{n} #{item_diagnostic_line(policy, item)}")
      end)

      if n > @log_candidates_max do
        Logger.info("[Segfy Budget] ... omitidos #{n - @log_candidates_max} itens (limite log)")
      end
    end
  end

  defp item_diagnostic_line(policy, item) do
    name_item = customer_name_from_item(item)
    cpf_item = item_cpf_digits(item)
    {is, ie} = vigencia_from_item(item)
    cpf_policy = digits(policy[:customer_cpf_or_cnpj] || policy["customer_cpf_or_cnpj"])
    use_cpf? = cpf_policy != "" and byte_size(cpf_policy) >= 11

    name_ok = name_matches?(policy, item)
    vig_ok = vigencia_matches?(policy, item)

    if use_cpf? do
      cpf_ok = cpf_item != "" and cpf_item == cpf_policy

      "mode=cpf nome=#{inspect(name_item)} doc_segfy_suffix=#{mask_doc_suffix(cpf_item)} cpf_ok=#{cpf_ok} vig_ok=#{vig_ok} vig_segfy=#{inspect({is, ie})}"
    else
      "mode=nome nome_ok=#{name_ok} vig_ok=#{vig_ok} nome_segfy=#{inspect(name_item)} vig_segfy=#{inspect({is, ie})}"
    end
  end

  defp item_match_summary(item) do
    name_item = customer_name_from_item(item)
    {is, ie} = vigencia_from_item(item)
    cpf_item = item_cpf_digits(item)

    "matched nome=#{inspect(name_item)} doc_suffix=#{mask_doc_suffix(cpf_item)} vig=#{inspect({is, ie})}"
  end

  defp mask_doc_suffix(digits_str) when is_binary(digits_str) do
    cond do
      digits_str == "" -> "(vazio)"
      byte_size(digits_str) <= 4 -> "****"
      true -> "****" <> String.slice(digits_str, -4, 4)
    end
  end

  defp mask_doc_suffix(_), do: "(?)"

  defp matches_policy?(policy, item) do
    name_ok = name_matches?(policy, item)
    vig_ok = vigencia_matches?(policy, item)

    cpf_policy = digits(policy[:customer_cpf_or_cnpj] || policy["customer_cpf_or_cnpj"])

    cond do
      cpf_policy != "" and byte_size(cpf_policy) >= 11 ->
        cpf_item = item_cpf_digits(item)

        cond do
          cpf_item != "" and cpf_item == cpf_policy ->
            vig_ok

          # Gate/JSON muitas vezes não traz CPF no item — cai no mesmo critério nome+vigência
          cpf_item == "" ->
            name_ok and vig_ok

          true ->
            false
        end

      true ->
        name_ok and vig_ok
    end
  end

  defp name_matches?(policy, item) do
    pn = normalize_name(policy[:customer_name] || policy["customer_name"])
    in_item = customer_name_from_item(item)

    in_item != "" and pn != "" and
      (in_item == pn or String.contains?(in_item, pn) or String.contains?(pn, in_item))
  end

  defp vigencia_matches?(policy, item) do
    ps = policy[:start_date] || policy["start_date"]
    pe = policy[:end_date] || policy["end_date"]

    case {as_date(ps), as_date(pe), vigencia_from_item(item)} do
      {%Date{} = psd, %Date{} = ped, {is, ie}} ->
        end_ok =
          case ie do
            %Date{} = ied -> date_close?(ped, ied)
            _ -> false
          end

        # Tela Gestão HTML só tem "Vence em" (fim) — sem data de início no item
        start_ok =
          case is do
            %Date{} = isd -> date_close?(psd, isd)
            nil -> true
          end

        standard = end_ok and start_ok

        # Renovação na Segfy: vigência do orçamento é o período NOVO; na apólice local ainda é o anterior.
        # Heurística: fim da apólice local ≈ início da vigência nova (dtInicioVigencia).
        renewal =
          case parse_date_flexible(get_first(item, ["dtInicioVigencia", "DtInicioVigencia"])) do
            %Date{} = ini_nova -> date_close?(ped, ini_nova)
            _ -> false
          end

        standard or renewal

      _ ->
        false
    end
  end

  defp date_close?(%Date{} = a, %Date{} = b), do: Date.diff(a, b) in -1..1

  defp normalize_name(nil), do: ""

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  defp customer_name_from_item(item) when is_map(item) do
    raw =
      get_first(item, [
        "nomeCliente",
        "NomeCliente",
        "cliente",
        "Cliente",
        "nome",
        "Nome",
        "segurado",
        "Segurado",
        "nomeSegurado",
        "NomeSegurado"
      ])

    normalize_name(to_string(raw || ""))
  end

  defp item_cpf_digits(item) when is_map(item) do
    raw =
      get_first(item, [
        "cpf",
        "Cpf",
        "CPF",
        "cpfCnpj",
        "CpfCnpj",
        "documento",
        "Documento",
        "documentoCliente"
      ])

    digits(to_string(raw || ""))
  end

  defp vigencia_from_item(item) when is_map(item) do
    start_d =
      parse_date_flexible(
        get_first(item, [
          "dataInicio",
          "DataInicio",
          "dtInicioVigencia",
          "DtInicioVigencia",
          "vigenciaInicial",
          "VigenciaInicial",
          "inicioVigencia",
          "validadeInicial"
        ])
      )

    end_d =
      parse_date_flexible(
        get_first(item, [
          "dataFim",
          "DataFim",
          "dtFinalVigencia",
          "DtFinalVigencia",
          "dataVencimento",
          "DataVencimento",
          "dtVencimento",
          "DtVencimento",
          "vencimento",
          "Vencimento",
          "vigenciaFinal",
          "VigenciaFinal",
          "fimVigencia",
          "validadeFinal",
          "dataTermino",
          "dataExpiracao",
          "DataExpiracao"
        ])
      )

    {start_d, end_d}
  end

  # Linha da listagem Gate/Gestão (mesmo mapa usado em `find_matching_item`) — costuma ter
  # apólice e "Vence em" quando a apólice local ou o show ainda não têm esses campos.
  @doc false
  def renewal_prior_policy_digits_from_gate_item(item) when is_map(item) do
    raw =
      get_first(item, [
        "numeroApolice",
        "NumeroApolice",
        "numero_apolice",
        "mask_police",
        "MaskPolice",
        "maskPolicy",
        "policy_number",
        "policyNumber",
        "numeroApoliceAnterior",
        "apolice",
        "Apolice",
        "numApolice",
        "num_apolice"
      ])

    String.replace(to_string(raw || ""), ~r/[^0-9]/, "")
  end

  def renewal_prior_policy_digits_from_gate_item(_), do: ""

  @doc false
  def renewal_prior_policy_end_iso_from_gate_item(item) when is_map(item) do
    {_start, end_d} = vigencia_from_item(item)

    case end_d do
      %Date{} = d -> Date.to_iso8601(d)
      _ -> nil
    end
  end

  def renewal_prior_policy_end_iso_from_gate_item(_), do: nil

  defp get_first(map, keys) do
    Enum.find_value(keys, fn k ->
      case Map.get(map, k) do
        nil -> nil
        v -> v
      end
    end)
  end

  defp parse_date_flexible(nil), do: nil

  defp parse_date_flexible(%Date{} = d), do: d

  defp parse_date_flexible(s) when is_binary(s) do
    s =
      s
      |> String.trim()
      |> split_iso_datetime()

    cond do
      s == "" ->
        nil

      match?({:ok, _}, Date.from_iso8601(s)) ->
        {:ok, d} = Date.from_iso8601(s)
        d

      # dd/mm/yyyy
      Regex.match?(~r/^\d{2}\/\d{2}\/\d{4}$/, s) ->
        [dd, mm, yyyy] = String.split(s, "/")
        Date.from_iso8601!("#{yyyy}-#{mm}-#{dd}")

      true ->
        nil
    end
  end

  defp split_iso_datetime(s) when is_binary(s) do
    case String.split(s, "T", parts: 2) do
      [date, _] -> String.trim(date)
      _ -> s
    end
  end

  defp as_date(%Date{} = d), do: d
  defp as_date(s), do: parse_date_flexible(s)

  defp digits(nil), do: ""
  defp digits(s), do: String.replace(to_string(s), ~r/[^0-9]/, "")

  defp opt_date_to_value(nil), do: nil
  defp opt_date_to_value(%Date{} = d), do: Date.to_iso8601(d)
  defp opt_date_to_value(s) when is_binary(s), do: s

  defp normalize_items(response) when is_map(response) do
    cond do
      is_map(response["data"]) and is_list(response["data"]["itemOrcamento"]) ->
        response["data"]["itemOrcamento"]

      is_map(response["data"]) and is_list(response["data"]["ItemOrcamento"]) ->
        response["data"]["ItemOrcamento"]

      is_list(response["data"]) ->
        response["data"]

      is_list(response["Data"]) ->
        response["Data"]

      is_list(response["items"]) ->
        response["items"]

      is_list(response["Items"]) ->
        response["Items"]

      is_list(response["lista"]) ->
        response["lista"]

      is_list(response["Lista"]) ->
        response["Lista"]

      is_list(response["rows"]) ->
        response["rows"]

      is_list(response["Rows"]) ->
        response["Rows"]

      is_list(response["value"]) ->
        response["value"]

      is_list(response["Value"]) ->
        response["Value"]

      is_list(response["result"]) ->
        response["result"]

      is_map(response["result"]) and is_list(response["result"]["items"]) ->
        response["result"]["items"]

      is_map(response["result"]) and is_list(response["result"]["Items"]) ->
        response["result"]["Items"]

      is_map(response["result"]) and is_list(response["result"]["data"]) ->
        response["result"]["data"]

      is_map(response["result"]) and is_list(response["result"]["Data"]) ->
        response["result"]["Data"]

      is_map(response["result"]) and is_list(response["result"]["lista"]) ->
        response["result"]["lista"]

      is_map(response["result"]) and is_list(response["result"]["Lista"]) ->
        response["result"]["Lista"]

      is_map(response["result"]) and is_list(response["result"]["rows"]) ->
        response["result"]["rows"]

      is_map(response["result"]) and is_list(response["result"]["Rows"]) ->
        response["result"]["Rows"]

      is_map(response["result"]) and is_map(response["result"]["data"]) and
          is_list(response["result"]["data"]["items"]) ->
        response["result"]["data"]["items"]

      is_map(response["result"]) and is_map(response["result"]["Data"]) and
          is_list(response["result"]["Data"]["items"]) ->
        response["result"]["Data"]["items"]

      true ->
        []
    end
  end

  # Extrai itens brutos de POST …/renewal-list. Muitas vezes `data` é lista de seguradoras (wizard), não
  # orçamentos — ver `renewal_list_response_is_insurer_wizard?/1` (HAR inicia_renovacao.har).
  @doc false
  def normalize_renewal_list_response(resp) when is_map(resp) do
    cond do
      is_list(resp["data"]) ->
        resp["data"]

      is_map(resp["data"]) && is_list(resp["data"]["items"]) ->
        resp["data"]["items"]

      is_map(resp["data"]) && is_list(resp["data"]["renewals"]) ->
        resp["data"]["renewals"]

      is_map(resp["data"]) && is_list(resp["data"]["list"]) ->
        resp["data"]["list"]

      is_list(resp["result"]) ->
        resp["result"]

      is_map(resp["result"]) && is_list(resp["result"]["items"]) ->
        resp["result"]["items"]

      true ->
        []
    end
  end

  def normalize_renewal_list_response(_), do: []

  @doc false
  def renewal_list_response_is_insurer_wizard?(resp) when is_map(resp) do
    case resp["data"] do
      [first | _] when is_map(first) ->
        # Formato observado no HAR `inicia_renovacao.har` (app multicalculo): um item por seguradora.
        Map.has_key?(first, "mask_police") and Map.has_key?(first, "search_renewal") and
          not Map.has_key?(first, "quotationId") and not Map.has_key?(first, "nomeCliente") and
          not Map.has_key?(first, "NomeCliente")

      _ ->
        false
    end
  end

  def renewal_list_response_is_insurer_wizard?(_), do: false

  @doc """
  Extrai UUID/string da cotação Segfy a partir de um item da listagem.
  """
  def quotation_id_from_item(item) when is_map(item) do
    id =
      get_first(item, [
        "quotationId",
        "idCotacao",
        "IdCotacao",
        "cotacaoId",
        "QuotationId",
        "guid",
        "Guid",
        "id",
        "Id"
      ]) || dig_in(item, ["cotacao", "id"]) || dig_in(item, ["orcamento", "id"])

    cond do
      is_binary(id) and String.length(String.trim(id)) > 10 ->
        {:ok, String.trim(id)}

      is_integer(id) ->
        {:error, :invalid_quotation_id}

      true ->
        {:error, :quotation_id_not_found}
    end
  end

  defp dig_in(map, [a, b]) when is_map(map) do
    inner =
      Map.get(map, a) ||
        Map.get(map, to_string(a)) ||
        Map.get(map, String.capitalize(to_string(a)))

    if is_map(inner) do
      Map.get(inner, b) || Map.get(inner, to_string(b))
    else
      nil
    end
  end

  defp dig_in(_, _), do: nil

  @doc """
  Código do orçamento no gestão (query `codigoOrcamento`), se existir no payload.
  """
  def codigo_orcamento_from_item(item) when is_map(item) do
    raw =
      get_first(item, [
        "codigoOrcamento",
        "CodigoOrcamento",
        "codigo",
        "Codigo",
        "idOrcamento",
        "IdOrcamento"
      ])

    if is_binary(raw) and raw != "", do: raw, else: nil
  end
end
