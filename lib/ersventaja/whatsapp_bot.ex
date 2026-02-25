defmodule Ersventaja.WhatsappBot do
  alias Ersventaja.Policies
  alias Ersventaja.Whatsapp.MetaApi

  @faq [
    {"oi",
     "Olá! Sou o assistente da RS Ventaja. Você pode:\n• Digitar *apólice* para baixar sua apólice (informando CPF/CNPJ)\n• Perguntar sobre *renovação*, *contato* ou *produtos*."},
    {"ola",
     "Olá! Sou o assistente da RS Ventaja. Você pode:\n• Digitar *apólice* para baixar sua apólice (informando CPF/CNPJ)\n• Perguntar sobre *renovação*, *contato* ou *produtos*."},
    {"menu",
     "Opções:\n• *apólice* – Baixar apólice (informe CPF ou CNPJ quando solicitado)\n• *renovação* – Informações sobre renovação\n• *contato* – Falar com a corretora\n• *produtos* – Conhecer nossos produtos"},
    {"renovação",
     "Para renovar sua apólice, entre em contato com a RS Ventaja pelo e-mail roberto@rsventaja.com ou pelo telefone. Temos prazer em ajudar!"},
    {"renovacao",
     "Para renovar sua apólice, entre em contato com a RS Ventaja pelo e-mail roberto@rsventaja.com ou pelo telefone. Temos prazer em ajudar!"},
    {"contato",
     "Contato RS Ventaja:\nE-mail: roberto@rsventaja.com\nVisite nosso site para mais informações."},
    {"contato ",
     "Contato RS Ventaja:\nE-mail: roberto@rsventaja.com\nVisite nosso site para mais informações."},
    {"produtos",
     "Trabalhamos com: Seguro Auto, Residencial, Empresarial, Responsabilidade Civil, Vida e Riscos Diversos. Para cotação ou dúvidas, fale conosco pelo e-mail roberto@rsventaja.com."},
    {"apólice",
     "Para enviar o link de download da sua apólice, *informe seu CPF ou CNPJ* (apenas números ou com pontuação)."},
    {"apolice",
     "Para enviar o link de download da sua apólice, *informe seu CPF ou CNPJ* (apenas números ou com pontuação)."},
    {"baixar",
     "Para enviar o link de download da sua apólice, *informe seu CPF ou CNPJ* (apenas números ou com pontuação)."},
    {"download",
     "Para enviar o link de download da sua apólice, *informe seu CPF ou CNPJ* (apenas números ou com pontuação)."}
  ]

  def process_webhook(%{"object" => "whatsapp_business_account", "entry" => entries}) do
    Enum.each(entries, &process_entry/1)
  end

  def process_webhook(_), do: :ok

  defp process_entry(%{"changes" => changes}) do
    Enum.each(changes, &process_change/1)
  end

  defp process_change(%{"value" => value, "field" => "messages"}) do
    messages = value["messages"] || []
    phone_number_id = value["metadata"]["phone_number_id"]
    require Logger
    Logger.info("[WhatsApp] Processing #{length(messages)} message(s)")
    Enum.each(messages, fn msg -> handle_message(phone_number_id, msg) end)
  end

  defp process_change(_), do: :ok

  defp handle_message(phone_number_id, %{
         "from" => from,
         "type" => "text",
         "text" => %{"body" => body}
       }) do
    reply = build_reply(String.trim(String.downcase(body)), from, phone_number_id)

    case MetaApi.send_text(phone_number_id, from, reply) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("[WhatsApp] Reply failed: #{inspect(reason)}")
    end
  end

  defp handle_message(phone_number_id, %{"from" => from}) do
    MetaApi.send_text(
      phone_number_id,
      from,
      "No momento só consigo responder a mensagens de texto. Envie *menu* para ver as opções."
    )
  end

  defp build_reply(text, _from, phone_number_id) do
    cond do
      looks_like_cpf_cnpj(text) -> reply_policy_by_cpf_cnpj(text, phone_number_id)
      true -> reply_faq_or_default(text)
    end
  end

  defp looks_like_cpf_cnpj(text) do
    digits = String.replace(text, ~r/[^0-9]/, "")
    len = String.length(digits)
    len == 11 or len == 14
  end

  defp reply_policy_by_cpf_cnpj(cpf_cnpj, _phone_number_id) do
    policies = Policies.get_policies_by_cpf_cnpj(cpf_cnpj)

    case policies do
      [] ->
        "Não encontrei apólice para o CPF/CNPJ informado. Verifique os dados ou entre em contato com a RS Ventaja: roberto@rsventaja.com"

      [one] ->
        base_url = base_download_url()
        token = Policies.generate_download_token(one.id)

        "Encontrei sua apólice. Clique no link para baixar (válido por 15 minutos):\n#{base_url}?token=#{token}"

      several ->
        lines =
          several
          |> Enum.with_index(1)
          |> Enum.map(fn {p, i} ->
            token = Policies.generate_download_token(p.id)

            "#{i}. #{p.detail || p.customer_name} (#{p.insurer || "N/A"}) – #{format_date(p.end_date)}\n   #{base_download_url()}?token=#{token}"
          end)

        "Encontrei #{length(several)} apólice(s). Use os links abaixo:\n\n" <>
          Enum.join(lines, "\n\n")
    end
  end

  defp base_download_url do
    case Application.get_env(:ersventaja, :whatsapp)[:base_url] do
      nil ->
        url = Application.get_env(:ersventaja, ErsventajaWeb.Endpoint)[:url] || []
        scheme = Keyword.get(url, :scheme, "https")
        host = Keyword.get(url, :host, "localhost")
        port = Keyword.get(url, :port)

        base =
          if port in [80, 443, nil],
            do: "#{scheme}://#{host}",
            else: "#{scheme}://#{host}:#{port}"

        "#{base}/api/policies/download"

      base when is_binary(base) ->
        base = String.trim_trailing(base, "/")
        "#{base}/api/policies/download"
    end
  end

  defp format_date(nil), do: "N/A"
  defp format_date(%Date{} = d), do: Calendar.strftime(d, "%d/%m/%Y")
  defp format_date(s) when is_binary(s), do: s

  defp reply_faq_or_default(text) do
    key = String.trim(text)

    case Enum.find(@faq, fn {k, _} -> key == k or String.starts_with?(key, k) end) do
      {_, reply} -> reply
      nil -> "Não entendi. Envie *menu* para ver as opções disponíveis."
    end
  end
end
