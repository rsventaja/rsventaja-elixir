defmodule Ersventaja.Policies.OCR.GPTClient do
  @moduledoc """
  Client for OpenAI GPT API to extract structured policy information from OCR text.

  Uses GPT to parse OCR-extracted text and return structured data including:
  - start_date
  - end_date
  - customer_cpf
  - customer_name
  - customer_cellphone
  - customer_email
  - and other relevant policy information
  """

  @default_api_url "https://api.openai.com/v1/chat/completions"
  @default_model "gpt-4o-mini"

  defp api_url do
    case System.get_env("APP_LLM_BASE_URL") do
      nil -> @default_api_url
      "" -> @default_api_url
      base -> String.trim_trailing(base, "/") <> "/chat/completions"
    end
  end

  @doc """
  Extracts structured policy information from OCR text using GPT.

  ## Parameters
  - `text`: The OCR-extracted text from the policy document
  - `insurers`: List of available insurers with id and name

  ## Returns
  - `{:ok, map}` with extracted policy information
  - `{:error, reason}` on failure

  ## Example

      iex> extract_policy_info("OCR text here...", [%{id: 1, name: "Porto Seguro"}])
      {:ok, %{
        start_date: "2024-12-01",
        end_date: "2025-12-01",
        customer_cpf: "123.456.789-00",
        customer_name: "John Doe",
        customer_cellphone: "(11) 98765-4321",
        customer_email: "john@example.com",
        insurer_id: 1,
        license_plate: "ABC1234"
      }}
  """
  def extract_policy_info(text, insurers \\ [], insurance_types \\ [])

  def extract_policy_info(text, insurers, insurance_types) when is_binary(text) do
    api_key = get_api_key() || ""
    using_local_llm? = System.get_env("APP_LLM_BASE_URL") not in [nil, ""]

    if api_key == "" and not using_local_llm? do
      {:error, "OPENAI_API_KEY not found (set APP_LLM_BASE_URL for local LLM)"}
    else
      model = System.get_env("OPENAI_MODEL", @default_model)
      call_gpt_api(text, api_key, model, insurers, insurance_types)
    end
  end

  def extract_policy_info(_, _, _), do: {:error, "Invalid text input"}

  defp get_api_key do
    System.get_env("OPENAI_API_KEY")
  end

  defp call_gpt_api(text, api_key, model, insurers, insurance_types) do
    prompt = build_prompt(text)

    request_body = %{
      model: model,
      messages: [
        %{
          role: "system",
          content: system_prompt(insurers, insurance_types)
        },
        %{
          role: "user",
          content: prompt
        }
      ],
      response_format: %{type: "json_object"},
      temperature: 0.1
    }

    body = Jason.encode!(request_body)

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    # Configure timeout options for hackney
    # recv_timeout: 60 seconds (time to wait for response)
    # connect_timeout: 10 seconds (time to establish connection)
    hackney_options = [
      recv_timeout: 60_000,
      connect_timeout: 10_000,
      timeout: 60_000
    ]

    case :hackney.post(api_url(), headers, body, hackney_options) do
      {:ok, status_code, _headers, client_ref} when status_code in [200, 201] ->
        {:ok, response_body} = :hackney.body(client_ref)
        parse_response(response_body)

      {:ok, status_code, _headers, client_ref} ->
        {:ok, error_body} = :hackney.body(client_ref)
        {:error, "OpenAI API error (status #{status_code}): #{error_body}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp system_prompt(insurers, insurance_types) do
    insurers_list =
      insurers
      |> Enum.map(fn insurer ->
        id = Map.get(insurer, :id) || Map.get(insurer, "id")
        name = Map.get(insurer, :name) || Map.get(insurer, "name")
        "ID: #{id}, Name: #{name}"
      end)
      |> Enum.join("\n")

    insurers_section =
      if length(insurers) > 0 do
        """

        Seguradoras disponíveis no banco de dados:
        #{insurers_list}

        Você DEVE fazer correspondência do nome da seguradora no documento com uma dessas seguradoras e retornar o insurer_id correspondente.
        Se não conseguir encontrar correspondência, retorne null para insurer_id.

        ATENÇÃO CRÍTICA - SEGURADORAS DO GRUPO PORTO:
        Azul Seguros, Itaú Seguros e Mitsui Seguros pertencem ao grupo Porto Seguro, mas são seguradoras DISTINTAS com CNPJs e produtos diferentes.
        Documentos da Azul Seguros podem conter referências a "Porto Seguro" ou "Grupo Porto" no rodapé, cabeçalho ou dados corporativos, mas isso NÃO significa que a seguradora é Porto Seguro.
        Para classificar corretamente, siga esta ordem de prioridade:
        1. Procure o nome da seguradora no CABEÇALHO PRINCIPAL ou LOGO do documento (ex: "AZUL SEGUROS", "AZUL COMPANHIA DE SEGUROS GERAIS")
        2. Procure o CNPJ da seguradora e compare:
           - Porto Seguro: CNPJ 61.198.164/0001-60
           - Azul Seguros: CNPJ 33.448.150/0001-44 (Azul Companhia de Seguros Gerais)
           - Itaú Seguros: CNPJ 61.557.039/0001-07
        3. Se o documento mencionar "Azul" em destaque e "Porto Seguro" apenas como grupo controlador, a seguradora é AZUL, não Porto Seguro
        4. A mesma lógica se aplica a Itaú Seguros e Mitsui - referências ao grupo Porto não mudam a seguradora emissora
        """
      else
        ""
      end

    insurance_types_list =
      insurance_types
      |> Enum.map(fn type ->
        id = Map.get(type, :id) || Map.get(type, "id")
        name = Map.get(type, :name) || Map.get(type, "name")
        "ID: #{id}, Name: #{name}"
      end)
      |> Enum.join("\n")

    insurance_types_section =
      if length(insurance_types) > 0 do
        """

        Tipos de seguro disponíveis no banco de dados:
        #{insurance_types_list}

        Você DEVE identificar o tipo de seguro do documento e retornar o insurance_type_id correspondente.
        Dicas para identificação:
        - AUTOMÓVEL: documento menciona veículo, placa, chassi, FIPE, ou dados de condutor
        - RESIDENCIAL: documento menciona imóvel residencial, endereço de residência, cobertura para moradia
        - EMPRESARIAL: documento menciona empresa, CNPJ de estabelecimento, cobertura empresarial
        - RESPONSABILIDADE CIVIL: documento menciona RC, responsabilidade civil, profissional liberal
        - SEGURO DE VIDA: documento menciona vida, morte, invalidez, beneficiário pessoa física
        - RISCOS DIVERSOS: documento menciona equipamentos, celular, portáteis, ou não se encaixa nos outros tipos
        - CAPITALIZAÇÃO: documento menciona título de capitalização, sorteio, capitalização
        Se não conseguir identificar o tipo, retorne null para insurance_type_id.
        """
      else
        ""
      end

    """
    Você é um especialista em extrair informações estruturadas de documentos de apólices de seguro brasileiros.
    Extraia as seguintes informações do texto OCR fornecido e retorne como um objeto JSON.

    Campos obrigatórios:
    - start_date: Data de início da apólice no formato ISO (YYYY-MM-DD), ou null se não encontrado
    - end_date: Data de término da apólice no formato ISO (YYYY-MM-DD), ou null se não encontrado
    - customer_cpf_or_cnpj: CPF do cliente (formato XXX.XXX.XXX-XX) ou CNPJ (formato XX.XXX.XXX/XXXX-XX), ou null se não encontrado. ATENÇÃO: NÃO confunda com o CNPJ da seguradora. Procure por seções como "DADOS DO SEGURADO", "DADOS DO CLIENTE", "DADOS DO CONTRATANTE", "DADOS DO PROPONENTE". O CPF/CNPJ do cliente geralmente aparece próximo ao nome do cliente.
    - customer_name: Nome completo do cliente/segurado, ou null se não encontrado. Procure em seções como "DADOS DO SEGURADO", "NOME DO SEGURADO", "CLIENTE", "CONTRATANTE", "PROPONENTE". Geralmente aparece em letras maiúsculas.
    - customer_phone: Telefone do cliente. SEMPRE priorize telefone celular se disponível, caso contrário use telefone fixo. Aceite qualquer formato (com ou sem DDD, com ou sem código do país). Ou null se não encontrado. Procure por campos como "Telefone", "Celular", "Fone", "DDD" seguido de número.
    - customer_email: E-mail do cliente, ou null se não encontrado.
      OCR costuma errar o @: trate "|" (pipe) como @ quando separar parte local e domínio (ex.: "ROSECARVELLI|GMAIL.COM" → "ROSECARVELLI@GMAIL.COM").
      "Q" colado ao domínio após "|" é típico: "nome|QGMAIL.COM" → "nome@gmail.com" (corrija QGMAIL→gmail, QHOTMAIL→hotmail, etc.).
      Também corrija @ lido como O, 0, G ou Q no meio do endereço (ex.: "emailQgmail.com" → "email@gmail.com").
      Nunca retorne e-mail sem '@' válido; use null se não der para reconstruir com confiança.
      Sempre formato válido: local@dominio.extensão (minúsculas no domínio é aceitável).
    - insurer_id: ID da seguradora da lista de seguradoras disponíveis, ou null se não encontrado ou não conseguir fazer correspondência
    - insurance_type_id: ID do tipo de seguro da lista de tipos disponíveis, ou null se não conseguir identificar. Identifique o tipo com base no conteúdo do documento (veículo = automóvel, imóvel = residencial/empresarial, etc.)
    - license_plate: Placa do veículo (para seguro auto), ou null se não encontrado ou não aplicável. Esta informação deve ir no campo "detail" se for seguro de carro.
      ATENÇÃO CRÍTICA - VALIDAÇÃO OBRIGATÓRIA DE PLACAS: As placas brasileiras têm formatos MUITO ESPECÍFICOS e RÍGIDOS. Você DEVE validar rigorosamente ANTES de retornar qualquer valor:

      FORMATOS VÁLIDOS (apenas estes dois):
      * Formato antigo: EXATAMENTE 3 letras maiúsculas (A-Z) seguidas de EXATAMENTE 4 dígitos (0-9) - exemplo: ABC1234, XYZ9876, GEO1234
      * Formato Mercosul: EXATAMENTE 3 letras maiúsculas (A-Z) + EXATAMENTE 1 dígito (0-9) + EXATAMENTE 1 letra maiúscula (A-Z) + EXATAMENTE 2 dígitos (0-9) - exemplo: ABC1D23, XYZ9A45, GEO1F72

      REGRAS DE VALIDAÇÃO OBRIGATÓRIAS:
      1. A placa DEVE ter EXATAMENTE 7 caracteres (sem espaços, hífens ou outros separadores)
      2. Se tiver 4 letras seguidas, é INVÁLIDA - retorne null
      3. Se tiver mais ou menos de 7 caracteres, é INVÁLIDA - retorne null
      4. Se não corresponder EXATAMENTE a um dos dois formatos acima, é INVÁLIDA - retorne null
      5. Se o OCR ler caracteres incorretos, tente corrigir APENAS se o resultado corresponder a um dos formatos válidos
      6. Se não conseguir corrigir para um formato válido, retorne null (NÃO retorne valores inválidos)

      Exemplos de valores VÁLIDOS que DEVEM ser retornados:
      - "ERP0147" → VÁLIDO (3 letras + 4 dígitos = 7 caracteres, formato antigo válido) ✅
      - "ABC1234" → VÁLIDO (3 letras + 4 dígitos = 7 caracteres, formato antigo válido) ✅
      - "GEO1F72" → VÁLIDO (formato Mercosul válido) ✅

      Exemplos de valores INVÁLIDOS que DEVEM retornar null:
      - "ERPO0147" → INVÁLIDO (4 letras + 4 dígitos = 8 caracteres, formato incorreto) - MAS pode ser corrigido para "ERP0147"
      - "ABC123" → INVÁLIDO (só 6 caracteres)
      - "ABCD1234" → INVÁLIDO (4 letras + 4 dígitos = 8 caracteres)
      - "ABC12345" → INVÁLIDO (3 letras + 5 dígitos = 8 caracteres)
      - "AB1234" → INVÁLIDO (só 2 letras)

      Exemplos de correção válida (apenas se resultar em formato válido):
      - "ERPO0147" → "ERP0147" (remover letra O extra que é erro comum de OCR, formato antigo válido: 3 letras + 4 dígitos) ✅
      - "ABCI234" → "ABC1234" (I corrigido para 1, formato antigo válido)
      - "ABC0D23" → "ABC1D23" (0 corrigido para 1, formato Mercosul válido)
      - "ABCD1234" → tentar "ABC1234" (remover letra D extra, formato antigo válido)

      CORREÇÃO DE ERROS COMUNS DE OCR:
      - Se encontrar 4 letras seguidas + 4 dígitos (ex: "ERPO0147"), tente remover uma letra do meio para formar 3 letras + 4 dígitos
      - Se encontrar 3 letras + 5 dígitos, tente remover um dígito do meio para formar 3 letras + 4 dígitos
      - Se encontrar caracteres que parecem erros de OCR (I em vez de 1, O em vez de 0, etc.), corrija baseado nos formatos válidos
      - SEMPRE valide que o resultado final corresponde EXATAMENTE a um dos formatos válidos antes de retornar

      IMPORTANTE: Se você encontrar um valor que não corresponde aos formatos válidos e NÃO conseguir corrigir para um formato válido, retorne null. Mas SEMPRE tente corrigir erros comuns de OCR primeiro.

    Campos adicionais que você pode extrair se encontrados:
    - policy_number: Número da apólice/identificador
    - insurer_name: Nome da seguradora (para referência, mas use insurer_id)
    - premium_amount: Valor do prêmio da apólice
    - coverage_type: Tipo de cobertura do seguro

    Instruções importantes:
    - Retorne APENAS JSON válido, sem texto adicional
    - Use null para campos não encontrados (não strings vazias)
    - Datas devem estar no formato ISO (YYYY-MM-DD)
    - CPF deve estar formatado como XXX.XXX.XXX-XX
    - CNPJ deve estar formatado como XX.XXX.XXX/XXXX-XX
    - Números de telefone podem estar em qualquer formato encontrado no documento
    - Para seguro auto, extraia a placa do veículo e inclua no campo license_plate
    - Seja flexível com erros de OCR e tente extrair informações mesmo se o texto estiver ligeiramente corrompido
    - IMPORTANTE: Diferencie claramente entre dados do CLIENTE/SEGURADO e dados da SEGURADORA. O CNPJ da seguradora geralmente aparece em seções como "DADOS DA SEGURADORA" ou "DADOS DA SUCURSAL". O CPF/CNPJ do cliente aparece em seções sobre o segurado/cliente.
    - Para telefone: se houver múltiplos números (celular e fixo), SEMPRE retorne o celular. Celulares geralmente têm 9 dígitos após o DDD (formato: XX 9XXXX-XXXX ou similar).
    #{insurers_section}
    #{insurance_types_section}
    """
  end

  defp build_prompt(text) do
    """
    Extraia as informações da apólice do seguinte texto OCR extraído de um documento de apólice de seguro brasileiro:

    #{text}

    Retorne as informações extraídas como um objeto JSON com os campos especificados no prompt do sistema.
    """
  end

  defp parse_response(response_body) do
    case Jason.decode(response_body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        case Jason.decode(content) do
          {:ok, extracted_data} ->
            # Normalize the data and convert dates
            normalized_data = normalize_extracted_data(extracted_data)
            {:ok, normalized_data}

          {:error, reason} ->
            {:error, "Failed to parse GPT response JSON: #{inspect(reason)}"}
        end

      {:ok, %{"error" => error}} ->
        {:error, "OpenAI API error: #{inspect(error)}"}

      {:ok, _} ->
        {:error, "Unexpected response format from OpenAI API"}

      {:error, reason} ->
        {:error, "Failed to parse API response: #{inspect(reason)}"}
    end
  end

  defp normalize_extracted_data(data) when is_map(data) do
    # Convert date strings to Date structs if they exist
    # Keep string keys for JSON compatibility
    # Also normalize insurer_id to integer if present
    data
    |> maybe_parse_date("start_date")
    |> maybe_parse_date("end_date")
    |> maybe_parse_integer("insurer_id")
    |> maybe_parse_integer("insurance_type_id")
  end

  defp normalize_extracted_data(data), do: data

  defp maybe_parse_integer(data, key) when is_map(data) do
    case Map.get(data, key) do
      nil ->
        data

      value when is_integer(value) ->
        data

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int_value, _} -> Map.put(data, key, int_value)
          :error -> data
        end

      _ ->
        data
    end
  end

  defp maybe_parse_integer(data, _key), do: data

  defp maybe_parse_date(data, key) when is_map(data) do
    case Map.get(data, key) do
      nil ->
        data

      date_string when is_binary(date_string) ->
        case Date.from_iso8601(date_string) do
          {:ok, date} -> Map.put(data, key, date)
          {:error, _} -> data
        end

      _ ->
        data
    end
  end

  defp maybe_parse_date(data, _key), do: data
end
