defmodule Ersventaja.Segfy.EmailFix do
  @moduledoc """
  Corrige e-mails danificados por OCR antes do Segfy (ex.: `@` lido como `|` ou `Q` colado ao domínio).

  Ex.: `ROSE|GMAIL.COM`, `RVELLI|QGMAIL.COM` → endereço com `@` e domínio usual.
  """

  require Logger

  @doc """
  Tenta reparar `s`; se já parecer e-mail válido, só normaliza caixa do domínio.
  """
  @spec fix_ocr_email(term()) :: String.t()
  def fix_ocr_email(nil), do: ""

  def fix_ocr_email(s) when is_binary(s) do
    s = String.trim(s)
    if s == "", do: "", else: repair(s)
  end

  def fix_ocr_email(_), do: ""

  defp repair(s) do
    s = String.replace(s, ~r/\s*\(at\)\s*/iu, "@")
    s = String.replace(s, ~r/\s*\[at\]\s*/iu, "@")

    cond do
      simple_valid?(s) ->
        normalize_case(s)

      String.contains?(s, "|") ->
        case split_pipe_email(s) do
          {:ok, repaired} ->
            if repaired != s,
              do: Logger.debug("[Segfy EmailFix] pipe→@: #{inspect(s)} → #{inspect(repaired)}")

            normalize_case(repaired)

          :error ->
            s
        end

      true ->
        s
    end
  end

  defp simple_valid?(s) do
    String.contains?(s, "@") and
      String.match?(s, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u)
  end

  defp normalize_case(s) do
    case String.split(s, "@", parts: 2) do
      [local, domain] ->
        String.downcase(local) <> "@" <> String.downcase(domain)

      _ ->
        s
    end
  end

  defp split_pipe_email(s) do
    case String.split(s, "|", parts: 2) do
      [local, domain] ->
        local = String.trim(local)
        domain = domain |> String.trim() |> fix_leading_q_domain()

        if local != "" and domain != "" and String.contains?(domain, ".") do
          {:ok, local <> "@" <> domain}
        else
          :error
        end

      _ ->
        :error
    end
  end

  # OCR: "QGMAIL.COM" em vez de "GMAIL.COM" após "|"
  defp fix_leading_q_domain(domain) do
    d = String.downcase(domain)

    fixed =
      cond do
        String.starts_with?(d, "qgmail.") ->
          "gmail." <> String.slice(domain, 7..-1//1)

        String.starts_with?(d, "qhotmail.") ->
          "hotmail." <> String.slice(domain, 9..-1//1)

        String.starts_with?(d, "qoutlook.") ->
          "outlook." <> String.slice(domain, 9..-1//1)

        String.starts_with?(d, "qlive.") ->
          "live." <> String.slice(domain, 6..-1//1)

        String.starts_with?(d, "quol.") ->
          "uol." <> String.slice(domain, 5..-1//1)

        true ->
          domain
      end

    String.downcase(fixed)
  end
end
