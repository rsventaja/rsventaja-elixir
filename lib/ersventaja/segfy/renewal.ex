defmodule Ersventaja.Segfy.Renewal do
  @moduledoc """
  Fluxo completo para **calcular renovação** na Segfy a partir de uma apólice local:

  1. Lista renovações no **Gestão** (`GET …/OrcamentosRenovacao` — HTML, mesmo fluxo do HAR do app).
     Se vier vazio ou falhar, cai no **Upfy Gate** `POST /bgt/api/budget/list`: primeiro com o mesmo
     body do baseline (`Budget.list_opts_har_default/0` = fixture/HAR), depois com `search` + datas da apólice.
  2. Encontra linha com mesmo cliente + vigência (`Ersventaja.Segfy.Budget`).
  3. Resolve o **quotation_id** (UUID): no JSON do Gate já vem; na tabela HTML só há nº de apólice —
     aí busca no Gate com `search` pelo número da apólice.
  4. Carrega a cotação com `Vehicle.show/1`.
  5. Opcional: texto do PDF (`OCR.extract_text_from_pdf/1`) → **só** `AutoPolicyExtractor` (LLM); sem heurísticas no texto bruto.
  6. `Vehicle.calculate/2`.

  Requer login Firebase (`SEGFY_FIREBASE_WEB_API_KEY`, `SEGFY_LOGIN_EMAIL`, `SEGFY_LOGIN_PASSWORD`).
  `SEGFY_AUTOMATION_TOKEN` é opcional; sem ele, o token vem do Gate (`list-by-intranet` + `SEGFY_INTRANET_ID`).
  Só o JWT do SSO no `config.token` costuma dar **401** na api.automation.
  """

  require Logger

  alias Ersventaja.Policies
  alias Ersventaja.Policies.OCR
  alias Ersventaja.Segfy.AutoPolicyExtractor
  alias Ersventaja.Segfy.BrazilianPlate
  alias Ersventaja.Segfy.EmailFix
  alias Ersventaja.Segfy.Budget
  alias Ersventaja.Segfy.Auth
  alias Ersventaja.Segfy.GestaoRenewal
  alias Ersventaja.Segfy.Vehicle

  @doc false
  def run(policy) when is_map(policy) do
    with :ok <- require_upfy_gate(),
         {:ok, match} <- find_match_gestao_or_gate(policy),
         :ok <- require_automation_token(),
         {:ok, qid, match_meta} <- resolve_quotation_id(policy, match),
         {:ok, show_resp} <- Vehicle.show(qid),
         data <- build_calculate_data(show_resp, policy, qid),
         {:ok, data} <- maybe_enrich_with_pdf_ocr(data, policy),
         {:ok, calc} <- Vehicle.calculate(data, calc_opts_from_show(show_resp)) do
      {:ok,
       %{
         quotation_id: qid,
         codigo_orcamento:
           Budget.codigo_orcamento_from_item(match_meta) ||
             match_meta["numeroApolice"],
         match: match_meta,
         calculate: calc
       }}
    end
  end

  @doc """
  Monta o payload `data` para `Vehicle.calculate/2`: tenta **match + show + OCR**;
  se falhar, usa **apenas OCR+LLM** no PDF da apólice (mesmo pipeline do upload).
  """
  def prepare_calculate_payload(policy) when is_map(policy) do
    with {:ok, match} <- find_match_gestao_or_gate(policy),
         {:ok, qid, match_meta} <- resolve_quotation_id(policy, match),
         {:ok, show_resp} <- Vehicle.show(qid),
         data <- build_calculate_data(show_resp, policy, qid),
         {:ok, data} <- maybe_enrich_with_pdf_ocr(data, policy) do
      {:ok,
       %{data: data, quotation_id: qid, match: match_meta, show_resp: show_resp, policy: policy}}
    else
      err ->
        Logger.info(
          "[Segfy Renewal] prepare_calculate_payload: listagem/show falhou (#{inspect(err)}); tentando OCR+LLM no PDF"
        )

        prepare_from_ocr_only(policy)
    end
  end

  defp prepare_from_ocr_only(policy) do
    case build_payload_from_ocr_only(policy) do
      {:ok, data} ->
        {:ok, %{data: data, quotation_id: nil, match: nil, show_resp: nil, policy: policy}}

      {:error, _} = e ->
        e
    end
  end

  defp build_payload_from_ocr_only(policy) do
    fname = policy[:file_name] || policy["file_name"]
    pid = policy[:id] || policy["id"]

    if is_binary(fname) and pid do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "segfy-q-#{pid}-#{:erlang.unique_integer([:positive])}.pdf"
        )

      try do
        with {:ok, bin} <- Policies.download_policy_file(fname),
             :ok <- File.write(tmp, bin),
             {:ok, text} <- OCR.extract_text_from_pdf(tmp),
             {:ok, extracted} <- AutoPolicyExtractor.extract_from_ocr_text(text) do
          base = minimal_calculate_skeleton()
          merged = AutoPolicyExtractor.merge_calculate_payload(base, extracted)
          merged = json_normalize(merged)
          {:ok, merged}
        else
          e -> {:error, {:ocr_payload_failed, e}}
        end
      after
        if File.exists?(tmp), do: File.rm(tmp)
      end
    else
      {:error, :policy_pdf_required_for_segfy_payload}
    end
  end

  defp minimal_calculate_skeleton do
    %{
      quotation_date: Date.utc_today() |> Date.to_iso8601(),
      commission_all: Ersventaja.Segfy.calculate_default_commission_all_integer(),
      alive_extension: "false",
      questionnaire_truck: %{},
      zip_code: "",
      validity_start: "",
      validity_end: "",
      main_driver: %{
        marital_status: "married",
        profession: "Medico",
        relationship: "himself"
      },
      vehicle: %{
        zero_km: false,
        alienated: false,
        gas_kit: false,
        armored: false,
        chassis_relabeled: false,
        anti_theft: false
      },
      questionnaire: %{
        # Segfy validate: "yes" não está na lista — alinhar ao probe (`segfy_chain_probe.py`)
        residence_garage: "yes_with_electronic_gate",
        job_garage: "yes",
        study_garage: "yes",
        utilization_type: "personal",
        other_driver: "does_not_exist",
        secondary_driver_age: " ",
        monthly_km: "300",
        work_distance: "10",
        residence_type: "house",
        tax_exemption: "not_isent"
      },
      coverage: %{
        coverage_type: "comprehensive",
        franchise: "normal",
        fipe_percentage: "100",
        assistance: "no_assistance",
        glass: "no_glass",
        rental_car: "no_car",
        rental_car_profile: "basic",
        replacement_zero_km: "no_replacement",
        material_damage: "500000.00",
        body_injuries: "500000.00",
        moral_damage: "10000.00",
        death_illness: 0,
        expense_extraordinary: 0,
        dmh: 0,
        lmi_residential: 0,
        defense_costs: 0,
        quick_repairs: false,
        body_shop_repair: false,
        exemption_franchise: false,
        selected_coverage: %{label: "Selecione", value: " "},
        description: "",
        maxpar_coverages: %{
          bodywork_and_paint: false,
          wheel_tire_and_suspension: false
        }
      }
    }
  end

  @doc false
  def calculate_opts_from_show(show_resp), do: calc_opts_from_show(show_resp)

  defp find_match_gestao_or_gate(policy) do
    if Ersventaja.Segfy.skip_gestao_html_list?() do
      Logger.debug(
        "[Segfy Renewal] skip Gestão HTML (SEGFY_SKIP_GESTAO_HTML_LIST); Upfy Gate budget/list"
      )

      try_budget_gate_match(policy)
    else
      case GestaoRenewal.list_table_rows() do
        {:ok, rows} when rows != [] ->
          Logger.info("[Segfy Renewal] fonte da lista: Gestão HTML (#{length(rows)} linha(s))")

          case Budget.find_matching_item(policy, rows) do
            {:ok, _} = ok -> ok
            {:error, _} -> try_budget_gate_match(policy)
          end

        {:ok, []} ->
          Logger.info("[Segfy Renewal] Gestão sem linhas; usando Upfy Gate")
          try_budget_gate_match(policy)

        {:error, reason} ->
          if reason == :gestao_requires_browser_session do
            Logger.debug("[Segfy Renewal] Gestão HTML 302/sessão; usando Upfy Gate")
          else
            Logger.warning(
              "[Segfy Renewal] Gestão indisponível (#{inspect(reason)}); usando Upfy Gate"
            )
          end

          try_budget_gate_match(policy)
      end
    end
  end

  defp try_budget_gate_match(policy) do
    har = Budget.list_opts_har_default()
    base = Budget.list_opts_from_policy(policy)

    har_body = Budget.build_list_request_body(har) |> Jason.encode!()
    base_body = Budget.build_list_request_body(base) |> Jason.encode!()

    case gate_try_find(policy, har) do
      {:ok, _} = ok ->
        ok

      {:error, :no_segfy_match} ->
        case maybe_gate_list_with_usuario_id(policy, har) do
          {:ok, _} = ok ->
            ok

          {:error, :no_segfy_match} ->
            r =
              if har_body == base_body do
                {:error, :no_segfy_match}
              else
                Logger.info(
                  "[Segfy Renewal] Gate sem match com POST idêntico ao HAR/fixture; tentando com search + datas da apólice"
                )

                gate_try_find(policy, inject_usuario_merge(base))
              end

            case r do
              {:ok, _} = ok ->
                ok

              {:error, :no_segfy_match} ->
                relaxed =
                  Keyword.merge(base, data_inicio: nil, data_fim: nil)
                  |> inject_usuario_merge()

                if Keyword.get(relaxed, :data_inicio) == Keyword.get(base, :data_inicio) and
                     Keyword.get(relaxed, :data_fim) == Keyword.get(base, :data_fim) do
                  finalize_gate_no_match(policy)
                else
                  Logger.info(
                    "[Segfy Renewal] Gate sem match com vigência da apólice; repetindo sem dataInicio/dataFim"
                  )

                  case gate_try_find(policy, relaxed) do
                    {:ok, _} = ok -> ok
                    {:error, :no_segfy_match} -> finalize_gate_no_match(policy)
                    {:error, _} = e -> e
                  end
                end

              {:error, _} = e ->
                e
            end

          {:error, _} = e ->
            e
        end

      {:error, _} = e ->
        e
    end
  end

  defp maybe_gate_list_with_usuario_id(policy, har) do
    har_u = inject_usuario_merge(har)

    if har_u == har do
      {:error, :no_segfy_match}
    else
      Logger.info("[Segfy Renewal] Repetindo listagem no formato HAR com usuarioId do JWT SSO")
      gate_try_find(policy, har_u)
    end
  end

  defp inject_usuario_merge(opts) do
    case Auth.budget_usuario_id_from_session() do
      id when is_integer(id) and id > 0 ->
        Keyword.put(opts, :usuario_id, id)

      _ ->
        opts
    end
  end

  defp finalize_gate_no_match(policy), do: try_vehicle_renewal_list_match(policy)

  defp try_vehicle_renewal_list_match(policy) do
    Logger.info("[Segfy Renewal] Gate sem linhas; tentando POST api/vehicle/.../renewal-list")

    case Vehicle.renewal_list() do
      {:ok, resp} ->
        if Budget.renewal_list_response_is_insurer_wizard?(resp) do
          Logger.warning(
            "[Segfy Renewal] renewal-list retornou catálogo de seguradoras (wizard), não linhas de orçamento " <>
              "(ex.: HAR inicia_renovacao: data[].mask_police/text/id); match por apólice aqui não se aplica"
          )

          {:error, :renewal_list_is_insurer_wizard_not_rows}
        else
          items = Budget.normalize_renewal_list_response(resp)
          n = length(items)

          if n == 0 do
            Logger.warning(
              "[Segfy Renewal] renewal-list normalizou 0 itens; keys=#{inspect(Map.keys(resp))}"
            )
          else
            Logger.info("[Segfy Renewal] renewal-list: #{n} item(ns)")
          end

          Budget.find_matching_item(policy, items)
        end

      {:error, _} = e ->
        Logger.warning("[Segfy Renewal] renewal-list falhou: #{inspect(e)}")
        e
    end
  end

  defp gate_try_find(policy, opts) do
    case Budget.list_all(opts) do
      {:ok, items} -> Budget.find_matching_item(policy, items)
      {:error, _} = e -> e
    end
  end

  defp resolve_quotation_id(policy, match) do
    case Budget.quotation_id_from_item(match) do
      {:ok, qid} ->
        {:ok, qid, match}

      {:error, :quotation_id_not_found} ->
        apol = apolice_digits(match)

        if apol != "" do
          Logger.info(
            "[Segfy Renewal] quotation_id via Gate search (apólice ****#{suffix_digits(apol)})"
          )

          opts = [
            search: apol,
            data_inicio: nil,
            data_fim: nil,
            page_number: 1,
            page_size: 50
          ]

          case Budget.list_page(opts) do
            {:ok, items, _} ->
              case Budget.find_matching_item(policy, items) do
                {:ok, jm} ->
                  case Budget.quotation_id_from_item(jm) do
                    {:ok, qid} -> {:ok, qid, jm}
                    {:error, _} = e -> e
                  end

                {:error, _} = e ->
                  e
              end

            {:error, _} = e ->
              e
          end
        else
          {:error, :quotation_id_not_found}
        end

      {:error, _} = e ->
        e
    end
  end

  defp apolice_digits(match) when is_map(match) do
    raw =
      match["numeroApolice"] || match["numero_apolice"] ||
        match["policy_number"] || match["policyNumber"]

    String.replace(to_string(raw || ""), ~r/[^0-9]/, "")
  end

  defp suffix_digits(s) when is_binary(s), do: String.slice(s, -4..-1//1)

  defp require_automation_token do
    case Ersventaja.Segfy.resolved_automation_token() do
      t when is_binary(t) and t != "" -> :ok
      _ -> {:error, :missing_automation_token}
    end
  end

  defp require_upfy_gate do
    if Ersventaja.Segfy.upfy_gate_configured?() do
      :ok
    else
      {:error, :missing_upfy_gate_auth}
    end
  end

  defp build_calculate_data(show_resp, policy, quotation_id) do
    raw = extract_inner_data(show_resp)

    Logger.info(
      "[Segfy Renewal] DEBUG build_calculate_data " <>
        "show_resp_keys=#{inspect(Map.keys(show_resp))} " <>
        "outer_keys=#{inspect(Map.keys(Map.get(show_resp, "data") || Map.get(show_resp, :data) || %{}))} " <>
        "raw_keys=#{inspect(Map.keys(raw))} " <>
        "raw_zip=#{inspect(raw["zip_code"] || raw[:zip_code])}"
    )

    raw
    |> json_normalize()
    |> Map.put("quotation_id", quotation_id)
    |> apply_policy_overrides_str(policy)
    |> apply_main_driver_defaults()
    |> resolve_fipe_value()
    |> ensure_vehicle_plate_for_segfy(policy, show_resp)
  end

  @doc false
  def vehicle_plate_from_show(show_resp) when is_map(show_resp) do
    inner = extract_inner_data(show_resp)
    v = Map.get(inner, "vehicle") || %{}
    Map.get(v, "plate")
  end

  def vehicle_plate_from_show(_), do: nil

  @doc false
  # Bloco `renewal` dentro do JSON interno do `POST …/show` (HAR `renovacao.har`).
  def renewal_from_show(show_resp) when is_map(show_resp) do
    inner = extract_inner_data(show_resp) |> json_normalize()
    r = Map.get(inner, "renewal") || %{}

    if is_map(r) do
      json_normalize(r)
    else
      %{}
    end
  end

  def renewal_from_show(_), do: %{}

  defp ensure_vehicle_plate_for_segfy(data, policy, show_resp) do
    veh = Map.get(data, "vehicle") || %{}
    pol_plate = policy[:license_plate] || policy["license_plate"]
    pol_detail = policy[:detail] || policy["detail"]

    plate =
      BrazilianPlate.pick_first_valid_plate([
        Map.get(veh, "plate"),
        vehicle_plate_from_show(show_resp),
        pol_plate,
        pol_detail
      ])

    if plate == "" do
      Logger.warning(
        "[Segfy Renewal] nenhuma placa BR válida (7 chars Mercosul/antiga); " <>
          "merged=#{inspect(Map.get(veh, "plate"))} show=#{inspect(vehicle_plate_from_show(show_resp))} " <>
          "policy.license_plate=#{inspect(pol_plate)} policy.detail=#{inspect(pol_detail)}"
      )
    end

    Map.put(data, "vehicle", Map.put(veh, "plate", plate))
  end

  # O show response tem data.data (aninhado): o nível externo contém {config, data},
  # o nível interno contém os campos reais (vehicle, coverage, etc.).
  defp extract_inner_data(show_resp) do
    outer = Map.get(show_resp, "data") || Map.get(show_resp, :data) || %{}

    case outer do
      %{"data" => inner} when is_map(inner) -> inner
      %{data: inner} when is_map(inner) -> inner
      # fallback: se não tem data aninhado, usa o próprio outer
      _ -> outer
    end
  end

  defp apply_main_driver_defaults(data) do
    md = Map.get(data, "main_driver") || %{}

    md =
      if blank?(md["marital_status"]),
        do: Map.put(md, "marital_status", "married"),
        else: md

    md =
      if blank?(md["profession"]),
        do: Map.put(md, "profession", "Medico"),
        else: md

    Map.put(data, "main_driver", md)
  end

  defp resolve_fipe_value(data) do
    veh = Map.get(data, "vehicle") || %{}

    case enrich_vehicle_from_segfy_model_list(veh) do
      {:ok, veh2} ->
        Map.put(data, "vehicle", veh2)

      {:error, reason} ->
        Logger.warning(
          "[Segfy Renewal] model-list falhou ao enriquecer veículo reason=#{inspect(reason)} " <>
            "fipe_value=#{inspect(veh["fipe_value"])}"
        )

        data
    end
  end

  @doc """
  Chama `model-list` (marca/ano/tipo) e alinha `vehicle.fipe_value` e **`vehicle.model`** ao item FIPE.

  O front Segfy seleciona o modelo pelo texto exato retornado em cada opção (`value`); só enviar
  `fipe_value` correto sem esse rótulo deixa o dropdown “vazio”.

  Ordem de escolha do item: `fipe_code` → nome exato → nome fuzzy → linha cujo `fipe_value` coincide
  com o já presente no veículo (ex.: veio certo do show mas `model` veio errado do OCR).
  """
  def enrich_vehicle_from_segfy_model_list(veh) when is_map(veh) do
    brand = veh["brand"]
    model_year = veh["model_year"]
    vehicle_type = veh["vehicle_type"] || "car"
    fipe_code = veh["fipe_code"]
    model_name = veh["model"]

    cond do
      blank?(brand) or is_nil(model_year) ->
        {:ok, veh}

      true ->
        params =
          %{
            "brand" => brand,
            "model_year" => model_year,
            "vehicle_type" => vehicle_type
          }
          |> maybe_put_model_list_brand_id(veh)

        Logger.info(
          "[Segfy Renewal] model-list request brand=#{inspect(brand)} model_year=#{inspect(model_year)} " <>
            "vehicle_type=#{inspect(vehicle_type)} brand_id?=#{params["brand_id"] != nil} " <>
            "fipe_code=#{inspect(fipe_code)} model=#{inspect(truncate_model_name(model_name))}"
        )

        case Vehicle.model_list(params) do
          {:ok, resp} ->
            models = model_list_extract_models(resp)
            n = length(models)

            Logger.info(
              "[Segfy Renewal] model-list OK models_count=#{n} resp_keys=#{inspect(Map.keys(resp))} " <>
                "sample=#{inspect(model_list_sample_for_log(models, 4))}"
            )

            match = find_fipe_model(models, fipe_code, model_name, veh["fipe_value"])

            case match do
              nil ->
                if not valid_fipe_value?(veh["fipe_value"]) do
                  Logger.warning(
                    "[Segfy Renewal] model-list sem match para FIPE fipe_code=#{inspect(fipe_code)} " <>
                      "model=#{inspect(truncate_model_name(model_name))} fipe_value=#{inspect(veh["fipe_value"])} " <>
                      "models_count=#{n}"
                  )
                end

                {:ok, veh}

              m ->
                veh2 = apply_model_list_match_to_vehicle(veh, m)
                label = veh2["model"]

                Logger.info(
                  "[Segfy Renewal] model-list aplicado fipe_value=#{inspect(veh2["fipe_value"])} " <>
                    "model=#{inspect(truncate_model_name(label))}"
                )

                {:ok, veh2}
            end

          {:error, reason} = e ->
            Logger.warning("[Segfy Renewal] model-list HTTP/erro reason=#{inspect(reason)}")
            e
        end
    end
  end

  def enrich_vehicle_from_segfy_model_list(_), do: {:error, :invalid_vehicle}

  @doc false
  # Retorno para chamadas legadas que só precisam de fipe + modelo após enriquecimento.
  def lookup_fipe_value_from_vehicle(veh) when is_map(veh) do
    case enrich_vehicle_from_segfy_model_list(veh) do
      {:ok, v} ->
        {:ok, %{fipe_value: v["fipe_value"], model: v["model"]}}

      {:error, _} = e ->
        e
    end
  end

  def lookup_fipe_value_from_vehicle(_), do: {:error, :invalid_vehicle}

  defp valid_fipe_value?(v) when is_number(v) and v > 100, do: true

  defp valid_fipe_value?(v) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n > 100
      :error -> false
    end
  end

  defp valid_fipe_value?(_), do: false

  defp maybe_put_model_list_brand_id(params, veh) do
    bid = veh["brand_id"] || veh[:brand_id]

    if is_binary(bid) and String.trim(bid) != "" do
      Map.put(params, "brand_id", String.trim(bid))
    else
      params
    end
  end

  defp apply_model_list_match_to_vehicle(veh, m) when is_map(m) do
    label = model_label_from_match(m)
    df = model_data_fipe(m)
    api_fipe_code = Map.get(df, "fipe_code") || Map.get(df, "FipeCode") || Map.get(m, "fipe_code")

    apply_fipe_code = fn v ->
      if is_binary(api_fipe_code) and api_fipe_code != "",
        do: Map.put(v, "fipe_code", api_fipe_code),
        else: v
    end

    apply_label = fn v ->
      if label != "", do: Map.put(v, "model", label), else: v
    end

    case fipe_value_from_model(m) do
      {:ok, fv} when is_integer(fv) and fv > 0 ->
        veh
        |> Map.put("fipe_value", fv)
        |> apply_label.()
        |> apply_fipe_code.()

      {:error, :bad_fipe_value_string, v} ->
        Logger.warning(
          "[Segfy Renewal] fipe model encontrado mas fipe_value string inválida: #{inspect(v)} " <>
            "model_label=#{inspect(truncate_model_name(label))}"
        )

        veh |> apply_label.() |> apply_fipe_code.()

      _ ->
        veh |> apply_label.() |> apply_fipe_code.()
    end
  end

  defp model_label_from_match(m) when is_map(m) do
    (m["value"] || m["Value"] || "") |> to_string() |> String.trim()
  end

  defp find_model_by_fipe_value_number(models, veh_fipe) do
    case normalize_vehicle_fipe_number(veh_fipe) do
      nil ->
        nil

      target ->
        Enum.find(models, fn m ->
          case fipe_value_from_model(m) do
            {:ok, fv} -> fv == target
            _ -> false
          end
        end)
    end
  end

  defp normalize_vehicle_fipe_number(v) when is_number(v) and v > 100, do: round(v)

  defp normalize_vehicle_fipe_number(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {n, _} when n > 100 -> round(n)
      _ -> nil
    end
  end

  defp normalize_vehicle_fipe_number(_), do: nil

  defp truncate_model_name(nil), do: nil

  defp truncate_model_name(name) when is_binary(name) do
    if String.length(name) > 80, do: binary_part(name, 0, 80) <> "…", else: name
  end

  defp truncate_model_name(name), do: name

  defp model_list_extract_models(resp) when is_map(resp) do
    candidates = [
      get_in(resp, ["data", "models"]),
      get_in(resp, ["data", "Models"]),
      get_in(resp, ["Data", "models"]),
      get_in(resp, ["Data", "Models"]),
      get_in(resp, ["result", "data", "models"]),
      get_in(resp, ["result", "Data", "Models"])
    ]

    case Enum.find(candidates, &is_list/1) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp model_list_sample_for_log(models, limit) when is_list(models) do
    models
    |> Enum.take(limit)
    |> Enum.map(fn m ->
      %{
        value: truncate_model_name(m["value"] || m["Value"]),
        fipe_code: get_in(m, ["data_fipe", "fipe_code"]) || get_in(m, ["DataFipe", "FipeCode"]),
        fipe_value: get_in(m, ["data_fipe", "fipe_value"]) || get_in(m, ["DataFipe", "FipeValue"])
      }
    end)
  end

  defp model_data_fipe(m) when is_map(m) do
    Map.get(m, "data_fipe") || Map.get(m, "DataFipe") || %{}
  end

  defp fipe_value_from_model(nil), do: :no_match

  defp fipe_value_from_model(m) when is_map(m) do
    df = model_data_fipe(m)
    v = Map.get(df, "fipe_value") || Map.get(df, "FipeValue")

    cond do
      is_number(v) and v > 0 ->
        {:ok, round(v)}

      is_binary(v) ->
        case Float.parse(String.trim(v)) do
          {n, _} when n > 100 -> {:ok, round(n)}
          _ -> {:error, :bad_fipe_value_string, v}
        end

      true ->
        :no_match
    end
  end

  defp find_fipe_model(models, fipe_code, model_name, veh_fipe_value) do
    # Primeiro tenta match por fipe_code (API pode vir "002168-7" vs OCR "21733" — só dígitos)
    by_code =
      if not blank?(fipe_code) do
        Enum.find(models, fn m ->
          df = model_data_fipe(m)
          api_code = Map.get(df, "fipe_code") || Map.get(df, "FipeCode")
          fipe_codes_equivalent?(api_code, fipe_code)
        end)
      end

    by_code ||
      if not blank?(model_name) do
        find_model_by_name_exact(models, model_name) ||
          find_model_by_name_fuzzy(models, model_name)
      end ||
      find_model_by_fipe_value_number(models, veh_fipe_value)
  end

  defp find_model_by_name_exact(models, model_name) do
    normalized = String.downcase(String.trim(model_name))

    Enum.find(models, fn m ->
      v = m["value"] || m["Value"] || ""
      String.downcase(String.trim(to_string(v))) == normalized
    end)
  end

  defp find_model_by_name_fuzzy(models, model_name) when is_binary(model_name) do
    w = normalize_vehicle_model_label(model_name)

    if w == "" do
      nil
    else
      Enum.find(models, fn m ->
        v = m["value"] || m["Value"] || ""
        api = normalize_vehicle_model_label(to_string(v))
        api != "" and (api == w or String.contains?(api, w) or String.contains?(w, api))
      end)
    end
  end

  defp find_model_by_name_fuzzy(_, _), do: nil

  # Compara rótulos para OCR vs lista FIPE (espaços, pontuação, caixa).
  defp normalize_vehicle_model_label(s) when is_binary(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[\s._\-\/]+/u, " ")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp fipe_codes_equivalent?(a, b) when is_binary(a) and is_binary(b) do
    da = fipe_code_digits(a)
    db = fipe_code_digits(b)

    cond do
      da == "" or db == "" -> false
      da == db -> true
      fipe_digits_stripped_equal?(da, db) -> true
      fipe_digits_substring_match?(da, db) -> true
      true -> false
    end
  end

  defp fipe_codes_equivalent?(a, b), do: a == b

  # OCR "21733" vs API "002173-3" → dígitos "21733" e "0021733" → sem zeros à esquerda iguais.
  defp fipe_digits_stripped_equal?(da, db) do
    sa = String.trim_leading(da, "0")
    sb = String.trim_leading(db, "0")
    sa != "" and sa == sb
  end

  # Fallback: código parcial do PDF contido no código completo (mín. 5 dígitos no menor).
  defp fipe_digits_substring_match?(da, db) do
    {short, long} =
      if String.length(da) <= String.length(db), do: {da, db}, else: {db, da}

    String.length(short) >= 5 and String.contains?(long, short)
  end

  defp fipe_code_digits(code) when is_binary(code) do
    String.replace(code, ~r/[^0-9]/, "")
  end

  defp fipe_code_digits(_), do: ""

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp json_normalize(map) when is_map(map) do
    Jason.decode!(Jason.encode!(map))
  end

  defp apply_policy_overrides_str(data, policy) do
    data
    |> merge_section_str("customer", customer_str(policy))
    |> merge_section_str("main_driver", main_driver_str(policy))
    |> merge_section_str("vehicle", vehicle_str(policy))
  end

  defp merge_section_str(data, _key, extra) when map_size(extra) == 0, do: data

  defp merge_section_str(data, key, extra) when is_map(extra) do
    prev = Map.get(data, key) || %{}
    Map.put(data, key, deep_merge_nonempty(prev, json_normalize(extra)))
  end

  defp deep_merge_nonempty(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _k, va, vb ->
      cond do
        is_map(va) and is_map(vb) -> deep_merge_nonempty(va, vb)
        is_nil(vb) or vb == "" -> va
        true -> vb
      end
    end)
  end

  defp deep_merge_nonempty(a, b), do: Map.merge(a, b)

  defp customer_str(policy) do
    m = %{}

    m =
      case present(policy[:customer_name] || policy["customer_name"]) do
        nil -> m
        n -> Map.put(m, "name", n)
      end

    m =
      case digits(policy[:customer_cpf_or_cnpj] || policy["customer_cpf_or_cnpj"]) do
        nil -> m
        "" -> m
        d -> Map.put(m, "document", d)
      end

    m =
      case present(policy[:customer_phone] || policy["customer_phone"]) do
        nil -> m
        t -> Map.put(m, "cellphone", t)
      end

    m =
      case policy[:customer_email] || policy["customer_email"] do
        nil ->
          m

        "" ->
          m

        e ->
          raw = to_string(e)
          fixed = EmailFix.fix_ocr_email(raw)
          em = if(fixed != "", do: fixed, else: raw)
          Map.put(m, "email", String.upcase(em))
      end

    m
  end

  defp main_driver_str(policy) do
    m = %{}

    m =
      case present(policy[:customer_name] || policy["customer_name"]) do
        nil -> m
        n -> Map.put(m, "name", n)
      end

    case digits(policy[:customer_cpf_or_cnpj] || policy["customer_cpf_or_cnpj"]) do
      nil -> m
      "" -> m
      d -> Map.put(m, "document", d)
    end
  end

  defp vehicle_str(policy) do
    case policy[:license_plate] || policy["license_plate"] do
      nil ->
        %{}

      "" ->
        %{}

      pl ->
        case BrazilianPlate.normalize(to_string(pl)) do
          {:ok, p} -> %{"plate" => p}
          :error -> %{}
        end
    end
  end

  defp present(nil), do: nil
  defp present(s) when is_binary(s) and s != "", do: String.upcase(String.trim(s))
  defp present(s), do: s

  defp digits(nil), do: nil
  defp digits(s), do: String.replace(to_string(s), ~r/[^0-9]/, "")

  defp maybe_enrich_with_pdf_ocr(data, policy) do
    fname = policy[:file_name] || policy["file_name"]
    pid = policy[:id] || policy["id"]

    if is_binary(fname) and pid do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "segfy-renewal-#{pid}-#{:erlang.unique_integer([:positive])}.pdf"
        )

      try do
        result =
          with {:ok, bin} <- Policies.download_policy_file(fname),
               :ok <- File.write(tmp, bin),
               {:ok, text} <- OCR.extract_text_from_pdf(tmp),
               {:ok, extracted} <- AutoPolicyExtractor.extract_from_ocr_text(text) do
            merged = deep_merge_nonempty(json_normalize(data), json_normalize(extracted))
            {:ok, merged}
          else
            err ->
              Logger.info("[Segfy Renewal] OCR/GPT opcional ignorado: #{inspect(err)}")
              {:ok, data}
          end

        result
      after
        if File.exists?(tmp), do: File.rm(tmp)
      end
    else
      {:ok, data}
    end
  end

  defp calc_opts_from_show(show_resp) do
    cfg =
      get_in(show_resp, ["data", "config"]) ||
        get_in(show_resp, ["config"]) ||
        Map.get(show_resp, :config) ||
        %{}

    insurers = normalize_insurers_for_calculate(cfg)

    callback =
      get_in(cfg, ["callback"]) || Map.get(cfg, :callback) ||
        get_in(show_resp, ["config", "callback"])

    merged = %{}
    merged = if insurers != [], do: Map.put(merged, :insurers, insurers), else: merged

    merged =
      if is_binary(callback) and callback != "",
        do: Map.put(merged, :callback, callback),
        else: merged

    merged = json_normalize(merged)

    if merged == %{} do
      []
    else
      [config: merged]
    end
  end

  defp normalize_insurers_for_calculate(cfg) do
    ins = Map.get(cfg, "insurers") || Map.get(cfg, :insurers) || []

    List.wrap(ins)
    |> Enum.flat_map(fn
      %{"company" => %{"name" => n, "commission" => c}} when is_binary(n) and n != "" ->
        [%{name: n, commission: round_commission(c)}]

      %{company: %{name: n, commission: c}} when is_binary(n) and n != "" ->
        [%{name: n, commission: round_commission(c)}]

      %{"name" => n, "commission" => c} when is_binary(n) and n != "" ->
        [%{name: n, commission: round_commission(c)}]

      %{name: n, commission: c} when is_binary(n) and n != "" ->
        [%{name: n, commission: round_commission(c)}]

      _ ->
        []
    end)
  end

  defp round_commission(c) when is_float(c) do
    r = round(c)
    if r > 0, do: r, else: Ersventaja.Segfy.calculate_default_commission_percent()
  end

  defp round_commission(c) when is_integer(c) do
    if c > 0, do: c, else: Ersventaja.Segfy.calculate_default_commission_percent()
  end

  defp round_commission(c) when is_binary(c) do
    case Integer.parse(String.trim(c)) do
      {i, _} when i > 0 -> i
      _ -> Ersventaja.Segfy.calculate_default_commission_percent()
    end
  end

  defp round_commission(_), do: Ersventaja.Segfy.calculate_default_commission_percent()
end
