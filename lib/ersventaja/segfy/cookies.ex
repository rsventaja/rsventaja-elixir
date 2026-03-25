defmodule Ersventaja.Segfy.Cookies do
  @moduledoc false
  # Mescla `Set-Cookie` de respostas HTTP no header `Cookie` (comportamento de browser em redirects).

  @doc """
  Junta os pares `name=value` dos headers `Set-Cookie` da resposta ao `Cookie` já usado no request.

  Necessário ao seguir redirects manualmente no Gestão; sem isso `ASP.NET_SessionId` etc. não atualizam
  e o servidor fica em loop 302 (login/sessão).
  """
  def merge_set_cookies_into_header(existing_cookie, response_headers)
      when is_list(response_headers) do
    existing = if is_binary(existing_cookie), do: existing_cookie, else: ""
    addition = set_cookie_header_value(response_headers)

    cond do
      addition == "" ->
        existing

      existing == "" ->
        addition

      true ->
        merge_cookie_header_strings(existing, addition)
    end
  end

  defp set_cookie_header_value(headers) when is_list(headers) do
    headers
    |> Enum.filter(fn {k, _} -> String.downcase(to_string(k)) == "set-cookie" end)
    |> Enum.map(fn {_, v} -> cookie_name_value_pair(v) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join("; ")
  end

  defp cookie_name_value_pair(set_cookie) when is_binary(set_cookie) do
    set_cookie
    |> String.split(";")
    |> List.first()
    |> case do
      nil -> nil
      pair -> String.trim(pair)
    end
  end

  defp cookie_name_value_pair(_), do: nil

  defp merge_cookie_header_strings(existing, addition)
       when is_binary(existing) and is_binary(addition) do
    m = Map.merge(cookie_header_to_map(existing), cookie_header_to_map(addition))
    map_to_cookie_header(m)
  end

  defp cookie_header_to_map(s) when is_binary(s) do
    s
    |> String.split(";")
    |> Enum.reduce(%{}, fn part, acc ->
      part = String.trim(part)

      case String.split(part, "=", parts: 2) do
        [k, v] when k != "" -> Map.put(acc, String.trim(k), String.trim(v))
        _ -> acc
      end
    end)
  end

  defp map_to_cookie_header(map) when map == %{}, do: ""

  defp map_to_cookie_header(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("; ", fn {k, v} -> k <> "=" <> v end)
  end
end
