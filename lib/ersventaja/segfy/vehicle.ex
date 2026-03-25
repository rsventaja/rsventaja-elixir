defmodule Ersventaja.Segfy.Vehicle do
  @moduledoc """
  Cliente da API `api.automation.segfy.com` para veículo (versão 1.0).

  `config.token`: token **opaco** (`Segfy.resolved_automation_token/0` = probe `list-by-intranet`), salvo override em `config`.
  """

  require Logger

  @api_prefix "/api/vehicle/version/1.0"

  @calculate_wire_json_trunc 8_000

  alias Ersventaja.Segfy.Client

  @doc """
  Carrega uma cotação existente por UUID.
  """
  def show(quotation_id, opts \\ []) when is_binary(quotation_id) do
    body = %{
      data: %{id: quotation_id},
      config: ensure_token(Keyword.get(opts, :config, %{}))
    }

    Client.post_automation("#{@api_prefix}/show", body)
  end

  @doc """
  Dispara o cálculo (multicálculo HFY). `data` deve seguir o contrato observado no front Segfy
  (cliente, condutor, veículo, questionnaire, coverage, renewal, etc.).
  """
  def calculate(data, opts \\ []) when is_map(data) do
    config =
      opts
      |> Keyword.get(:config, %{})
      |> ensure_token()
      |> maybe_put_insurers(Keyword.get(opts, :insurers))
      |> maybe_put_callback(Keyword.get(opts, :callback))

    body = %{data: data, config: config}
    log_calculate_wire_compare(body)
    Client.post_automation("#{@api_prefix}/calculate", body)
  end

  def brand_list(vehicle_type \\ "car", opts \\ []) do
    body = %{
      data: %{vehicle_type: vehicle_type},
      config: ensure_token(Keyword.get(opts, :config, %{}))
    }

    Client.post_automation("#{@api_prefix}/brand-list", body)
  end

  def company_list(vehicle_type \\ "car", opts \\ []) do
    body = %{
      data: %{vehicle_type: vehicle_type},
      config: ensure_token(Keyword.get(opts, :config, %{}))
    }

    Client.post_automation("#{@api_prefix}/company-list", body)
  end

  def renewal_list(opts \\ []) do
    body = %{config: ensure_token(Keyword.get(opts, :config, %{}))}
    Client.post_automation("#{@api_prefix}/renewal-list", body)
  end

  def model_list(params, opts \\ []) when is_map(params) do
    # gRPC espera integral em `year_model`; JSON com "2019" (string) → 422 no backend.
    data = normalize_model_list_params(params)
    body = %{data: data, config: ensure_token(Keyword.get(opts, :config, %{}))}
    Client.post_automation("#{@api_prefix}/model-list", body)
  end

  defp normalize_model_list_params(params) when is_map(params) do
    my = Map.get(params, "model_year") || Map.get(params, :model_year)
    ym = Map.get(params, "year_model") || Map.get(params, :year_model)
    year = parse_year_int_for_api(my) || parse_year_int_for_api(ym)

    if is_integer(year) do
      params
      |> Map.drop([:model_year, :year_model])
      |> Map.drop(["model_year", "year_model"])
      |> Map.put("model_year", year)
      |> Map.put("year_model", year)
    else
      params
    end
  end

  defp parse_year_int_for_api(nil), do: nil
  defp parse_year_int_for_api(y) when is_integer(y), do: y

  defp parse_year_int_for_api(y) when is_binary(y) do
    case Integer.parse(String.trim(y)) do
      {n, _} when n >= 1950 and n <= 2100 -> n
      _ -> nil
    end
  end

  defp parse_year_int_for_api(_), do: nil

  def profession_list(prefix, opts \\ []) when is_binary(prefix) do
    body = %{data: %{profession: prefix}, config: ensure_token(Keyword.get(opts, :config, %{}))}
    Client.post_automation("#{@api_prefix}/profession-list", body)
  end

  defp ensure_token(config) when is_map(config) do
    token = Map.get(config, :token) || Map.get(config, "token")

    if is_binary(token) and token != "" do
      config
    else
      case Ersventaja.Segfy.resolved_automation_token() do
        t when is_binary(t) and t != "" -> Map.put(config, :token, t)
        _ -> config
      end
    end
  end

  defp maybe_put_insurers(config, nil), do: config

  defp maybe_put_insurers(config, insurers) when is_list(insurers) do
    Map.put(config, :insurers, insurers)
  end

  defp maybe_put_callback(config, nil), do: config
  defp maybe_put_callback(config, cb) when is_binary(cb), do: Map.put(config, :callback, cb)

  # JSON efetivo do POST /calculate (comparar com HAR). Token mascarado; JSON longo só em debug.
  defp log_calculate_wire_compare(body) when is_map(body) do
    wire =
      try do
        Jason.decode!(Jason.encode!(body))
      rescue
        _ ->
          Logger.warning(
            "[Segfy Vehicle] CALCULATE_WIRE encode falhou — body não serializável como JSON"
          )

          %{}
      end

    d = Map.get(wire, "data") || %{}
    c = Map.get(wire, "config") || %{}

    summary = %{
      "data_keys" => d |> Map.keys() |> Enum.sort(),
      "quotation_id" => Map.get(d, "quotation_id"),
      "commission_all" => Map.get(d, "commission_all"),
      "commission_all_type" => type_label(Map.get(d, "commission_all")),
      "renewal" => Map.get(d, "renewal"),
      "coverage_enums" => take_coverage_enums(Map.get(d, "coverage")),
      "questionnaire_garage" => take_questionnaire_garage(Map.get(d, "questionnaire")),
      "vehicle_brief" => take_vehicle_brief(Map.get(d, "vehicle")),
      "customer_doc_masked" => mask_doc_suffix(Map.get(d["customer"] || %{}, "document")),
      "zip_code" => Map.get(d, "zip_code"),
      "validity_start" => Map.get(d, "validity_start"),
      "validity_end" => Map.get(d, "validity_end"),
      "config_insurers" => insurers_wire_snapshot(Map.get(c, "insurers")),
      "config_callback" => Map.get(c, "callback"),
      "config_extra_keys" => (Map.keys(c) -- ["token", "insurers", "callback"]) |> Enum.sort(),
      "token_masked" => mask_token_log(Map.get(c, "token")),
      "wire_sha16" => wire_sha16(wire)
    }

    Logger.info("[Segfy Vehicle] CALCULATE_WIRE_SHAPE " <> Jason.encode!(summary))

    Logger.debug(fn ->
      json = Jason.encode!(wire)

      trunc =
        if byte_size(json) > @calculate_wire_json_trunc do
          binary_part(json, 0, @calculate_wire_json_trunc) <> "…(truncated)"
        else
          json
        end

      "[Segfy Vehicle] CALCULATE_WIRE_JSON " <> trunc
    end)
  end

  defp log_calculate_wire_compare(_), do: :ok

  defp wire_sha16(wire) when is_map(wire) do
    :crypto.hash(:sha256, Jason.encode!(wire))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  rescue
    _ -> "?"
  end

  defp type_label(v) when is_integer(v), do: "integer"
  defp type_label(v) when is_float(v), do: "float"
  defp type_label(v) when is_binary(v), do: "binary"
  defp type_label(nil), do: "nil"
  defp type_label(_), do: "other"

  defp take_coverage_enums(nil), do: %{}

  defp take_coverage_enums(cov) when is_map(cov) do
    keys =
      ~w(coverage_type franchise assistance glass rental_car rental_car_profile fipe_percentage)

    Map.new(keys, fn k -> {k, Map.get(cov, k)} end)
  end

  defp take_questionnaire_garage(nil), do: %{}

  defp take_questionnaire_garage(q) when is_map(q) do
    Map.take(q, [
      "residence_garage",
      "job_garage",
      "study_garage",
      "utilization_type",
      "residence_type"
    ])
  end

  defp take_vehicle_brief(nil), do: %{}

  defp take_vehicle_brief(v) when is_map(v) do
    Map.take(v, [
      "plate",
      "brand",
      "model",
      "model_year",
      "fipe_value",
      "fipe_code",
      "brand_id",
      "vehicle_type"
    ])
  end

  defp insurers_wire_snapshot(nil), do: []

  defp insurers_wire_snapshot(list) when is_list(list) do
    Enum.map(list, fn
      %{"company" => inner} when is_map(inner) ->
        %{
          "name" => Map.get(inner, "name"),
          "commission" => Map.get(inner, "commission")
        }

      m when is_map(m) ->
        %{
          "name" => Map.get(m, "name"),
          "commission" => Map.get(m, "commission")
        }
    end)
  end

  defp mask_doc_suffix(nil), do: nil

  defp mask_doc_suffix(doc) when is_binary(doc) do
    d = String.replace(doc, ~r/[^0-9]/, "")

    cond do
      d == "" -> "(vazio)"
      byte_size(d) <= 4 -> "****"
      true -> "****" <> String.slice(d, -4, 4)
    end
  end

  defp mask_doc_suffix(_), do: "(?)"

  defp mask_token_log(nil), do: nil
  defp mask_token_log(""), do: ""

  defp mask_token_log(t) when is_binary(t) do
    n = byte_size(t)
    if n <= 10, do: "…(#{n}B)", else: String.slice(t, 0, 8) <> "…(#{n}B)"
  end

  defp mask_token_log(_), do: "?"
end
