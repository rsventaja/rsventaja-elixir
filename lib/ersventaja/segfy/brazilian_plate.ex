defmodule Ersventaja.Segfy.BrazilianPlate do
  @moduledoc """
  Placa veicular BR para o multicálculo Segfy: **7 caracteres** alfanuméricos, sem hífen no payload.

  - Formato **antigo**: `AAA9999` (3 letras + 4 dígitos)
  - **Mercosul**: `AAA9A99` (3 letras + dígito + letra + 2 dígitos)

  Valores como `DAP-9` (OCR/policy) são inválidos e não devem sobrescrever a placa vinda do `show`.
  """

  @old ~r/\A[A-Z]{3}[0-9]{4}\z/u
  @mercosul ~r/\A[A-Z]{3}[0-9][A-Z][0-9]{2}\z/u

  @doc """
  Remove separadores, caixa alta, valida padrão BR. Retorna placa **sem hífen** (ex.: `DAP0J59`).
  """
  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(s) when is_binary(s) do
    raw =
      s
      |> String.trim()
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]/u, "")

    cond do
      String.length(raw) != 7 ->
        :error

      Regex.match?(@old, raw) ->
        {:ok, raw}

      Regex.match?(@mercosul, raw) ->
        {:ok, raw}

      true ->
        :error
    end
  end

  def normalize(_), do: :error

  @doc false
  def valid?(s), do: match?({:ok, _}, normalize(s))

  @doc false
  def normalize_or_nil(s) do
    case normalize(s) do
      {:ok, p} -> p
      :error -> nil
    end
  end

  @doc """
  Primeira placa válida na ordem (ex.: `[atual, show, policy]`).
  Retorna `""` se nenhuma for válida.
  """
  @spec pick_first_valid_plate([term()]) :: String.t()
  def pick_first_valid_plate(candidates) when is_list(candidates) do
    Enum.find_value(candidates, fn c ->
      case normalize(c) do
        {:ok, p} -> p
        :error -> nil
      end
    end) || ""
  end
end
