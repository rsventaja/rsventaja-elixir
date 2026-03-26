defmodule Ersventaja.Segfy.Quotation do
  @moduledoc """
  Fluxo espelhado em `scripts/segfy_chain_probe.py` (benchmark):

  1. Cookie gate + **vuex** (`auth/login`) e sessão Gestão (Prosseguir).
  2. `POST …/vehicle/.../calculate` com **RENOVATION** e **NEW_QUOTATION** — `config.token` = token **opaco** do perfil
     (`list-by-intranet`), Bearer = JWT de `/auths/token` (nunca inverter).
  3. `GET …/HfyAuto?cod=…` + `SalvaCotacaoAutomation?token=<opaco>` com o mesmo cookie.

  Link para o usuário: `https://app.segfy.com/multicalculo/hfy-auto?q=<cod>`.

  Payload: **listagem Segfy + show + OCR/LLM** ou só **OCR+LLM** no PDF (`Renewal.prepare_calculate_payload/1`).
  """

  require Logger

  alias Ersventaja.Segfy

  alias Ersventaja.Segfy.{
    Auth,
    BrazilianPlate,
    Budget,
    EmailFix,
    Gestao,
    MulticalculoSocket,
    Renewal,
    Vehicle
  }

  @app_multicalculo "https://app.segfy.com/multicalculo/hfy-auto?q="

  # Logs `[Segfy PAYLOAD_DUMP]` — JSON truncado para você colar e mapearmos respostas (valores por seguradora etc.).
  @payload_dump_json_max 28_000

  @redact_log_keys MapSet.new(~w(
    token idtoken access_token refresh_token password authorization
  ))

  defp default_insurers do
    p = Segfy.calculate_default_commission_percent()

    for name <- ~w(porto azul itau mitsui bllu), do: %{name: name, commission: p}
  end

  @doc """
  Gera cotação de **renovação** no Segfy e devolve o link `app.segfy.com/.../hfy-auto?q=`.

  Fluxo (espelha o browser — HAR `renovacao_contrato.har`):
  1. OCR+LLM extrai dados da apólice/PDF
  2. `POST calculate` (RENOVATION) → `quotation_id`
  3. `POST SalvaCotacaoAutomation` com `codigoOrcamento=""` → gera e retorna o `cod`
  4. `POST SalvaCotacaoAutomation` com `codigoOrcamento=<cod>` → persiste

  O código de NEW_QUOTATION permanece disponível em `calculate_and_save/5` para uso futuro.
  """
  def run(policy) when is_map(policy) do
    with :ok <- require_upfy_gate(),
         :ok <- require_automation_token(),
         {:ok, cookie} <- Auth.gate_cookie(),
         {:ok, payload} <- Renewal.prepare_calculate_payload(policy),
         {:ok, token} <- opaque_token(),
         {:ok, renovation} <- calculate_and_save(payload, "", token, cookie, :renovation),
         {:ok, cod} <- extract_cod_from_save(renovation),
         {:ok, _} <- save_with_cod(renovation, cod, token, cookie) do
      ren_qid = quotation_id_from_segfy_step(renovation)

      out = %{
        cod: cod,
        quotation_url: @app_multicalculo <> cod,
        renovation: renovation,
        renovation_quotation_id: ren_qid
      }

      Logger.info(
        "[Segfy Quotation] run/1 concluído: RENOVATION " <>
          "cod=#{cod} | quotation_id=#{inspect(ren_qid)}"
      )

      {:ok, out}
    end
  end

  # O primeiro SalvaCotacaoAutomation (codigoOrcamento="") retorna o cod como string JSON.
  defp extract_cod_from_save(%{save: cod}) when is_binary(cod) and cod != "" do
    # Response pode vir com aspas: "\"69c4100d...\""
    clean = String.trim(cod, "\"")

    if Regex.match?(~r/^[a-fA-F0-9]+$/, clean) do
      {:ok, String.downcase(clean)}
    else
      Logger.warning("[Segfy Quotation] SalvaCotacao retornou valor inesperado: #{inspect(cod)}")
      {:error, :unexpected_cod_format}
    end
  end

  defp extract_cod_from_save(_), do: {:error, :no_cod_from_save}

  # Segundo save com o cod real para persistir no Gestão.
  defp save_with_cod(%{calculate: calc_resp} = ren, cod, token, cookie) when is_binary(cod) do
    save_cookie =
      case Gestao.warm_hfy_auto_session(cod, cookie) do
        {:ok, merged} when is_binary(merged) and merged != "" -> merged
        _ -> cookie
      end

    request_data = Map.get(ren, :request_data, %{})
    request_config = Map.get(ren, :request_config, %{})
    server_qid = quotation_id_from_calculate_response(calc_resp, request_data)

    {body_data, body_cfg} = save_body_maps(calc_resp, request_data, request_config)
    body_cfg_salva = nest_insurers_for_gestao_salva(body_cfg)
    body_data_salva = Map.delete(body_data, "commission_all")

    body = %{
      "quotation_id" => server_qid,
      "token" => token,
      "data" => body_data_salva,
      "config" => body_cfg_salva,
      "tipo_multicalculo" => "Auto"
    }

    case Gestao.salva_cotacao_automation(cod, token, body, cookie: save_cookie) do
      {:ok, _} = ok ->
        Logger.info("[Segfy Quotation] SalvaCotacao com cod=#{cod} OK")
        ok

      {:error, reason} ->
        Logger.warning("[Segfy Quotation] SalvaCotacao com cod=#{cod} falhou: #{inspect(reason)}")
        {:error, {:salva_with_cod_failed, reason}}
    end
  end

  # Resultado de `calculate_and_save` → UUID no `calculate` (api.automation). O `with` já desembrulha `{:ok, map}`.
  defp quotation_id_from_segfy_step(%{calculate: calc}) when is_map(calc) do
    quotation_id_from_calculate_response(calc, %{})
  end

  defp quotation_id_from_segfy_step({:ok, %{calculate: calc}}) when is_map(calc) do
    quotation_id_from_calculate_response(calc, %{})
  end

  defp quotation_id_from_segfy_step(_), do: nil

  defp calculate_mode_human(:renovation), do: "passo 1/2 — renovação RENOVAÇÃO"
  defp calculate_mode_human(:new_quotation), do: "passo 2/2 — novo orçamento NEW_QUOTATION"
  defp calculate_mode_human(other), do: "modo #{inspect(other)}"

  defp require_upfy_gate do
    if Ersventaja.Segfy.upfy_gate_configured?(), do: :ok, else: {:error, :missing_upfy_gate_auth}
  end

  defp require_automation_token do
    case Ersventaja.Segfy.resolved_automation_token() do
      t when is_binary(t) and t != "" -> :ok
      _ -> {:error, :missing_automation_token}
    end
  end

  defp opaque_token do
    case Ersventaja.Segfy.resolved_automation_token() do
      t when is_binary(t) and t != "" -> {:ok, t}
      _ -> {:error, :missing_automation_token}
    end
  end

  defp calculate_and_save(payload, cod, token, cookie, mode) do
    data =
      payload.data
      |> json_normalize()
      |> Map.put("quotation_id", Ecto.UUID.generate())
      |> apply_renewal_mode(mode)
      |> apply_calculate_defaults(payload)

    cov = data["coverage"] || %{}
    veh = data["vehicle"] || %{}

    Logger.info(
      "[Segfy Quotation] DEBUG calculate_and_save mode=#{mode} " <>
        "data_keys=#{inspect(Map.keys(data))} " <>
        "commission_all=#{inspect(data["commission_all"])} " <>
        "zip_code=#{inspect(data["zip_code"])} " <>
        "validity_start=#{inspect(data["validity_start"])} " <>
        "vehicle.fipe_value=#{inspect(veh["fipe_value"])} vehicle.brand_id=#{inspect(veh["brand_id"])} " <>
        "vehicle.zero_km=#{inspect(veh["zero_km"])} " <>
        "renewal.insurer=#{inspect((data["renewal"] || %{})["insurer"])} " <>
        "main_driver.marital_status=#{inspect((data["main_driver"] || %{})["marital_status"])} " <>
        "coverage.coverage_type=#{inspect(cov["coverage_type"])} " <>
        "coverage.franchise=#{inspect(cov["franchise"])} coverage.glass=#{inspect(cov["glass"])} " <>
        "coverage.rental_car=#{inspect(cov["rental_car"])} coverage.assistance=#{inspect(cov["assistance"])} " <>
        "coverage.material_damage=#{inspect(cov["material_damage"])} " <>
        "coverage.body_injuries=#{inspect(cov["body_injuries"])} " <>
        "coverage.moral_damage=#{inspect(cov["moral_damage"])} " <>
        "coverage.fipe_percentage=#{inspect(cov["fipe_percentage"])} " <>
        "vehicle.fipe_code=#{inspect(veh["fipe_code"])} " <>
        "vehicle.model_year=#{inspect(veh["model_year"])} (#{if is_binary(veh["model_year"]), do: "string", else: "non-string"}) " <>
        "questionnaire.residence_garage=#{inspect((data["questionnaire"] || %{})["residence_garage"])}"
    )

    callback = Ecto.UUID.generate()
    opts = vehicle_opts(payload, token, callback)
    calculate_request_config = Keyword.get(opts, :config, %{})

    log_har_compare_calculate_request(data, calculate_request_config, mode, cod)

    {calc_out, multicalculo_socket_results} =
      MulticalculoSocket.collect_during_calculate(callback, fn ->
        Vehicle.calculate(data, opts)
      end)

    multicalculo_socket_results = List.wrap(multicalculo_socket_results)

    if multicalculo_socket_results != [] do
      Logger.info(
        "[Segfy Quotation] multicalculo_socket eventos=#{length(multicalculo_socket_results)} mode=#{mode}"
      )
    end

    case calc_out do
      {:ok, calc_resp} ->
        status = calc_resp["status"] || calc_resp[:status] || calc_resp["Status"]
        st = normalize_calculate_status(status)
        qid = quotation_id_from_calculate_response(calc_resp, data)

        log_har_compare_calculate_response_config(calc_resp, st)
        log_payload_dump_calculate_response(calc_resp, mode)

        cond do
          st == "OK" ->
            save_after_calculate(
              calc_resp,
              qid,
              cod,
              token,
              cookie,
              mode,
              :ok,
              data,
              calculate_request_config,
              multicalculo_socket_results
            )

          st == "VALIDACAO" ->
            validations = first_validations(calc_resp)
            cov = data["coverage"] || %{}
            veh = data["vehicle"] || %{}

            Logger.warning(
              "[Segfy Quotation] calculate status=VALIDACAO mode=#{mode} — " <>
                "cotação NÃO criada no servidor; não tenta salvar (mesmo comportamento do probe Python). " <>
                "validations=#{inspect(validations)} " <>
                "msg=#{inspect(first_msg(calc_resp))} errors=#{inspect(first_errors(calc_resp))} " <>
                "resp_top_keys=#{inspect(Map.keys(calc_resp))}"
            )

            Logger.warning(
              "[Segfy Quotation] VALIDACAO payload enviado (trecho) insurer=#{inspect((data["renewal"] || %{})["insurer"])} " <>
                "franchise=#{inspect(cov["franchise"])} glass=#{inspect(cov["glass"])} " <>
                "rental_car=#{inspect(cov["rental_car"])} assistance=#{inspect(cov["assistance"])} " <>
                "coverage_type=#{inspect(cov["coverage_type"])} fipe_value=#{inspect(veh["fipe_value"])} " <>
                "config.insurers_count=#{inspect(insurers_count_from_opts(opts))}"
            )

            {:error, {:calculate_validation, mode, validations}}

          true ->
            snippet =
              calc_resp
              |> Jason.encode!()
              |> truncate_json(900)

            Logger.warning(
              "[Segfy Quotation] calculate status=#{inspect(status)} mode=#{mode} " <>
                "msg=#{inspect(first_msg(calc_resp))} errors=#{inspect(first_errors(calc_resp))} " <>
                "data_keys=#{inspect(data_section_keys(calc_resp))} body_snippet=#{snippet}"
            )

            {:error, {:calculate_not_ok, mode, status, first_msg(calc_resp)}}
        end

      {:error, reason} ->
        {:error, {:calculate_failed, mode, reason}}
    end
  end

  defp insurers_count_from_opts(opts) when is_list(opts) do
    cfg = Keyword.get(opts, :config) || %{}
    ins = Map.get(cfg, :insurers) || Map.get(cfg, "insurers") || []
    length(List.wrap(ins))
  end

  defp insurers_count_from_opts(_), do: 0

  defp vehicle_opts(%{show_resp: nil}, token, callback) when is_binary(callback) do
    [
      config: %{
        token: token,
        callback: callback,
        insurers: default_insurers()
      }
    ]
  end

  defp vehicle_opts(%{show_resp: sr}, token, callback) when is_binary(callback) do
    extra = Renewal.calculate_opts_from_show(sr)

    base_cfg =
      case extra do
        [config: c] when is_map(c) -> c
        _ -> %{insurers: default_insurers()}
      end

    merged =
      base_cfg
      |> Map.merge(%{
        token: token,
        callback: callback
      })

    merged =
      if blank_insurers?(merged) do
        Map.put(merged, :insurers, default_insurers())
      else
        merged
      end

    merged = Map.put(merged, :insurers, normalize_insurers_commission_for_calculate(merged))

    [config: merged]
  end

  # Show pode devolver `commission: 0`; o front exige percentual válido — alinha a `commission_all`.
  defp normalize_insurers_commission_for_calculate(cfg) when is_map(cfg) do
    ins = Map.get(cfg, :insurers) || Map.get(cfg, "insurers") || []
    pct = Segfy.calculate_default_commission_percent()

    mapped =
      ins
      |> List.wrap()
      |> Enum.flat_map(fn m ->
        case Map.get(m, :name) || Map.get(m, "name") do
          n when is_binary(n) and n != "" -> [%{name: n, commission: pct}]
          _ -> []
        end
      end)

    if mapped == [], do: default_insurers(), else: mapped
  end

  defp blank_insurers?(cfg) do
    ins = Map.get(cfg, :insurers) || Map.get(cfg, "insurers") || []
    ins == []
  end

  defp apply_renewal_mode(data, :renovation) do
    data = json_normalize(data)
    r = Map.get(data, "renewal") || %{}
    r = json_normalize(r) |> Map.put("quotation_type", "RENOVATION")
    Map.put(data, "renewal", r)
  end

  defp apply_renewal_mode(data, :new_quotation) do
    data = json_normalize(data)
    r0 = Map.get(data, "renewal") || %{}
    r0 = json_normalize(r0)
    prior_ic = Map.get(r0, "prior_ic") || ""

    r = %{
      "quotation_type" => "NEW_QUOTATION",
      "insurer" => "new",
      "prior_policy" => "",
      "claim_amount" => "",
      "prior_policy_end" => "",
      "bonus_current" => " ",
      "prior_ic" => prior_ic,
      "bonus_last" => " ",
      "codigo_sucursal" => ""
    }

    Map.put(data, "renewal", r)
  end

  # Garante que todos os campos obrigatórios do calculate tenham valores válidos.
  # Atua como safety net final, independente de o payload vir do show ou do OCR-only.
  defp apply_calculate_defaults(data, payload) do
    data
    |> ensure_commission_all_default()
    |> ensure_zip_code(payload)
    |> ensure_validity_dates(payload)
    |> ensure_vehicle_defaults(payload)
    |> ensure_vehicle_plate_for_calculate(payload)
    |> ensure_main_driver_defaults()
    |> ensure_questionnaire_defaults()
    |> ensure_coverage_defaults()
    |> ensure_renewal_defaults(payload)
    |> fix_customer_emails_for_segfy()
    |> sanitize_calculate_like_har()
  end

  # Pós-LLM: corrige @ perdido por OCR (|QGMAIL etc.) — alinhado ao prompt do AutoPolicyExtractor.
  defp fix_customer_emails_for_segfy(data) when is_map(data) do
    data
    |> Map.update("customer", %{}, &fix_section_email/1)
    |> Map.update("main_driver", %{}, &fix_section_email/1)
  end

  defp fix_section_email(m) when is_map(m) do
    case Map.get(m, "email") do
      e when is_binary(e) and e != "" ->
        fixed = EmailFix.fix_ocr_email(e)
        out = if fixed != "", do: String.upcase(fixed), else: e
        Map.put(m, "email", out)

      _ ->
        m
    end
  end

  defp fix_section_email(m), do: m

  # Referência: HARs `novo_orcamento.har` / `renovacao.har` (Chrome) — POST calculate na api.automation.
  # OCR/show podem trazer texto em português nos enums; a API só aceita slugs tipo `comprehensive`.
  @har_coverage_enum_defaults %{
    "coverage_type" => "comprehensive",
    "franchise" => "normal",
    "assistance" => "assistance_no_limit_unattached",
    "glass" => "glass_total_referenced",
    "rental_car" => "rental_car_30_days_referenced",
    "rental_car_profile" => "basic",
    "replacement_zero_km" => "no_replacement",
    "fipe_percentage" => "100"
  }

  defp sanitize_calculate_like_har(data) when is_map(data) do
    q = Map.get(data, "questionnaire") || %{}
    c = Map.get(data, "coverage") || %{}
    v = Map.get(data, "vehicle") || %{}

    data
    |> Map.put("questionnaire", sanitize_questionnaire_har(q))
    |> Map.put("coverage", sanitize_coverage_enums_har(c))
    |> Map.put("vehicle", sanitize_vehicle_booleans_har(v))
  end

  defp sanitize_questionnaire_har(q) when is_map(q) do
    q
    |> Map.put("residence_garage", coerce_residence_garage_har(Map.get(q, "residence_garage")))
    |> Map.put("job_garage", coerce_yes_no_garage_har(Map.get(q, "job_garage")))
    |> Map.put("study_garage", coerce_yes_no_garage_har(Map.get(q, "study_garage")))
  end

  defp sanitize_questionnaire_har(_), do: %{}

  defp coerce_residence_garage_har(v) do
    v = if is_binary(v), do: String.trim(v), else: v

    cond do
      v == "yes_with_electronic_gate" -> v
      v == "yes_without_electronic_gate" -> v
      is_binary(v) and segfy_slug_like?(v) and String.length(v) >= 12 -> v
      true -> "yes_with_electronic_gate"
    end
  end

  defp coerce_yes_no_garage_har(v) do
    v = if is_binary(v), do: String.trim(v), else: v

    cond do
      v in [nil, ""] -> "yes"
      v == "yes" -> "yes"
      v == "no" -> "no"
      is_binary(v) and segfy_slug_like?(v) and String.length(v) <= 24 -> v
      true -> "yes"
    end
  end

  defp sanitize_coverage_enums_har(c) when is_map(c) do
    {out, changes} =
      Enum.reduce(@har_coverage_enum_defaults, {c, []}, fn {key, har_default}, {acc, chg} ->
        cur = Map.get(acc, key)

        if coverage_field_valid_for_calculate?(key, cur) do
          {acc, chg}
        else
          {Map.put(acc, key, har_default), [{key, cur, har_default} | chg]}
        end
      end)

    if changes != [] do
      Logger.info(
        "[Segfy Quotation] sanitize coverage: substituídos (campo antigo → HAR) " <>
          "#{inspect(Enum.reverse(changes), limit: :infinity)}"
      )
    end

    # HAR envia fipe_percentage como "100", não "100.00"
    out = normalize_fipe_percentage(out)
    # HAR envia monetários como strings "500000.00" — normalizar números/strings vindos do LLM
    out = normalize_coverage_monetary(out)
    out |> ensure_franchise_non_blank()
  end

  @coverage_monetary_keys ~w(material_damage body_injuries moral_damage)

  defp normalize_coverage_monetary(c) when is_map(c) do
    Enum.reduce(@coverage_monetary_keys, c, fn key, acc ->
      case Map.get(acc, key) do
        v when is_number(v) ->
          Map.put(acc, key, :erlang.float_to_binary(v / 1, decimals: 2))

        v when is_binary(v) ->
          case Float.parse(String.trim(v)) do
            {n, _} -> Map.put(acc, key, :erlang.float_to_binary(n, decimals: 2))
            :error -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp normalize_fipe_percentage(c) when is_map(c) do
    case Map.get(c, "fipe_percentage") do
      v when is_binary(v) ->
        case Float.parse(String.trim(v)) do
          {n, _} -> Map.put(c, "fipe_percentage", Integer.to_string(round(n)))
          :error -> c
        end

      v when is_number(v) ->
        Map.put(c, "fipe_percentage", Integer.to_string(round(v)))

      _ ->
        c
    end
  end

  defp sanitize_coverage_enums_har(_), do: %{}

  # Show/Porto pode trazer franchise/glass/rental_car como valores monetários ("3400.00") —
  # a API multicálculo espera **slugs** (HAR). Só `fipe_percentage` aceita número como string.
  defp coverage_field_valid_for_calculate?("fipe_percentage", v),
    do: coverage_fipe_percentage_valid?(v)

  defp coverage_field_valid_for_calculate?(_key, v) when is_number(v), do: false

  # O show/Porto às vezes manda slugs “genéricos” (`unlimited`) que passam em `segfy_slug_like?/1`
  # mas **não** estão na lista da api.automation → VALIDACAO "não está incluído na lista".
  defp coverage_field_valid_for_calculate?("assistance", v) when is_binary(v) do
    s = String.trim(v)
    s != "" and String.starts_with?(s, "assistance_")
  end

  defp coverage_field_valid_for_calculate?("glass", v) when is_binary(v) do
    s = String.trim(v)
    s != "" and String.starts_with?(s, "glass_")
  end

  defp coverage_field_valid_for_calculate?("rental_car", v) when is_binary(v) do
    s = String.trim(v)
    s != "" and String.starts_with?(s, "rental_car_")
  end

  defp coverage_field_valid_for_calculate?(_key, v) when is_binary(v) do
    s = String.trim(v)
    s != "" and segfy_slug_like?(s)
  end

  defp coverage_field_valid_for_calculate?(_key, _v), do: false

  defp coverage_fipe_percentage_valid?(v) when is_binary(v) do
    s = String.trim(v)

    cond do
      s == "" -> false
      segfy_slug_like?(s) -> true
      String.match?(s, ~r/\A[0-9]+(\.[0-9]+)?\z/) -> true
      true -> false
    end
  end

  defp coverage_fipe_percentage_valid?(v) when is_number(v), do: v >= 0
  defp coverage_fipe_percentage_valid?(_), do: false

  defp segfy_slug_like?(s) when is_binary(s) do
    String.match?(s, ~r/\A[a-z][a-z0-9_]*\z/)
  end

  defp segfy_slug_like?(_), do: false

  @vehicle_boolean_keys ~w(
    zero_km alienated gas_kit armored chassis_relabeled anti_theft
  )

  defp sanitize_vehicle_booleans_har(veh) when is_map(veh) do
    veh =
      Enum.reduce(@vehicle_boolean_keys, veh, fn key, acc ->
        Map.put(acc, key, coerce_segfy_boolean(Map.get(acc, key)))
      end)

    # HAR envia model_year/manufacture_year como strings
    veh
    |> coerce_year_to_string("model_year")
    |> coerce_year_to_string("manufacture_year")
  end

  defp sanitize_vehicle_booleans_har(_), do: %{}

  defp coerce_year_to_string(veh, key) do
    case Map.get(veh, key) do
      y when is_integer(y) -> Map.put(veh, key, Integer.to_string(y))
      _ -> veh
    end
  end

  defp coerce_segfy_boolean(v) when v in [true, false], do: v
  defp coerce_segfy_boolean(0), do: false
  defp coerce_segfy_boolean(1), do: true

  defp coerce_segfy_boolean(v) when is_binary(v) do
    t = v |> String.trim() |> String.downcase()

    cond do
      t in ~w(true 1 sim s yes y) -> true
      t in ~w(false 0 não nao n no) -> false
      t == "" -> false
      true -> false
    end
  end

  defp coerce_segfy_boolean(_), do: false

  defp ensure_vehicle_plate_for_calculate(data, payload) do
    veh = Map.get(data, "vehicle") || %{}
    sr = Map.get(payload, :show_resp) || Map.get(payload, "show_resp")
    pol = extract_policy_from_payload(payload)
    pol_p = pol[:license_plate] || pol["license_plate"]
    pol_detail = pol[:detail] || pol["detail"]

    plate =
      BrazilianPlate.pick_first_valid_plate([
        Map.get(veh, "plate"),
        Renewal.vehicle_plate_from_show(sr),
        pol_p,
        pol_detail
      ])

    if plate == "" do
      Logger.warning(
        "[Segfy Quotation] placa BR inválida em todas as fontes (vehicle/show/policy.detail); " <>
          "campo plate vazio — corrija license_plate ou detail na apólice se precisar no Segfy"
      )
    end

    Map.put(data, "vehicle", Map.put(veh, "plate", plate))
  end

  defp ensure_commission_all_default(data) when is_map(data) do
    cur = Map.get(data, "commission_all")

    if commission_all_json_valid?(cur) do
      Map.put(data, "commission_all", coerce_commission_all_to_string(cur))
    else
      Map.put(
        data,
        "commission_all",
        Integer.to_string(Segfy.calculate_default_commission_all_integer())
      )
    end
  end

  defp commission_all_json_valid?(nil), do: false
  defp commission_all_json_valid?(""), do: false

  defp commission_all_json_valid?(n) when is_integer(n) and n > 0, do: true
  defp commission_all_json_valid?(n) when is_float(n) and n > 0, do: true

  defp commission_all_json_valid?(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {i, _} when i > 0 -> true
      _ -> false
    end
  end

  defp commission_all_json_valid?(_), do: false

  # HAR envia commission_all como string (ex.: "25"), não integer
  defp coerce_commission_all_to_string(n) when is_integer(n), do: Integer.to_string(n)
  defp coerce_commission_all_to_string(n) when is_float(n), do: Integer.to_string(round(n))

  defp coerce_commission_all_to_string(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {i, _} -> Integer.to_string(i)
      _ -> Integer.to_string(Segfy.calculate_default_commission_all_integer())
    end
  end

  defp coerce_commission_all_to_string(_),
    do: Integer.to_string(Segfy.calculate_default_commission_all_integer())

  defp ensure_zip_code(data, payload) do
    if blank?(data["zip_code"]) do
      # Tenta pegar do vehicle.circulation_zip_code ou do customer
      veh = data["vehicle"] || %{}
      cep = veh["circulation_zip_code"]

      if is_binary(cep) and cep != "" do
        Map.put(data, "zip_code", String.replace(cep, ~r/[^0-9]/, ""))
      else
        # Tenta extrair da policy original
        policy = extract_policy_from_payload(payload)
        zip = policy[:zip_code] || policy["zip_code"] || policy[:cep] || policy["cep"] || ""
        Map.put(data, "zip_code", String.replace(to_string(zip), ~r/[^0-9]/, ""))
      end
    else
      data
    end
  end

  defp ensure_validity_dates(data, payload) do
    policy = extract_policy_from_payload(payload)

    data =
      if blank?(data["validity_start"]) do
        # Usa a data de fim da apólice atual como início da nova
        end_date =
          policy[:validity_end] || policy["validity_end"] ||
            policy[:vigencia_fim] || policy["vigencia_fim"]

        start = parse_validity_date(end_date) || Date.utc_today()
        Map.put(data, "validity_start", format_validity_datetime(start))
      else
        data
      end

    if blank?(data["validity_end"]) do
      # Fim = início + 1 ano
      start_str = data["validity_start"]
      start = parse_validity_date(start_str) || Date.utc_today()
      end_date = Date.add(start, 365)
      Map.put(data, "validity_end", format_validity_datetime(end_date))
    else
      data
    end
  end

  defp parse_validity_date(nil), do: nil
  defp parse_validity_date(""), do: nil

  defp parse_validity_date(s) when is_binary(s) do
    # Aceita "2026-03-31", "2026-03-31T03:00:00.000Z", "31/03/2026"
    cond do
      String.contains?(s, "T") ->
        case Date.from_iso8601(String.slice(s, 0, 10)) do
          {:ok, d} -> d
          _ -> nil
        end

      String.contains?(s, "/") ->
        parts = String.split(s, "/")

        if length(parts) == 3 do
          case Date.from_iso8601("#{Enum.at(parts, 2)}-#{Enum.at(parts, 1)}-#{Enum.at(parts, 0)}") do
            {:ok, d} -> d
            _ -> nil
          end
        end

      true ->
        case Date.from_iso8601(s) do
          {:ok, d} -> d
          _ -> nil
        end
    end
  end

  defp parse_validity_date(_), do: nil

  defp format_validity_datetime(%Date{} = d) do
    Date.to_iso8601(d) <> "T03:00:00.000Z"
  end

  defp ensure_vehicle_defaults(data, _payload) do
    veh = data["vehicle"] || %{}

    veh = put_default(veh, "zero_km", false)
    veh = put_default(veh, "alienated", false)
    veh = put_default(veh, "gas_kit", false)
    veh = put_default(veh, "armored", false)
    veh = put_default(veh, "chassis_relabeled", false)
    veh = put_default(veh, "anti_theft", false)

    # model-list: alinha fipe_value e o texto exato de `model` (dropdown Segfy).
    veh =
      case Renewal.enrich_vehicle_from_segfy_model_list(veh) do
        {:ok, veh2} ->
          veh2

        {:error, reason} ->
          Logger.warning(
            "[Segfy Quotation] model-list falhou reason=#{inspect(reason)} " <>
              "vehicle=#{inspect(Map.take(veh, ~w(brand model model_year fipe_code fipe_value)))}"
          )

          veh
      end

    Map.put(data, "vehicle", veh)
  end

  defp ensure_main_driver_defaults(data) do
    md = data["main_driver"] || %{}
    md = put_default(md, "marital_status", "married")
    md = put_default(md, "profession", "Medico")
    md = put_default(md, "relationship", "himself")
    Map.put(data, "main_driver", md)
  end

  defp ensure_questionnaire_defaults(data) do
    q = data["questionnaire"] || %{}
    # Probe: `yes_with_electronic_gate`; API rejeita `residence_garage: "yes"`.
    q = put_default(q, "residence_garage", "yes_with_electronic_gate")
    q = put_default(q, "job_garage", "yes")
    q = put_default(q, "study_garage", "yes")
    q = put_default(q, "utilization_type", "personal")
    q = put_default(q, "other_driver", "does_not_exist")
    q = put_default(q, "secondary_driver_age", " ")
    q = put_default(q, "monthly_km", "300")
    q = put_default(q, "work_distance", "10")
    q = put_default(q, "residence_type", "house")
    q = put_default(q, "tax_exemption", "not_isent")
    q = normalize_residence_garage_enum(q)
    Map.put(data, "questionnaire", q)
  end

  defp normalize_residence_garage_enum(q) when is_map(q) do
    v = Map.get(q, "residence_garage")

    v2 =
      cond do
        blankish?(v) -> "yes_with_electronic_gate"
        v == "yes" -> "yes_with_electronic_gate"
        true -> v
      end

    Map.put(q, "residence_garage", v2)
  end

  defp ensure_coverage_defaults(data) do
    c = data["coverage"] || %{}
    c = put_default(c, "coverage_type", "comprehensive")
    c = put_default(c, "franchise", "normal")
    c = put_default(c, "fipe_percentage", "100")
    c = put_default(c, "assistance", "assistance_no_limit_unattached")
    c = put_default(c, "glass", "glass_total_referenced")
    c = put_default(c, "rental_car", "rental_car_30_days_referenced")
    c = put_default(c, "rental_car_profile", "basic")
    c = put_default(c, "replacement_zero_km", "no_replacement")
    c = put_default(c, "material_damage", "500000.00")
    c = put_default(c, "body_injuries", "500000.00")
    c = put_default(c, "moral_damage", "10000.00")
    c = put_default(c, "death_illness", 0)
    c = put_default(c, "expense_extraordinary", 0)
    c = put_default(c, "dmh", 0)
    c = put_default(c, "lmi_residential", 0)
    c = put_default(c, "defense_costs", 0)
    c = put_default(c, "quick_repairs", false)
    c = put_default(c, "body_shop_repair", false)
    c = put_default(c, "exemption_franchise", false)
    c = put_default(c, "description", "")
    c = put_default_map(c, "selected_coverage", %{"label" => "Selecione", "value" => " "})

    c =
      put_default_map(c, "maxpar_coverages", %{
        "bodywork_and_paint" => false,
        "wheel_tire_and_suspension" => false
      })

    c = ensure_franchise_non_blank(c)
    Map.put(data, "coverage", c)
  end

  defp ensure_franchise_non_blank(c) when is_map(c) do
    if blankish?(Map.get(c, "franchise")),
      do: Map.put(c, "franchise", "normal"),
      else: c
  end

  defp ensure_renewal_defaults(data, payload) when is_map(data) do
    r = data["renewal"] || %{}
    pol = extract_policy_from_payload(payload)

    # Show/OCR pode trazer insurer "new" ou vazio; para RENOVATION precisamos do slug correto da seguradora anterior.
    r =
      if Map.get(r, "quotation_type") == "RENOVATION" do
        case Map.get(r, "insurer") do
          x when x in [nil, "", "new"] ->
            slug = insurer_slug_from_policy(pol)

            Logger.info(
              "[Segfy Quotation] renewal.insurer inválido para RENOVATION (#{inspect(x)}) → inferido da policy: #{inspect(slug)}"
            )

            Map.put(r, "insurer", slug)

          other ->
            # Valida se é um slug Segfy conhecido
            case normalize_insurer_slug(to_string(other)) do
              nil -> r
              slug -> Map.put(r, "insurer", slug)
            end
        end
      else
        r
      end

    r =
      if blank?(Map.get(r, "insurer")) do
        slug = insurer_slug_from_policy(pol)
        Map.put(r, "insurer", slug)
      else
        r
      end

    r =
      if Map.get(r, "quotation_type") == "RENOVATION" do
        r
        |> ensure_prior_policy_for_renovation(pol, payload)
        |> ensure_prior_policy_end_for_renovation(pol, payload)
      else
        r
      end

    r = put_default(r, "prior_policy", "")
    r = put_default(r, "claim_amount", "0")
    r = put_default(r, "bonus_current", "10")
    r = put_default(r, "bonus_last", "10")
    r = put_default(r, "prior_ic", "")
    r = put_default(r, "codigo_sucursal", "")

    r =
      if Map.get(r, "quotation_type") == "RENOVATION" and
           (blankish?(Map.get(r, "prior_policy")) or blankish?(Map.get(r, "prior_policy_end"))) do
        Logger.warning(
          "[Segfy Quotation] RENOVATION sem prior_policy/prior_policy_end completos " <>
            "prior_policy=#{inspect(Map.get(r, "prior_policy"))} " <>
            "prior_policy_end=#{inspect(Map.get(r, "prior_policy_end"))} " <>
            "policy_keys=#{inspect(Map.keys(pol))}"
        )

        r
      else
        r
      end

    Map.put(data, "renewal", r)
  end

  defp ensure_renewal_defaults(data, _), do: data

  # HAR `renovacao.har`: prior_policy só dígitos (ex. "4551146"), prior_policy_end "YYYY-MM-DD".
  # O show pode trazer lixo em prior_policy (ex. "059"); se for curto demais, ignora e usa Gate/apólice.
  @prior_policy_min_digits 5

  defp ensure_prior_policy_for_renovation(r, pol, payload) do
    cur = prior_policy_digits_only(Map.get(r, "prior_policy"))
    gate_num = gate_prior_policy_digits(payload)
    pro_num = prosseguir_apolice_digits(payload)

    chosen =
      cond do
        # Linha Segfy/Gestão (match) é a fonte de verdade — o show costuma concatenar lixo (ex.: 59250531+4551146).
        gate_num != "" and prior_policy_digits_plausible?(gate_num) ->
          gate_num

        # Linha cuja checkbox foi marcada no POST Prosseguir (HTML) — bate com o log "linha apólice=...".
        pro_num != "" and prior_policy_digits_plausible?(pro_num) ->
          pro_num

        prior_policy_digits_plausible?(cur) ->
          cur

        true ->
          num = prior_policy_digits_from_policy(pol)

          cond do
            prior_policy_digits_plausible?(num) ->
              num

            true ->
              show_r = show_renewal_map(payload)
              sp = Map.get(show_r, "prior_policy") || Map.get(show_r, :prior_policy)
              show_d = if is_binary(sp), do: String.replace(sp, ~r/[^0-9]/, ""), else: ""

              cond do
                prior_policy_digits_plausible?(show_d) ->
                  show_d

                gate_num != "" ->
                  gate_num

                cur != "" ->
                  cur

                true ->
                  ""
              end
          end
      end

    if chosen != "" and chosen != cur do
      Logger.info(
        "[Segfy Quotation] RENOVATION prior_policy ajustado " <>
          "de=#{inspect(cur)} (plausible?=#{prior_policy_digits_plausible?(cur)}) " <>
          "para=#{inspect(chosen)} (gate=#{inspect(gate_num)} prosseguir=#{inspect(pro_num)})"
      )
    end

    Map.put(r, "prior_policy", chosen)
  end

  defp ensure_prior_policy_end_for_renovation(r, pol, payload) do
    if non_blank_str?(Map.get(r, "prior_policy_end")) do
      maybe_normalize_prior_policy_end_date(r)
    else
      # Gate / Gestão HTML costuma ter "Vence em" (dataFim) mesmo sem vigência na apólice local ou no show.
      r =
        case gate_prior_policy_end_iso(payload) do
          s when is_binary(s) and s != "" ->
            Map.put(r, "prior_policy_end", s)

          _ ->
            # Schema local (`policies`): `end_date` — não só validity_end do show/OCR.
            ve =
              pol[:end_date] || pol["end_date"] ||
                pol[:validity_end] || pol["validity_end"] ||
                pol[:vigencia_fim] || pol["vigencia_fim"]

            case format_segfy_renewal_date(ve) do
              nil ->
                show_r = show_renewal_map(payload)
                sve = Map.get(show_r, "prior_policy_end") || Map.get(show_r, :prior_policy_end)

                case format_segfy_renewal_date(sve) do
                  nil ->
                    case gate_match_item(payload) do
                      nil ->
                        r

                      gm ->
                        case Budget.renewal_prior_policy_end_iso_from_gate_item(gm) do
                          nil -> r
                          s -> Map.put(r, "prior_policy_end", s)
                        end
                    end

                  s ->
                    Map.put(r, "prior_policy_end", s)
                end

              s ->
                Map.put(r, "prior_policy_end", s)
            end
        end

      maybe_normalize_prior_policy_end_date(r)
    end
  end

  defp prior_policy_digits_only(nil), do: ""

  defp prior_policy_digits_only(s) when is_binary(s),
    do: String.replace(s, ~r/[^0-9]/, "")

  defp prior_policy_digits_only(_), do: ""

  defp prior_policy_digits_plausible?(s) when is_binary(s) do
    d = String.replace(s, ~r/[^0-9]/, "")
    byte_size(d) >= @prior_policy_min_digits
  end

  defp prior_policy_digits_plausible?(_), do: false

  defp prosseguir_apolice_digits(payload) when is_map(payload) do
    case Map.get(payload, :prosseguir) || Map.get(payload, "prosseguir") do
      %{prosseguir_apolice: s} when is_binary(s) -> prior_policy_digits_only(s)
      %{"prosseguir_apolice" => s} when is_binary(s) -> prior_policy_digits_only(s)
      _ -> ""
    end
  end

  defp prosseguir_apolice_digits(_), do: ""

  defp gate_prior_policy_digits(payload) do
    case gate_match_item(payload) do
      nil -> ""
      gm -> Budget.renewal_prior_policy_digits_from_gate_item(gm)
    end
  end

  defp gate_prior_policy_end_iso(payload) do
    case gate_match_item(payload) do
      nil -> nil
      gm -> Budget.renewal_prior_policy_end_iso_from_gate_item(gm)
    end
  end

  defp maybe_normalize_prior_policy_end_date(r) when is_map(r) do
    case Map.get(r, "prior_policy_end") do
      s when is_binary(s) ->
        case format_segfy_renewal_date(s) do
          nil -> r
          out -> Map.put(r, "prior_policy_end", out)
        end

      _ ->
        r
    end
  end

  defp show_renewal_map(payload) when is_map(payload) do
    sr = Map.get(payload, :show_resp) || Map.get(payload, "show_resp")
    Renewal.renewal_from_show(sr)
  end

  defp show_renewal_map(_), do: %{}

  defp gate_match_item(payload) when is_map(payload) do
    m = Map.get(payload, :match) || Map.get(payload, "match")
    if is_map(m) and map_size(m) > 0, do: m, else: nil
  end

  defp gate_match_item(_), do: nil

  defp prior_policy_digits_from_policy(pol) when is_map(pol) do
    raw =
      pol[:policy_number] || pol["policy_number"] ||
        pol[:numero_apolice] || pol["numero_apolice"] ||
        pol[:detail] || pol["detail"]

    String.replace(to_string(raw || ""), ~r/[^0-9]/, "")
  end

  defp prior_policy_digits_from_policy(_), do: ""

  defp format_segfy_renewal_date(nil), do: nil

  defp format_segfy_renewal_date(s) when is_binary(s) do
    case parse_validity_date(s) do
      %Date{} = d -> Date.to_iso8601(d)
      _ -> nil
    end
  end

  defp format_segfy_renewal_date(%Date{} = d), do: Date.to_iso8601(d)
  defp format_segfy_renewal_date(_), do: nil

  defp non_blank_str?(v) when is_binary(v), do: String.trim(v) != ""
  defp non_blank_str?(_), do: false

  defp put_default(map, key, default) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, default)
      "" -> Map.put(map, key, default)
      _ -> map
    end
  end

  defp put_default_map(map, key, default) do
    case Map.get(map, key) do
      m when is_map(m) and map_size(m) > 0 -> map
      _ -> Map.put(map, key, default)
    end
  end

  # Mapa de nomes de seguradoras (plataforma / PDF) → slug Segfy para a API de automação
  @insurer_slug_map %{
    "porto seguro" => "porto",
    "porto" => "porto",
    "azul seguros" => "azul",
    "azul assinatura" => "azul",
    "azul" => "azul",
    "itau seguros" => "itau",
    "itaú seguros" => "itau",
    "itau" => "itau",
    "itaú" => "itau",
    "mitsui seguros" => "mitsui",
    "mitsui sumitomo" => "mitsui",
    "mitsui" => "mitsui",
    "bllu" => "bllu",
    "tokio marine" => "tokio",
    "tokio" => "tokio",
    "hdi seguros" => "hdi",
    "hdi" => "hdi",
    "liberty seguros" => "liberty",
    "liberty" => "liberty",
    "mapfre" => "mapfre",
    "mapfre seguros" => "mapfre",
    "bradesco seguros" => "bradesco",
    "bradesco" => "bradesco",
    "allianz" => "allianz",
    "allianz seguros" => "allianz",
    "sulamerica" => "sulamerica",
    "sulamérica" => "sulamerica",
    "sul america" => "sulamerica",
    "sul américa" => "sulamerica",
    "zurich" => "zurich",
    "zurich seguros" => "zurich",
    "sompo" => "sompo",
    "sompo seguros" => "sompo",
    "alfa seguros" => "alfa",
    "alfa" => "alfa",
    "suhai" => "suhai",
    "unimed" => "unimed",
    "unimed seguros" => "unimed"
  }

  defp normalize_insurer_slug(name) when is_binary(name) do
    key = name |> String.downcase() |> String.trim()
    Map.get(@insurer_slug_map, key)
  end

  defp normalize_insurer_slug(_), do: nil

  defp insurer_slug_from_policy(pol) when is_map(pol) do
    name =
      pol[:insurer] || pol["insurer"] ||
        pol[:insurer_name] || pol["insurer_name"] || ""

    case normalize_insurer_slug(to_string(name)) do
      nil ->
        Logger.info(
          "[Segfy Quotation] seguradora não mapeada: #{inspect(name)} → fallback 'azul'"
        )

        "azul"

      slug ->
        slug
    end
  end

  defp insurer_slug_from_policy(_), do: "azul"

  defp extract_policy_from_payload(%{policy: p}) when is_map(p), do: policy_as_map(p)

  defp extract_policy_from_payload(map) when is_map(map) do
    case Map.get(map, :policy) || Map.get(map, "policy") do
      p when is_map(p) -> policy_as_map(p)
      _ -> %{}
    end
  end

  defp extract_policy_from_payload(_), do: %{}

  defp policy_as_map(%{__struct__: _} = s), do: Map.from_struct(s)
  defp policy_as_map(m) when is_map(m), do: m

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp blankish?(nil), do: true
  defp blankish?(""), do: true

  defp blankish?(s) when is_binary(s) do
    String.trim(s) == ""
  end

  defp blankish?(_), do: false

  defp json_normalize(map) when is_map(map) do
    Jason.decode!(Jason.encode!(map))
  end

  defp json_normalize(_), do: %{}

  defp normalize_calculate_status(s) when is_binary(s),
    do: s |> String.trim() |> String.upcase()

  defp normalize_calculate_status(s) when is_atom(s),
    do: s |> Atom.to_string() |> normalize_calculate_status()

  defp normalize_calculate_status(_), do: ""

  defp pick_data_section(resp) when is_map(resp) do
    Map.get(resp, "data") || Map.get(resp, :data) || Map.get(resp, "Data") ||
      Map.get(resp, :Data) || get_in(resp, ["result", "data"]) ||
      get_in(resp, ["Result", "Data"])
  end

  defp pick_data_section(_), do: nil

  defp pick_config_section(resp) when is_map(resp) do
    Map.get(resp, "config") || Map.get(resp, :config) || Map.get(resp, "Config") ||
      Map.get(resp, :Config) || get_in(resp, ["result", "config"])
  end

  defp pick_config_section(_), do: nil

  defp data_section_keys(resp) when is_map(resp) do
    case pick_data_section(resp) do
      m when is_map(m) -> Map.keys(m)
      _ -> nil
    end
  end

  defp first_msg(resp) when is_map(resp) do
    Map.get(resp, "message") || Map.get(resp, :message) || Map.get(resp, "Message")
  end

  defp first_errors(resp) when is_map(resp) do
    Map.get(resp, "errors") || Map.get(resp, :errors) || Map.get(resp, "Errors")
  end

  defp first_validations(resp) when is_map(resp) do
    Map.get(resp, "validations") || Map.get(resp, :validations) || Map.get(resp, "Validations")
  end

  defp quotation_id_from_calculate_response(resp, request_data) when is_map(request_data) do
    dm = pick_data_section(resp)

    from_data =
      if is_map(dm) do
        Map.get(dm, "quotation_id") || Map.get(dm, :quotation_id) ||
          Map.get(dm, "QuotationId") || Map.get(dm, :QuotationId)
      end

    from_data ||
      Map.get(resp, "quotation_id") ||
      Map.get(resp, :quotation_id) ||
      Map.get(request_data, "quotation_id") ||
      Map.get(request_data, :quotation_id)
  end

  defp quotation_id_from_calculate_response(_, _), do: nil

  defp truncate_json(bin, max) when is_binary(bin) and byte_size(bin) > max do
    binary_part(bin, 0, max) <> "…(truncated #{byte_size(bin)}B total)"
  end

  defp truncate_json(bin, _max), do: bin

  # --- PAYLOAD_DUMP: respostas/pedidos brutos (grep `SEGFY PAYLOAD_DUMP` nos logs Docker) ---

  defp log_payload_dump_calculate_response(resp, mode) when is_map(resp) do
    dm = pick_data_section(resp)
    dc = pick_config_section(resp)

    summary = %{
      "where" => "api.automation POST /api/vehicle/version/1.0/calculate RESPONSE",
      "mode" => to_string(mode),
      "top_keys" => resp |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
      "status" => Map.get(resp, "status") || Map.get(resp, :status),
      "message" => first_msg(resp),
      "data_keys" => data_keys_sorted(dm),
      "data_outline" => payload_dump_outline(dm, 72),
      "config_keys" => data_keys_sorted(dc),
      "config_outline" => payload_dump_outline(dc, 48)
    }

    Logger.info("[Segfy PAYLOAD_DUMP] calculate_response summary " <> Jason.encode!(summary))

    try do
      redacted = resp |> json_normalize() |> redact_tokens_deep()
      json = Jason.encode!(redacted)

      Logger.info(
        "[Segfy PAYLOAD_DUMP] calculate_response json_redacted_trunc mode=#{inspect(mode)}\n" <>
          truncate_json(json, @payload_dump_json_max)
      )
    rescue
      e ->
        Logger.warning(
          "[Segfy PAYLOAD_DUMP] calculate_response encode falhou mode=#{inspect(mode)}: #{inspect(e)}"
        )
    end
  end

  defp log_payload_dump_calculate_response(_, mode) do
    Logger.info("[Segfy PAYLOAD_DUMP] calculate_response (não-map) mode=#{inspect(mode)}")
  end

  defp log_payload_dump_salva_request(body, mode, server_qid) when is_map(body) do
    data = Map.get(body, "data") || %{}
    cfg = Map.get(body, "config") || %{}

    summary = %{
      "where" => "gestao POST /api/Orcamento/SalvaCotacaoAutomation REQUEST",
      "mode" => to_string(mode),
      "quotation_id" => Map.get(body, "quotation_id"),
      "tipo_multicalculo" => Map.get(body, "tipo_multicalculo"),
      "data_keys" => data_keys_sorted(data),
      "data_outline" => payload_dump_outline(data, 72),
      "config_keys" => data_keys_sorted(cfg),
      "config_outline" => payload_dump_outline(cfg, 48)
    }

    Logger.info(
      "[Segfy PAYLOAD_DUMP] salva_request summary quotation_id=#{inspect(server_qid)} " <>
        Jason.encode!(summary)
    )

    try do
      redacted = body |> json_normalize() |> redact_tokens_deep()
      json = Jason.encode!(redacted)

      Logger.info(
        "[Segfy PAYLOAD_DUMP] salva_request json_redacted_trunc mode=#{inspect(mode)} quotation_id=#{inspect(server_qid)}\n" <>
          truncate_json(json, @payload_dump_json_max)
      )
    rescue
      e ->
        Logger.warning("[Segfy PAYLOAD_DUMP] salva_request encode falhou: #{inspect(e)}")
    end
  end

  defp log_payload_dump_salva_request(_, mode, server_qid) do
    Logger.info(
      "[Segfy PAYLOAD_DUMP] salva_request (body não-map) mode=#{inspect(mode)} qid=#{inspect(server_qid)}"
    )
  end

  defp log_payload_dump_salva_response(resp, mode, server_qid) do
    outline_header =
      cond do
        is_map(resp) ->
          %{
            "kind" => "map",
            "keys" => resp |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
            "outline" => payload_dump_outline(resp, 64)
          }

        is_binary(resp) ->
          %{
            "kind" => "binary",
            "byte_size" => byte_size(resp),
            "prefix" => String.slice(resp, 0, 400)
          }

        true ->
          %{"kind" => "other", "inspect" => inspect(resp, limit: 40)}
      end

    Logger.info(
      "[Segfy PAYLOAD_DUMP] salva_response header mode=#{inspect(mode)} quotation_id=#{inspect(server_qid)} " <>
        Jason.encode!(outline_header)
    )

    if is_map(resp) do
      try do
        json =
          resp
          |> json_normalize()
          |> redact_tokens_deep()
          |> Jason.encode!()

        Logger.info(
          "[Segfy PAYLOAD_DUMP] salva_response json_redacted_trunc mode=#{inspect(mode)}\n" <>
            truncate_json(json, @payload_dump_json_max)
        )
      rescue
        e ->
          Logger.warning("[Segfy PAYLOAD_DUMP] salva_response encode falhou: #{inspect(e)}")
      end
    end
  end

  defp data_keys_sorted(nil), do: nil

  defp data_keys_sorted(m) when is_map(m) do
    m |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
  end

  defp data_keys_sorted(_), do: nil

  defp payload_dump_outline(nil, _), do: nil

  defp payload_dump_outline(m, max_entries) when is_map(m) do
    m
    |> Map.to_list()
    |> Enum.take(max_entries)
    |> Map.new(fn {k, v} -> {to_string(k), payload_dump_value_outline(v)} end)
  end

  defp payload_dump_outline(_, _), do: nil

  defp payload_dump_value_outline(v) when is_list(v) do
    case v do
      [] ->
        "list(0)"

      [h | _] when is_map(h) ->
        fk = h |> Map.keys() |> Enum.map(&to_string/1) |> Enum.take(14)
        "list(#{length(v)}) first_item_keys=#{inspect(fk)}"

      _ ->
        "list(#{length(v)})"
    end
  end

  defp payload_dump_value_outline(v) when is_map(v) do
    ks = v |> Map.keys() |> Enum.map(&to_string/1) |> Enum.take(18)

    more =
      if map_size(v) > length(ks), do: "…(+#{map_size(v) - length(ks)} keys)", else: ""

    "map(#{map_size(v)} keys #{inspect(ks)}#{more})"
  end

  defp payload_dump_value_outline(v), do: inspect(v, limit: 120, printable_limit: 96)

  defp redact_tokens_deep(value) do
    walk_redact(json_normalize(value))
  end

  defp walk_redact(m) when is_map(m) do
    Enum.into(m, %{}, fn {k, v} ->
      key_s = String.downcase(to_string(k))

      v_out =
        if MapSet.member?(@redact_log_keys, key_s) or String.ends_with?(key_s, "token") do
          mask_opaque_for_log(if is_binary(v), do: v, else: inspect(v, limit: 30))
        else
          walk_redact(v)
        end

      {k, v_out}
    end)
  end

  defp walk_redact(l) when is_list(l), do: Enum.map(l, &walk_redact/1)
  defp walk_redact(x), do: x

  # --- Logs para comparar com HAR (Chrome → api.automation/calculate + SalvaCotacaoAutomation) ---

  defp mask_opaque_for_log(nil), do: nil
  defp mask_opaque_for_log(""), do: ""

  defp mask_opaque_for_log(t) when is_binary(t) do
    n = byte_size(t)
    if n <= 10, do: "…(#{n}B)", else: String.slice(t, 0, 8) <> "…(#{n}B)"
  end

  defp mask_opaque_for_log(_), do: "?"

  defp insurers_commission_snapshot(cfg) when is_map(cfg) do
    ins = Map.get(cfg, "insurers") || []

    ins
    |> List.wrap()
    |> Enum.map(&insurer_flat_snapshot_for_log/1)
  end

  defp insurers_commission_snapshot(_), do: []

  defp insurer_flat_snapshot_for_log(%{"company" => c}) when is_map(c) do
    %{"name" => Map.get(c, "name"), "commission" => Map.get(c, "commission")}
  end

  defp insurer_flat_snapshot_for_log(m) when is_map(m) do
    %{"name" => Map.get(m, "name"), "commission" => Map.get(m, "commission")}
  end

  # HAR `renovacao.har` → POST SalvaCotacaoAutomation: cada item é
  # `{"company": {"name": "porto", "commission": 20}}`, não `{name, commission}` no topo.
  # Formato plano é aceito na api.automation/calculate; o Gestão **só persiste** comissão no nested.
  defp nest_insurers_for_gestao_salva(cfg) when is_map(cfg) do
    cfg = json_normalize(cfg)
    ins = Map.get(cfg, "insurers") || []

    if is_list(ins) and ins != [] do
      nested = Enum.map(ins, &insurer_to_gestao_salva_company_entry/1)
      Map.put(cfg, "insurers", nested)
    else
      cfg
    end
  end

  defp insurer_to_gestao_salva_company_entry(%{"company" => inner}) when is_map(inner) do
    n = Map.get(inner, "name")
    c = normalize_salva_commission_integer(Map.get(inner, "commission"))
    %{"company" => %{"name" => n, "commission" => c}}
  end

  defp insurer_to_gestao_salva_company_entry(m) when is_map(m) do
    n = Map.get(m, "name")
    c = normalize_salva_commission_integer(Map.get(m, "commission"))
    %{"company" => %{"name" => n, "commission" => c}}
  end

  # HAR `novo.har` Salva: `company.commission` é inteiro `25` (não float).
  defp normalize_salva_commission_integer(n) when is_integer(n), do: n

  defp normalize_salva_commission_integer(n) when is_float(n), do: round(n)

  defp normalize_salva_commission_integer(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {i, _} -> i
      _ -> Segfy.calculate_default_commission_percent()
    end
  end

  defp normalize_salva_commission_integer(_), do: Segfy.calculate_default_commission_percent()

  defp log_har_compare_calculate_request(data, calculate_request_config, mode, cod)
       when is_map(data) do
    cfg = json_normalize(calculate_request_config)

    block = %{
      "har_ref" => "POST …/api/vehicle/version/1.0/calculate",
      "mode" => to_string(mode),
      "cod_orcamento_gestao" => cod,
      "data" => %{"commission_all" => data["commission_all"]},
      "config" => %{
        "insurers" => insurers_commission_snapshot(cfg),
        "callback" => Map.get(cfg, "callback"),
        "token_masked" => mask_opaque_for_log(Map.get(cfg, "token"))
      }
    }

    Logger.info(
      "[Segfy Quotation] HAR_COMPARE calculate REQUEST comissão " <> Jason.encode!(block)
    )
  end

  defp log_har_compare_calculate_request(_, _, _, _), do: :ok

  defp log_har_compare_calculate_response_config(calc_resp, st) when is_map(calc_resp) do
    resp_c = pick_config_section(calc_resp)

    {keys_label, insurers_snap} =
      if is_map(resp_c) and map_size(resp_c) > 0 do
        nc = json_normalize(resp_c)
        {inspect(Map.keys(nc)), insurers_commission_snapshot(nc)}
      else
        {"(resposta sem config ou config vazio — típico)", []}
      end

    Logger.info(
      "[Segfy Quotation] HAR_COMPARE calculate RESPONSE status=#{st} " <>
        "resp.config_keys=#{keys_label} resp.config.insurers=#{inspect(insurers_snap)}"
    )
  end

  defp log_har_compare_calculate_response_config(_, _), do: :ok

  defp log_har_compare_save_merge(req_d, resp_cfg, req_c, merged_cfg, merged_data) do
    Logger.info(
      "[Segfy Quotation] HAR_COMPARE save_body_maps merge " <>
        "request_data.commission_all=#{inspect(req_d["commission_all"])} " <>
        "merged_data.commission_all=#{inspect(merged_data["commission_all"])} " <>
        "resp_cfg.empty?=#{map_size(resp_cfg) == 0} " <>
        "resp_cfg.insurers=#{inspect(insurers_commission_snapshot(resp_cfg))} " <>
        "request_config.insurers=#{inspect(insurers_commission_snapshot(req_c))} " <>
        "merged_config.insurers=#{inspect(insurers_commission_snapshot(merged_cfg))}"
    )
  end

  defp log_har_compare_save_body_before_salva(
         server_qid,
         cod,
         body_data,
         body_cfg,
         calculate_request_config
       ) do
    bd = json_normalize(body_data)
    bc = json_normalize(body_cfg)
    oc = json_normalize(calculate_request_config)

    block = %{
      "har_ref" => "POST …/api/Orcamento/SalvaCotacaoAutomation?codigoOrcamento=&token=",
      "note" => "insurers devem ser [{company: {name, commission}}] como no HAR",
      "quotation_id" => server_qid,
      "cod_orcamento_gestao" => cod,
      "data" => %{
        "commission_all_before_salva_strip" => bd["commission_all"],
        "salva_json_will_omit_commission_all" => true
      },
      "config" => %{
        "insurers" => Map.get(bc, "insurers"),
        "insurers_flat_log" => insurers_commission_snapshot(bc),
        "callback" => Map.get(bc, "callback"),
        "token_masked" => mask_opaque_for_log(Map.get(bc, "token"))
      },
      "same_as_calculate_request_config_insurers" => insurers_commission_snapshot(oc)
    }

    Logger.info(
      "[Segfy Quotation] HAR_COMPARE SalvaCotacaoAutomation BODY comissão " <>
        Jason.encode!(block)
    )
  end

  # A resposta do `calculate` muitas vezes vem com `config` vazio ou sem `insurers`.
  # O `SalvaCotacaoAutomation` persiste esse `config` — se for %{}, o HFy abre com comissão 0%.
  # Mesclamos o **mesmo** `config` enviado no POST do calculate (token, callback, insurers).
  defp save_body_maps(calc_resp, request_data, calculate_request_config)
       when is_map(request_data) do
    resp_d = pick_data_section(calc_resp)
    resp_c = pick_config_section(calc_resp)
    req_d = json_normalize(request_data)

    req_c =
      if is_map(calculate_request_config) and calculate_request_config != %{} do
        json_normalize(calculate_request_config)
      else
        %{}
      end

    data =
      cond do
        is_map(resp_d) and resp_d != %{} ->
          rd = json_normalize(resp_d)
          # Servidor manda quotation_id etc.; `commission_all` deve acompanhar o pedido (HAR).
          Map.merge(rd, Map.take(req_d, ["commission_all"]))

        true ->
          req_d
      end

    data =
      if commission_all_json_valid?(data["commission_all"]) do
        Map.put(data, "commission_all", coerce_commission_all_to_string(data["commission_all"]))
      else
        Map.put(
          data,
          "commission_all",
          Integer.to_string(Segfy.calculate_default_commission_all_integer())
        )
      end

    resp_cfg =
      if is_map(resp_c) and resp_c != %{} do
        json_normalize(resp_c)
      else
        %{}
      end

    config = Map.merge(resp_cfg, req_c)

    log_har_compare_save_merge(req_d, resp_cfg, req_c, config, data)

    {data, config}
  end

  defp save_after_calculate(
         calc_resp,
         server_qid,
         cod,
         token,
         cookie,
         mode,
         outcome,
         request_data,
         calculate_request_config,
         multicalculo_socket_results
       ) do
    # Sempre aquecer sessão ASP.NET — inclusive quando cod="" (primeiro save),
    # senão o Gestão retorna HTTP 500 por falta de sessão inicializada.
    save_cookie =
      case Gestao.warm_hfy_auto_session(cod, cookie) do
        {:ok, merged} when is_binary(merged) and merged != "" -> merged
        _ -> cookie
      end

    {body_data, body_cfg} = save_body_maps(calc_resp, request_data, calculate_request_config)
    body_cfg_salva = nest_insurers_for_gestao_salva(body_cfg)

    log_har_compare_save_body_before_salva(
      server_qid,
      cod,
      body_data,
      body_cfg_salva,
      calculate_request_config
    )

    # HAR SalvaCotacaoAutomation: `data` não inclui `commission_all` (só `config.insurers`).
    body_data_salva = Map.delete(body_data, "commission_all")

    body = %{
      "quotation_id" => server_qid,
      "token" => token,
      "data" => body_data_salva,
      "config" => body_cfg_salva,
      "tipo_multicalculo" => "Auto"
    }

    log_payload_dump_salva_request(body, mode, server_qid)

    case Gestao.salva_cotacao_automation(cod, token, body, cookie: save_cookie) do
      {:ok, save_resp} ->
        Logger.info(
          "[Segfy Quotation] SalvaCotacaoAutomation OK mode=#{inspect(mode)} " <>
            "(#{calculate_mode_human(mode)}) quotation_id=#{inspect(server_qid)} cod_gestao=#{cod}"
        )

        log_payload_dump_salva_response(save_resp, mode, server_qid)

        {:ok,
         %{
           calculate: calc_resp,
           save: save_resp,
           mode: mode,
           calculate_outcome: outcome,
           request_data: request_data,
           request_config: calculate_request_config,
           multicalculo_socket_results: List.wrap(multicalculo_socket_results)
         }}

      {:error, reason} ->
        {:error, {:salva_failed, mode, reason}}
    end
  end
end
