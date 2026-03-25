defmodule Ersventaja.Policies.OCR do
  @moduledoc """
  Extração de **texto bruto** a partir de PDF (pdftotext e, se necessário, Tesseract).

  Este módulo **não** interpreta campos da apólice a partir do texto: o papel do OCR é só
  gerar string para enviar à **LLM** (`GPTClient.extract_policy_info/2`, `Segfy.AutoPolicyExtractor`, etc.).
  Todos os campos estruturados vêm do modelo, não de regex/heurísticas no texto OCR.
  """

  alias Ersventaja.Policies.OCR.GPTClient

  @doc """
  Extracts policy information from a PDF file path.

  ## Parameters
  - `file_path`: Path to the PDF file
  - `insurers`: List of available insurers with id and name

  ## Returns
  - `{:ok, map}` with extracted policy information including:
    - `start_date`: Date struct or nil
    - `end_date`: Date struct or nil
    - `customer_cpf_or_cnpj`: String or nil
    - `customer_name`: String or nil
    - `customer_phone`: String or nil
    - `customer_email`: String or nil
    - `insurer_id`: Integer or nil
    - `license_plate`: String or nil
    - Additional fields as extracted by GPT
  - `{:error, reason}` on failure

  ## Examples

      iex> extract_policy_info("/path/to/file.pdf", [%{id: 1, name: "Porto Seguro"}])
      {:ok, %{
        start_date: ~D[2024-12-01],
        end_date: ~D[2025-12-01],
        customer_cpf_or_cnpj: "123.456.789-00",
        customer_name: "John Doe",
        customer_phone: "(11) 98765-4321",
        customer_email: "john@example.com",
        insurer_id: 1,
        license_plate: "ABC1234"
      }}
  """
  def extract_policy_info(file_path, insurers \\ [], insurance_types \\ [])

  def extract_policy_info(file_path, insurers, insurance_types) when is_binary(file_path) do
    file_path_str = to_string(file_path)

    if File.exists?(file_path_str) do
      try do
        result =
          with {:ok, text} <- extract_text(file_path_str),
               {:ok, info} <- parse_policy_info(text, insurers, insurance_types) do
            {:ok, info}
          else
            {:error, _reason} = error ->
              error
          end

        result
      rescue
        e ->
          {:error, {:ocr_error, Exception.message(e)}}
      end
    else
      {:error, {:ocr_error, "File not found: #{file_path_str}"}}
    end
  end

  def extract_policy_info(_, _, _), do: {:error, :invalid_input}

  @doc """
  Apenas texto bruto do PDF (`pdftotext` → fallback Tesseract). **Sem** parsing de campos.
  O resultado deve ir para uma LLM (`AutoPolicyExtractor`, etc.) — não usar este texto para inferir placa, CPF, etc. por heurística.
  """
  def extract_text_from_pdf(file_path) when is_binary(file_path) do
    extract_text(file_path)
  end

  def extract_text_from_pdf(_), do: {:error, :invalid_input}

  # Private functions

  defp extract_text(file_path) do
    require Logger
    file_path_str = to_string(file_path)

    # Verify file exists before attempting extraction
    if File.exists?(file_path_str) do
      Logger.info("[OCR STEP 1] Trying pdftotext for: #{file_path_str}")
      # First, try to extract text directly from PDF (much faster and more accurate)
      case extract_text_directly(file_path_str) do
        {:ok, text} when is_binary(text) and byte_size(text) > 50 ->
          # Got good text directly from PDF, use it
          Logger.info("[OCR STEP 2] pdftotext success, text size: #{byte_size(text)} bytes")
          {:ok, text}

        {:ok, text} when is_binary(text) ->
          # Got some text but it's too short, might be incomplete - try OCR as fallback
          Logger.info(
            "[OCR STEP 2] pdftotext returned short text (#{byte_size(text)} bytes), falling back to OCR"
          )

          extract_text_with_ocr(file_path_str)

        {:error, reason} ->
          # Direct extraction failed, fall back to OCR
          Logger.info("[OCR STEP 2] pdftotext failed: #{inspect(reason)}, falling back to OCR")
          extract_text_with_ocr(file_path_str)
      end
    else
      {:error, {:ocr_error, "Arquivo temporário não encontrado: #{file_path_str}"}}
    end
  end

  # Try to extract text directly from PDF using pdftotext (much faster and more accurate)
  defp extract_text_directly(file_path) do
    # Use pdftotext to extract text directly from PDF
    # -layout: preserve layout as much as possible
    # -enc UTF-8: output UTF-8 encoding
    case System.cmd("pdftotext", ["-layout", "-enc", "UTF-8", file_path, "-"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        text = String.trim(output)

        if String.length(text) > 0 do
          {:ok, text}
        else
          {:error, "No text extracted from PDF"}
        end

      {error_output, exit_code} ->
        error_msg = String.trim(error_output)
        {:error, "pdftotext failed (exit code: #{exit_code}): #{error_msg}"}
    end
  rescue
    e ->
      {:error, "Exception in pdftotext: #{Exception.message(e)}"}
  end

  # Fallback: Extract text using OCR (slower but works for scanned PDFs)
  defp extract_text_with_ocr(file_path) do
    require Logger
    Logger.info("[OCR FALLBACK] Starting pdftoppm conversion for: #{file_path}")
    # Convert PDF to images first (Tesseract can't read PDFs directly)
    case convert_pdf_to_image(file_path) do
      {:ok, image_paths} when is_list(image_paths) ->
        # Process all pages and combine the text
        Logger.info("[OCR TESSERACT] Starting Tesseract on #{length(image_paths)} images")

        try do
          texts =
            Enum.with_index(image_paths)
            |> Enum.map(fn {image_path, idx} ->
              Logger.info(
                "[OCR TESSERACT] Processing image #{idx + 1}/#{length(image_paths)}: #{image_path}"
              )

              # Use Portuguese language for better OCR accuracy with PT-BR dates
              TesseractOcr.read(image_path, %{lang: "por"})
            end)

          # Combine all pages with page separators
          combined_text = texts |> Enum.join("\n\n--- PÁGINA ---\n\n")

          # Clean up all image files
          Enum.each(image_paths, &File.rm/1)

          {:ok, combined_text}
        rescue
          e ->
            # Clean up image files on error
            Enum.each(image_paths, fn path -> if File.exists?(path), do: File.rm(path) end)

            error_msg =
              case e do
                %ErlangError{original: :enoent} ->
                  "Tesseract OCR não está instalado ou não está no PATH. Por favor, instale o Tesseract OCR."

                _ ->
                  Exception.message(e)
              end

            {:error, {:ocr_error, error_msg}}
        catch
          :exit, {:shutdown, {:enoent, _}} ->
            Enum.each(image_paths, fn path -> if File.exists?(path), do: File.rm(path) end)

            {:error,
             {:ocr_error,
              "Tesseract OCR não está instalado ou não está no PATH. Por favor, instale o Tesseract OCR."}}

          :exit, reason ->
            Enum.each(image_paths, fn path -> if File.exists?(path), do: File.rm(path) end)
            {:error, {:ocr_exit, reason}}
        end

      {:ok, single_image_path} when is_binary(single_image_path) ->
        # Backward compatibility: handle single image path
        try do
          text = TesseractOcr.read(single_image_path, %{lang: "por"})
          File.rm(single_image_path)
          {:ok, text}
        rescue
          e ->
            File.rm(single_image_path)

            error_msg =
              case e do
                %ErlangError{original: :enoent} ->
                  "Tesseract OCR não está instalado ou não está no PATH. Por favor, instale o Tesseract OCR."

                _ ->
                  Exception.message(e)
              end

            {:error, {:ocr_error, error_msg}}
        catch
          :exit, {:shutdown, {:enoent, _}} ->
            File.rm(single_image_path)

            {:error,
             {:ocr_error,
              "Tesseract OCR não está instalado ou não está no PATH. Por favor, instale o Tesseract OCR."}}

          :exit, reason ->
            File.rm(single_image_path)
            {:error, {:ocr_exit, reason}}
        end

      {:error, reason} ->
        {:error, {:ocr_error, "Erro ao converter PDF para imagem: #{inspect(reason)}"}}
    end
  end

  defp convert_pdf_to_image(pdf_path) do
    require Logger
    # Generate output image path
    base_path = pdf_path |> String.replace(".pdf", "")
    dir = Path.dirname(base_path)
    base_name = Path.basename(base_path)
    output_path = Path.join(dir, "#{base_name}_page")

    file_size = File.stat!(pdf_path).size

    # Use pdftoppm to convert ALL pages of PDF to PNG
    # -png: output format
    # -r 300: resolution (300 DPI for best OCR quality)
    Logger.info(
      "[OCR FALLBACK] Running pdftoppm (all pages, 300 DPI) for: #{pdf_path} (#{div(file_size, 1024)}KB)"
    )

    result =
      System.cmd("pdftoppm", ["-png", "-r", "300", pdf_path, output_path], stderr_to_stdout: true)

    Logger.info("[OCR FALLBACK] pdftoppm finished with result: #{inspect(result)}")

    case result do
      {output, 0} ->
        # pdftoppm outputs multiple files: output_path-01.png, output_path-02.png, etc.
        # Find all created image files
        case File.ls(dir) do
          {:ok, files} ->
            image_files =
              files
              |> Enum.filter(fn f ->
                String.starts_with?(f, Path.basename(output_path)) &&
                  String.ends_with?(f, ".png")
              end)
              |> Enum.sort()
              |> Enum.map(&Path.join(dir, &1))

            if length(image_files) > 0 do
              Logger.info("[OCR FALLBACK] Found #{length(image_files)} image files")
              {:ok, image_files}
            else
              Logger.error("[OCR FALLBACK] No image files found! Output: #{String.trim(output)}")
              {:error, "Nenhuma imagem convertida encontrada. Output: #{String.trim(output)}"}
            end

          {:error, _} ->
            {:error, "Erro ao listar arquivos do diretório. Output: #{String.trim(output)}"}
        end

      {error_output, exit_code} ->
        error_msg = String.trim(error_output)
        {:error, "Erro ao converter PDF (exit code: #{exit_code}): #{error_msg}"}
    end
  rescue
    e ->
      {:error, "Exceção ao converter PDF: #{Exception.message(e)}"}
  end

  defp parse_policy_info(text, insurers, insurance_types) do
    require Logger
    Logger.info("[OCR STEP 3] Starting GPT extraction, text size: #{byte_size(text)} bytes")
    result = GPTClient.extract_policy_info(text, insurers, insurance_types)
    Logger.info("[OCR STEP 4] GPT extraction complete")

    case result do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, {:parsing_error, reason}}
    end
  end
end
