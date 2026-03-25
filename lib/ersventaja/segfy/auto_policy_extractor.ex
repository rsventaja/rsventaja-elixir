defmodule Ersventaja.Segfy.AutoPolicyExtractor do
  @moduledoc """
  **Única** etapa que transforma texto do PDF (vindo de `OCR.extract_text_from_pdf/1`) em campos
  estruturados para o multicálculo Segfy — via LLM (OpenAI), alinhado ao `GPTClient` de apólices.

  O OCR só alimenta esta LLM; não há extração paralela de placa/cobertura/etc. por regex no texto bruto.
  O JSON retornado é **mesclado** ao payload de `Ersventaja.Segfy.Vehicle.calculate/2` (`merge_calculate_payload/2`).
  """

  @api_url "https://api.openai.com/v1/chat/completions"
  @default_model "gpt-4o-mini"

  @top_sections ~w(renewal questionnaire coverage customer main_driver vehicle)a

  # Chaves aninhadas conhecidas como **binários** (igual ao JSON do LLM).
  # Só convertemos para átomo chaves desta lista (conjunto finito — seguro com `String.to_atom/1`).
  @nested_string_keys MapSet.new(~w(
    quotation_type insurer prior_policy claim_amount prior_policy_end bonus_current bonus_last
    prior_ic codigo_sucursal codigo_renovacao item origin_bonus transferencia_corretagem
    proprio_corretor
    residence_garage job_garage study_garage utilization_type other_driver secondary_driver_age
    monthly_km work_distance residence_type tax_exemption
    coverage_type franchise fipe_percentage assistance glass rental_car rental_car_profile
    replacement_zero_km material_damage body_injuries moral_damage death_illness
    expense_extraordinary dmh lmi_residential defense_costs exemption_franchise body_shop_repair
    quick_repairs description selected_coverage label value
    name document birth_date sex email cellphone social_name profession marital_status relationship
    brand model plate chassis manufacture_year model_year circulation_zip_code fuel_type
    vehicle_type category_type fipe_code fipe_value zero_km alienated gas_kit armored
    chassis_relabeled anti_theft
    bodywork_and_paint wheel_tire_and_suspension
  )s)

  @doc """
  Mescla `extracted` (normalmente saída de `extract_from_ocr_text/1`) em `base`.

  Seções de primeiro nível: `renewal`, `questionnaire`, `coverage`, `customer`, `main_driver`,
  `vehicle`. Mapas aninhados são unidos com preferência aos valores de `extracted`.
  Chaves string vindas do JSON são convertidas em átomos apenas quando constam de uma lista
  interna conhecida (conjunto finito; não usamos `to_existing_atom` porque o átomo pode ainda
  não existir na VM se a chave só apareceu no JSON).
  """
  def merge_calculate_payload(base, extracted) when is_map(base) and is_map(extracted) do
    extracted = normalize_root(extracted)

    Enum.reduce(@top_sections, base, fn section, acc ->
      case Map.get(extracted, section) do
        nil ->
          acc

        v when is_map(v) ->
          prev = Map.get(acc, section) || %{}
          Map.put(acc, section, deep_merge_maps(prev, atomize_nested_safe(v)))

        v ->
          Map.put(acc, section, v)
      end
    end)
  end

  defp normalize_root(map) do
    map
    |> Enum.map(fn {k, v} -> {normalize_root_key(k), v} end)
    |> Enum.reject(fn {k, _} -> k == :skip end)
    |> Map.new()
  end

  defp normalize_root_key(k) when is_atom(k) do
    if k in @top_sections, do: k, else: :skip
  end

  defp normalize_root_key(k) when is_binary(k) do
    case k do
      "renewal" -> :renewal
      "questionnaire" -> :questionnaire
      "coverage" -> :coverage
      "customer" -> :customer
      "main_driver" -> :main_driver
      "vehicle" -> :vehicle
      _ -> :skip
    end
  end

  defp deep_merge_maps(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn
      _, va, vb when is_map(va) and is_map(vb) -> deep_merge_maps(va, vb)
      _, _va, vb -> vb
    end)
  end

  defp deep_merge_maps(a, b), do: Map.merge(a, b)

  defp atomize_nested_safe(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key =
        case k do
          k when is_atom(k) ->
            k

          k when is_binary(k) ->
            if MapSet.member?(@nested_string_keys, k) do
              String.to_atom(k)
            else
              k
            end
        end

      val =
        cond do
          is_map(v) -> atomize_nested_safe(v)
          is_list(v) -> v
          true -> v
        end

      {key, val}
    end)
  end

  @doc """
  Extrai mapa de campos compatíveis com `data` do `calculate` da Segfy.

  Retorna chaves de primeiro nível típicas: `renewal`, `questionnaire`, `coverage`, `customer`,
  `main_driver`, `vehicle` — apenas o que for inferível do texto.
  """
  def extract_from_ocr_text(text) when is_binary(text) do
    api_key = System.get_env("OPENAI_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, "OPENAI_API_KEY not set"}
    else
      model = System.get_env("OPENAI_MODEL", @default_model)

      case call_openai(text, api_key, model) do
        {:ok, map} -> {:ok, sanitize_extracted(map)}
        err -> err
      end
    end
  end

  def extract_from_ocr_text(_), do: {:error, "text must be a binary"}

  defp sanitize_extracted(map) when is_map(map) do
    vkey = if Map.has_key?(map, "vehicle"), do: "vehicle", else: :vehicle

    case Map.get(map, vkey) do
      v when is_map(v) ->
        ckey = if Map.has_key?(v, "chassis"), do: "chassis", else: :chassis
        chassis = Map.get(v, ckey)

        if is_binary(chassis) and chassis != "" and not valid_vin?(chassis) do
          require Logger

          Logger.warning(
            "[AutoPolicyExtractor] chassi inválido descartado: #{inspect(chassis)} " <>
              "(#{byte_size(chassis)} chars, esperado 17 sem I/O/Q)"
          )

          Map.put(map, vkey, Map.put(v, ckey, nil))
        else
          map
        end

      _ ->
        map
    end
  end

  @doc """
  Valida chassi (VIN) brasileiro: 17 caracteres alfanuméricos, sem I/O/Q.
  """
  def valid_vin?(nil), do: false

  def valid_vin?(vin) when is_binary(vin) do
    clean = String.upcase(String.trim(vin))
    byte_size(clean) == 17 and Regex.match?(~r/\A[A-HJ-NPR-Z0-9]{17}\z/, clean)
  end

  def valid_vin?(_), do: false

  defp call_openai(text, api_key, model) do
    request_body = %{
      model: model,
      messages: [
        %{role: "system", content: system_prompt()},
        %{role: "user", content: user_prompt(text)}
      ],
      response_format: %{type: "json_object"},
      temperature: 0.1
    }

    body = Jason.encode!(request_body)

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    hackney_options = [
      :with_body,
      recv_timeout: 90_000,
      connect_timeout: 10_000
    ]

    case :hackney.post(@api_url, headers, body, hackney_options) do
      {:ok, status, _headers, resp_body} when status in [200, 201] ->
        parse_openai_response(resp_body)

      {:ok, status, _headers, resp_body} ->
        {:error, "OpenAI error #{status}: #{truncate(resp_body)}"}

      {:error, reason} ->
        {:error, "HTTP failed: #{inspect(reason)}"}
    end
  end

  defp parse_openai_response(resp_body) do
    with {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} <-
           Jason.decode(resp_body),
         {:ok, map} <- Jason.decode(content) do
      {:ok, map}
    else
      {:ok, %{"error" => err}} ->
        {:error, "OpenAI: #{inspect(err)}"}

      _ ->
        {:error, "unexpected OpenAI response shape"}
    end
  end

  defp user_prompt(text) do
    """
    Texto OCR de uma apólice de seguro auto brasileira:

    #{text}

    Devolva apenas o JSON definido no prompt do sistema.
    """
  end

  defp system_prompt do
    """
    Você extrai dados para preencher o multicálculo Segfy (API de automação de seguro auto).

    Retorne um ÚNICO objeto JSON com chaves de primeiro nível opcionais (omitir ou usar null se desconhecido):
    - renewal: objeto com campos usados em renovação quando aplicável:
      - quotation_type: "RENOVATION" ou "NEW_QUOTATION"
      - insurer: slug Segfy da seguradora anterior. Slugs válidos:
        "porto" (Porto Seguro), "azul" (Azul Seguros / Azul Assinatura), "itau" (Itaú Seguros),
        "mitsui" (Mitsui Seguros / Mitsui Sumitomo), "bllu" (BLLU), "tokio" (Tokio Marine),
        "hdi" (HDI Seguros), "liberty" (Liberty Seguros), "mapfre" (Mapfre), "bradesco" (Bradesco Seguros),
        "allianz" (Allianz), "sulamerica" (SulAmérica), "zurich" (Zurich), "sompo" (Sompo),
        "alfa" (Alfa Seguros), "suhai" (Suhai).
        Use "new" APENAS se não houver seguradora anterior (cotação nova, sem apólice vigente)
      - prior_policy: número da apólice anterior (string)
      - claim_amount: string com valor ou quantidade de sinistros (ex.: "0")
      - prior_policy_end: data fim da apólice anterior (YYYY-MM-DD)
      - bonus_current, bonus_last: classe de bônus (string, ex.: "10")
      - prior_ic: código CI / classe interna se aparecer no documento (string)
      - codigo_sucursal: string vazia ou valor se houver
    - questionnaire: perfil de risco (valores exatos do Segfy em inglês):
      - residence_garage: use "yes_with_electronic_gate", "yes_without_electronic_gate", "no" etc. — NUNCA só "yes" (inválido na API)
      - job_garage, study_garage
      - utilization_type (ex.: "personal")
      - other_driver (ex.: "does_not_exist")
      - secondary_driver_age
      - monthly_km, work_distance (números ou strings)
      - residence_type (ex.: "house", "apartment")
      - tax_exemption (ex.: "not_isent")
    - coverage: apenas se o documento deixar claro limites ou tipos; use chaves alinhadas ao Segfy:
      - coverage_type, franchise, fipe_percentage, assistance, glass, rental_car, material_damage, body_injuries, moral_damage (números ou strings conforme o texto)
    - customer: name, document (CPF só dígitos), birth_date (YYYY-MM-DD), sex ("male"|"female"), email, cellphone, social_name
    - main_driver: mesmos conceitos + profession, marital_status, relationship (ex.: "himself")
    - vehicle: brand, model, plate (OBRIGATÓRIO se preencher: exatamente 7 caracteres após remover hífen — antiga AAA9999 ou Mercosul AAA9A99; NUNCA fragmentos tipo "DAP-9"),
      chassis, manufacture_year, model_year, circulation_zip_code (CEP com hífen se possível),
      fuel_type (ex.: "gasoline"), vehicle_type ("car"), category_type (ex.: "particular"), fipe_code, fipe_value (número),
      zero_km, alienated, gas_kit, armored, chassis_relabeled, anti_theft (boolean)

    ERROS COMUNS DE OCR — corrija antes de preencher JSON (customer.email, main_driver sem email duplicado se não houver):
    - E-mail: o símbolo @ é lido como "|" (pipe), "Q" colado ao domínio (ex.: "nome|QGMAIL.COM" → "nome@gmail.com"), ou confundido com O/0/G.
      Sempre devolva e-mail válido no formato local@dominio.ext (minúsculas no domínio), com @ obrigatório.
      Exemplos: "ROSE|GMAIL.COM" → "rose@gmail.com"; "RVELLI|QGMAIL.COM" → "rvelli@gmail.com" só se o nome no documento bater; se claramente ROSECARVELLI@GMAIL.COM no contexto, reconstrua o local a partir do nome + domínio corrigido.
      Se aparecer "(at)" ou "[at]" no texto, substitua por @.
    - Nome: linhas quebradas podem cortar o início ("emary" → "Rosemary"); use o cabeçalho da apólice e consistência com CPF/e-mail para recuperar nome completo quando óbvio.
    - Placa: hífen/espços no meio; confusão O↔0, I↔1; confirme 7 caracteres nos formatos BR válidos ou use null.
    - Chassi (VIN): exatamente 17 caracteres alfanuméricos (A-Z 0-9, NUNCA letras I, O ou Q).
      OCR frequentemente confunde: S↔5, F↔E, I↔1, K↔X, 8↔B, 3↔8, 0↔O↔Q↔D.
      O 9º caractere é dígito verificador (0-9 ou X). Se o resultado tiver <17 ou >17 chars, ou contiver I/O/Q, tente corrigir com base no contexto (marca/modelo).
      Exemplo real de erro: "9BRBCSFISKB031368" (errado) → "9BRBC9F38K8031368" (correto para Toyota chassi BR).
      Se não conseguir garantir 17 chars válidos, use null em vez de enviar chassi errado.

    Regras:
    - Use null para qualquer campo desconhecido.
    - Não invente número de apólice, CI, bônus ou placa: se não estiver razoavelmente claro no texto, null.
    - Datas no formato ISO YYYY-MM-DD.
    - CPF no JSON sem pontuação (11 dígitos) se possível.
    - E-mail: nunca retorne string sem '@' em customer.email (use null se irreparável).
    - Responda só JSON válido, sem markdown.
    """
  end

  defp truncate(s) when is_binary(s) and byte_size(s) > 400, do: binary_part(s, 0, 400) <> "..."
  defp truncate(s), do: s
end
