defmodule Ersventaja.Segfy.GestaoProsseguir do
  @moduledoc false
  # POST Prosseguir ASP.NET (UpdatePanel) — extrai `cod` para HfyAuto / multicalculo app.

  require Logger

  alias Ersventaja.Segfy.{Client, Cookies, GestaoSession}

  @recv_timeout 90_000

  @doc """
  GET lista `OrcamentosRenovacao`, marca checkbox da apólice (dígitos) e POST `lbSalvarProsseguir`.

  Retorna `{:ok, cod, meta}` — `cod` (hex) para `https://app.segfy.com/multicalculo/hfy-auto?q=<cod>` e
  `meta.prosseguir_apolice` com os dígitos da apólice da linha onde o checkbox foi marcado (útil para
  `renewal.prior_policy` quando a apólice local não tem o número em `detail`).
  """
  def proceed(cookie, preferred_apolice_digits \\ "") when is_binary(cookie) do
    cookie = GestaoSession.warm(cookie)

    gb = Ersventaja.Segfy.gestao_base_url() |> String.trim_trailing("/")

    referer_app =
      Ersventaja.Segfy.gate_request_origin() |> String.trim_trailing("/") |> then(&(&1 <> "/"))

    want = digits_only(preferred_apolice_digits)

    urls = [
      gb <> "/OrcamentosRenovacao?novoOrcamento=true&cod=0",
      gb <> "//OrcamentosRenovacao?novoOrcamento=true&cod=0"
    ]

    headers_get = [
      {"Referer", referer_app},
      {"Upgrade-Insecure-Requests", "1"},
      {"Sec-Fetch-Dest", "iframe"},
      {"Sec-Fetch-Mode", "navigate"},
      {"Sec-Fetch-Site", "same-site"}
    ]

    r =
      Enum.reduce_while(urls, {cookie, nil}, fn url, {acc_cookie, _} ->
        case fetch_html(url, acc_cookie, headers_get) do
          {:ok, html, final_url, cookie_out} ->
            if good_page?(html, final_url) do
              {:halt, {cookie_out, {:ok, html, final_url, cookie_out}}}
            else
              {:cont, {cookie_out, {:try, html, final_url, cookie_out}}}
            end

          {:error, _} = e ->
            {:halt, {acc_cookie, e}}
        end
      end)

    case r do
      {_c, {:ok, html, final_url, cookie_out}} ->
        run_postback(html, final_url, cookie_out, gb, want)

      {_c, {:error, _} = e} ->
        e

      {_c, {:try, html, final_url, cookie_out}} ->
        # Login e várias telas ASP.NET têm __VIEWSTATE; a grade de renovação tem lblSegurado / Prosseguir.
        if renewal_grid_page?(html) do
          run_postback(html, final_url, cookie_out, gb, want)
        else
          Logger.warning(
            "[Segfy Prosseguir] HTML não é a lista de renovações (sem lblSegurado/lbSalvarProsseguir). " <>
              "Sessão Gestão/vuex ou cookie incompleto — mesma URL no browser mostraria a grade?"
          )

          {:error, :gestao_prosseguir_not_renewal_list}
        end

      _ ->
        {:error, :gestao_prosseguir_no_response}
    end
  end

  # Hackney com follow_redirect: true → max_redirect_overflow. Seguimos manualmente e
  # mesclamos Set-Cookie a cada hop (como o browser); sem isso a sessão ASP.NET não evolui.
  defp fetch_html(url, cookie, headers_get) do
    fetch_html_follow(url, cookie, headers_get, 0)
  end

  @max_redirect_hops 12

  defp fetch_html_follow(url, cookie, headers_get, depth) do
    if depth > @max_redirect_hops do
      {:error, :gestao_prosseguir_redirect_limit}
    else
      h = [
        {"Cookie", cookie},
        {"User-Agent", Client.user_agent()},
        {"Accept",
         "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"},
        {"Accept-Language", "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7"}
        | headers_get
      ]

      opts = [
        :with_body,
        recv_timeout: @recv_timeout,
        connect_timeout: 15_000,
        follow_redirect: false
      ]

      case :hackney.get(url, h, [], opts) do
        {:ok, status, rh, body} when status in [301, 302, 303, 307, 308] ->
          cookie = Cookies.merge_set_cookies_into_header(cookie, rh)

          case location_header(rh) do
            loc when is_binary(loc) and loc != "" ->
              next = resolve_redirect_url(url, loc)
              fetch_html_follow(next, cookie, headers_get, depth + 1)

            _ ->
              Logger.warning("[Segfy Prosseguir] GET #{url} HTTP #{status} sem Location")
              {:error, {:http, status, truncate(body)}}
          end

        {:ok, status, rh, body} when status in 200..299 ->
          merged = Cookies.merge_set_cookies_into_header(cookie, rh)
          {:ok, IO.iodata_to_binary(body), url, merged}

        {:ok, status, _, body} ->
          Logger.warning("[Segfy Prosseguir] GET #{url} HTTP #{status}")
          {:error, {:http, status, truncate(body)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp location_header(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} ->
        if String.downcase(to_string(k)) == "location", do: v, else: nil

      _ ->
        nil
    end)
  end

  defp location_header(_), do: nil

  defp resolve_redirect_url(current_url, location) do
    location = String.trim(location)

    case URI.parse(location) do
      %URI{scheme: s} when s in ["http", "https"] ->
        location

      _ ->
        base = URI.parse(current_url)

        (base.scheme && base.host &&
           URI.merge(base, URI.parse(location))
           |> URI.to_string()) || location
    end
  end

  defp good_page?(html, final_url) do
    u = String.downcase(final_url || "")
    bad = String.contains?(u, "logoff")

    good =
      renewal_grid_page?(html) and String.contains?(html || "", "__VIEWSTATE") and
        byte_size(html || "") > 800

    good and not bad
  end

  defp renewal_grid_page?(html) when is_binary(html) do
    String.contains?(html, "lblSegurado") or String.contains?(html, "lbSalvarProsseguir") or
      String.contains?(html, "upOrcamentoRenovacao")
  end

  defp renewal_grid_page?(_), do: false

  defp run_postback(html, page_url, cookie, gb, want) do
    html_len = byte_size(html || "")

    Logger.info(
      "[Segfy Prosseguir] run_postback url=#{page_url} html_len=#{html_len} " <>
        "__VIEWSTATE?=#{String.contains?(html || "", "__VIEWSTATE")} " <>
        "lblSegurado?=#{String.contains?(html || "", "lblSegurado")} " <>
        "lbSalvarProsseguir?=#{String.contains?(html || "", "lbSalvarProsseguir")}"
    )

    case Floki.parse_document(html) do
      {:ok, doc} ->
        form = find_form_with_viewstate(doc)

        if form == nil do
          Logger.warning(
            "[Segfy Prosseguir] nenhum <form> com __VIEWSTATE encontrado. " <>
              "HTML len=#{html_len} __VIEWSTATE?=#{String.contains?(html || "", "__VIEWSTATE")}"
          )

          {:error, :gestao_prosseguir_no_form}
        else
          post_url = form_action_url(form, page_url, gb)
          sm_name = script_manager_name(html, form, doc)
          dpb = extract_prosseguir_postback(doc, html)

          cond do
            sm_name == nil ->
              Logger.warning(
                "[Segfy Prosseguir] ScriptManager não encontrado (JS nem input hidden). " <>
                  "HTML tem __VIEWSTATE? #{String.contains?(html || "", "__VIEWSTATE")} lblSegurado? #{String.contains?(html || "", "lblSegurado")}"
              )

              {:error, :gestao_prosseguir_no_scriptmanager}

            dpb == nil ->
              Logger.warning(
                "[Segfy Prosseguir] link lbSalvarProsseguir não encontrado no HTML. " <>
                  "HTML contém 'lbSalvarProsseguir'? #{String.contains?(html || "", "lbSalvarProsseguir")} " <>
                  "contém '__doPostBack'? #{String.contains?(html || "", "__doPostBack")}"
              )

              {:error, :gestao_prosseguir_no_prosseguir_link}

            true ->
              {evt_target, _evt_arg} = dpb
              rows = collect_checkbox_rows(doc)

              if rows == [] do
                Logger.warning(
                  "[Segfy Prosseguir] nenhuma linha com checkbox + lblApolice na tabela. " <>
                    "HTML contém 'lblApolice'? #{String.contains?(html || "", "lblApolice")} " <>
                    "contém 'checkbox'? #{String.contains?(html || "", "checkbox")}"
                )

                {:error, :gestao_prosseguir_no_rows}
              else
                chosen = choose_row(rows, want)
                sel_name = chosen["name"]

                Logger.info(
                  "[Segfy Prosseguir] linha apólice=#{inspect(chosen["apolice"])} name=…#{String.slice(sel_name, -40..-1//1)}"
                )

                up_el = update_panel_for_prosseguir(doc)
                panel_uid = panel_uid_for(evt_target, up_el)

                sm_val = panel_uid <> "|" <> evt_target
                ddl = find_ddl_cod_ramo(form) || {nil, "-1"}

                {ddl_name, ddl_val} = ddl

                nps_score = Floki.find(form, "input[name*='hiddenFieldScore']") |> List.first()
                nps_chave = Floki.find(form, "input[name*='hiddenFieldChave']") |> List.first()

                nps_score_name = nps_score && Floki.attribute(nps_score, "name") |> List.first()
                nps_chave_name = nps_chave && Floki.attribute(nps_chave, "name") |> List.first()

                pairs =
                  [
                    {sm_name, sm_val},
                    {"__EVENTTARGET", evt_target},
                    {"__EVENTARGUMENT", ""},
                    {"__LASTFOCUS", ""},
                    {"__VSTATE", hidden_input(form, "__VSTATE")},
                    {"__VIEWSTATE", ""},
                    {"__PREVIOUSPAGE", hidden_input(form, "__PREVIOUSPAGE")},
                    {"__EVENTVALIDATION", hidden_input(form, "__EVENTVALIDATION")},
                    {ddl_name || "", ddl_val},
                    {sel_name, "on"},
                    {nps_score_name || "", ""},
                    {nps_chave_name || "", ""},
                    {"__ASYNCPOST", "true"}
                  ]
                  |> Enum.reject(fn {k, _} -> k == nil or k == "" end)

                post_headers = [
                  {"Origin", gb},
                  {"Referer", page_url},
                  {"Sec-Fetch-Dest", "empty"},
                  {"Sec-Fetch-Mode", "cors"},
                  {"Sec-Fetch-Site", "same-origin"}
                ]

                ap_meta =
                  Map.get(chosen, "digits") || digits_only(Map.get(chosen, "apolice") || "")

                case Client.post_gestao_form(post_url, cookie, pairs, post_headers) do
                  {:ok, _st, resp_body} ->
                    parse_page_redirect(resp_body, ap_meta)

                  {:error, _} = e ->
                    e
                end
              end
          end
        end

      {:error, parse_err} ->
        Logger.warning("[Segfy Prosseguir] Floki parse_document falhou: #{inspect(parse_err)}")
        {:error, :gestao_prosseguir_bad_html}
    end
  end

  defp parse_page_redirect(resp_body, prosseguir_apolice) when is_binary(resp_body) do
    ap = digits_only(to_string(prosseguir_apolice || ""))

    if String.contains?(resp_body, "|pageRedirect|") do
      case Regex.run(~r/\|pageRedirect\|\|([^|]+)\|/, resp_body) do
        [_, path] ->
          path = URI.decode(path)
          cod = Regex.run(~r/cod=([a-fA-F0-9]+)/, path)

          case cod do
            [_, hex] ->
              Logger.info("[Segfy Prosseguir] cod HfyAuto=#{hex}")
              {:ok, String.downcase(hex), %{prosseguir_apolice: ap}}

            _ ->
              {:error, :gestao_prosseguir_no_cod_in_redirect}
          end

        _ ->
          {:error, :gestao_prosseguir_bad_redirect}
      end
    else
      if String.contains?(resp_body, "|error|") do
        Logger.warning("[Segfy Prosseguir] resposta async error: #{truncate(resp_body)}")
      end

      {:error, :gestao_prosseguir_not_redirect}
    end
  end

  defp truncate(b) when is_binary(b) and byte_size(b) > 400, do: binary_part(b, 0, 400) <> "..."
  defp truncate(b), do: to_string(b)

  defp digits_only(s) when is_binary(s), do: String.replace(s, ~r/[^0-9]/, "")
  defp digits_only(_), do: ""

  defp find_form_with_viewstate(doc) do
    Floki.find(doc, "form")
    |> Enum.find(fn f ->
      Floki.find(f, "input[type='hidden']")
      |> Enum.any?(fn i ->
        n = Floki.attribute(i, "name") |> List.first() |> to_string()
        n == "__VIEWSTATE" or String.ends_with?(n, "__VIEWSTATE")
      end)
    end)
  end

  defp form_action_url(form, page_url, gb) do
    action =
      form
      |> Floki.attribute("action")
      |> List.first()
      |> to_string()
      |> String.trim()

    cond do
      action == "" ->
        page_url

      String.starts_with?(action, "http") ->
        action

      String.starts_with?(action, "/") ->
        gb <> action

      true ->
        URI.merge(URI.parse(page_url), URI.parse(action)) |> URI.to_string()
    end
  end

  # Mesma ideia do probe: PageRequestManager._initialize('NAME', …) — o nome também pode aparecer
  # só em input hidden (ASP.NET 4.x / markup diferente / aspas duplas / Sys.WebForms opcional).
  defp script_manager_name(html, form, doc) do
    html = html || ""

    normalized =
      html
      |> String.replace("&quot;", "\"")
      |> String.replace("&#39;", "'")
      |> String.replace("&apos;", "'")

    from_js =
      Enum.find_value(script_manager_patterns(), fn re ->
        case Regex.run(re, normalized) do
          [_, n] when is_binary(n) and n != "" -> String.trim(n)
          _ -> nil
        end
      end)

    from_js || script_manager_name_from_form(form) || script_manager_name_from_form(doc)
  end

  defp script_manager_patterns do
    [
      # Probe Python: PageRequestManager._initialize('…'
      ~r/PageRequestManager\._initialize\s*\(\s*'([^']+)'/u,
      # Aspas duplas (minificadores / bundlers)
      ~r/PageRequestManager\._initialize\s*\(\s*"([^"]+)"/u,
      # Prefixo Sys.WebForms explícito
      ~r/Sys\.WebForms\.PageRequestManager\._initialize\s*\(\s*'([^']+)'/u,
      ~r/Sys\.WebForms\.PageRequestManager\._initialize\s*\(\s*"([^"]+)"/u,
      # Case-insensitive (raro)
      ~r/(?i)PageRequestManager\._initialize\s*\(\s*['"]([^'"]+)['"]/
    ]
  end

  defp script_manager_name_from_form(form) do
    candidates =
      form
      |> Floki.find("input[type='hidden'][name*='ScriptManager']")
      |> Enum.map(fn i -> Floki.attribute(i, "name") |> List.first() |> to_string() end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reject(&String.contains?(&1, "HiddenField"))

    Enum.find(candidates, &Regex.match?(~r/ScriptManager\d+$/u, &1)) || List.first(candidates)
  end

  defp extract_prosseguir_postback(doc, html) do
    found =
      doc
      |> Floki.find("a[href]")
      |> Enum.find(fn a ->
        href = Floki.attribute(a, "href") |> List.first() |> to_string()
        id = Floki.attribute(a, "id") |> List.first() |> to_string()
        String.contains?(id, "lbSalvarProsseguir") or String.contains?(href, "lbSalvarProsseguir")
      end)

    href =
      if found do
        Floki.attribute(found, "href") |> List.first() |> to_string()
      else
        ""
      end

    case Regex.run(~r/__doPostBack\s*\(\s*'([^']+)'\s*,\s*'([^']*)'\s*\)/u, href) do
      [_, t, a] -> {t, a}
      _ -> do_postback_from_html(html)
    end
  end

  defp do_postback_from_html(html) do
    case Regex.run(
           ~r/__doPostBack\s*\(\s*'([^']*lbSalvarProsseguir[^']*)'\s*,\s*'([^']*)'\s*\)/u,
           html
         ) do
      [_, t, a] -> {t, a}
      _ -> nil
    end
  end

  defp parse_row(tr) do
    cb =
      Floki.find(tr, "input[type='checkbox']")
      |> Enum.find(fn i ->
        n = Floki.attribute(i, "name") |> List.first() |> to_string()

        n != "" and not String.contains?(n, "chkMarcarDesmarcar") and
          not String.contains?(n, "MarcarDesmarcar")
      end)

    if cb == nil do
      nil
    else
      name = Floki.attribute(cb, "name") |> List.first() |> to_string()

      apol =
        tr
        |> Floki.find("span[id*='lblApolice']")
        |> Floki.text()
        |> String.trim()

      seg =
        tr
        |> Floki.find("span[id*='lblSegurado']")
        |> Floki.text()
        |> String.trim()

      if apol != "" or seg != "" do
        %{
          "name" => name,
          "apolice" => apol,
          "segurado" => seg,
          "digits" => digits_only(apol)
        }
      end
    end
  end

  defp collect_checkbox_rows(doc) do
    panel = Floki.find(doc, "[id*='upOrcamentoRenovacao']") |> List.first()
    roots = if(panel, do: [panel, doc], else: [doc])

    Enum.reduce(roots, {[], MapSet.new()}, fn root, {acc, seen} ->
      Floki.find(root, "tr")
      |> Enum.reduce({acc, seen}, fn tr, {a, s} ->
        case parse_row(tr) do
          nil ->
            {a, s}

          row ->
            n = row["name"]

            if MapSet.member?(s, n) do
              {a, s}
            else
              {a ++ [row], MapSet.put(s, n)}
            end
        end
      end)
    end)
    |> elem(0)
  end

  defp choose_row(rows, want) do
    if want != "" do
      Enum.find(rows, fn r ->
        d = r["digits"]
        want == d or String.contains?(d, want) or String.contains?(want, d)
      end) || List.first(rows)
    else
      List.first(rows)
    end
  end

  defp update_panel_for_prosseguir(doc) do
    Floki.find(doc, "[id*='upDatas']") |> List.first() ||
      Floki.find(doc, "[id*='upOrcamentoRenovacao']") |> List.first()
  end

  defp panel_uid_for(evt_target, up_el) do
    prefix = evt_target |> String.split("$") |> Enum.drop(-1) |> Enum.join("$")

    suffix =
      if up_el == nil do
        "upDatas"
      else
        id = Floki.attribute(up_el, "id") |> List.first() |> to_string()
        id |> String.split("_") |> List.last() || "upDatas"
      end

    prefix <> "$" <> suffix
  end

  defp hidden_input(form, suffix) when is_binary(suffix) do
    form
    |> Floki.find("input[type='hidden']")
    |> Enum.find(fn i ->
      n = Floki.attribute(i, "name") |> List.first() |> to_string()
      n == suffix or String.ends_with?(n, "$" <> suffix) or String.ends_with?(n, suffix)
    end)
    |> case do
      nil -> ""
      el -> Floki.attribute(el, "value") |> List.first() || ""
    end
  end

  defp find_ddl_cod_ramo(form) do
    case Floki.find(form, "select[name*='ddlCod_Ramo']") |> List.first() do
      nil ->
        nil

      ddl ->
        name = Floki.attribute(ddl, "name") |> List.first()
        sel = Floki.find(ddl, "option[selected]") |> List.first()
        val = if sel, do: Floki.attribute(sel, "value") |> List.first() || "-1", else: "-1"
        {name, val}
    end
  end
end
