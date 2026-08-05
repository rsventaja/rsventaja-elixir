defmodule Ersventaja.WhatsappBot do
  alias Ersventaja.Lgpd
  alias Ersventaja.Policies
  alias Ersventaja.Whatsapp.MetaApi

  # ETS table for tracking pending consent state per phone number.
  # Key = whatsapp phone number string, Value = %{cpf_cnpj: "...", timestamp: DateTime}
  @pending_consent_table :whatsapp_pending_consent

  @faq [
    {"oi",
     "Olá! Sou o assistente da RS Ventaja. Você pode:\n• Digitar *apólice* para baixar sua apólice (informando CPF/CNPJ)\n• Perguntar sobre *renovação*, *contato* ou *produtos*."},
    {"ola",
     "Olá! Sou o assistente da RS Ventaja. Você pode:\n• Digitar *apólice* para baixar sua apólice (informando CPF/CNPJ)\n• Perguntar sobre *renovação*, *contato* ou *produtos*."},
    {"menu",
     "Opções:\n• *apólice* – Baixar apólice (informe CPF ou CNPJ quando solicitado)\n• *renovação* – Informações sobre renovação\n• *contato* – Falar com a corretora\n• *produtos* – Conhecer nossos produtos\n• *revogar* – Revogar autorização LGPD"},
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

  # ---------------------------------------------------------------------------
  # ETS table lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Initializes the ETS table for pending consent state.
  Called from Application.start/2.
  """
  def init do
    unless :ets.whereis(@pending_consent_table) != :undefined do
      @pending_consent_table =
        :ets.new(@pending_consent_table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Webhook processing
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Reply routing — consent check before policy lookup
  # ---------------------------------------------------------------------------

  defp build_reply(text, from, phone_number_id) do
    cond do
      # Revocation command — any time
      String.starts_with?(text, "revogar") ->
        reply_revoke_consent(from)

      # Consent response ("sim") while there's a pending consent for this phone
      is_consent_affirmative(text) and has_pending_consent(from) ->
        reply_give_consent_and_policies(from, phone_number_id)

      # Consent refusal ("não") while there's a pending consent for this phone
      is_consent_refusal(text) and has_pending_consent(from) ->
        reply_consent_refused(from)

      # CPF/CNPJ detected — check consent first
      looks_like_cpf_cnpj(text) ->
        reply_check_consent_then_policies(text, from, phone_number_id)

      # Fallback to FAQ
      true ->
        reply_faq_or_default(text)
    end
  end

  # ---------------------------------------------------------------------------
  # Consent helpers
  # ---------------------------------------------------------------------------

  defp is_consent_affirmative(text) do
    text in ["sim", "s", "sí", "si", "aceito", "autorizo", "concordo", "ok", "yes", "y"]
  end

  defp is_consent_refusal(text) do
    text in ["não", "nao", "n", "negar", "recuso", "no", "nope", "negativo"]
  end

  # ---------------------------------------------------------------------------
  # Pending consent state (ETS-backed)
  # ---------------------------------------------------------------------------

  defp has_pending_consent(from) do
    case :ets.lookup(@pending_consent_table, from) do
      [{^from, _}] -> true
      [] -> false
    end
  end

  defp get_pending_consent(from) do
    case :ets.lookup(@pending_consent_table, from) do
      [{^from, data}] -> data
      [] -> nil
    end
  end

  defp set_pending_consent(from, cpf_cnpj) do
    :ets.insert(@pending_consent_table, {from, %{cpf_cnpj: cpf_cnpj, timestamp: DateTime.utc_now()}})
  end

  defp clear_pending_consent(from) do
    :ets.delete(@pending_consent_table, from)
  end

  # ---------------------------------------------------------------------------
  # Core reply handlers
  # ---------------------------------------------------------------------------

  # User wants to revoke consent
  defp reply_revoke_consent(from) do
    # We need the CPF to revoke — if there's a pending consent, use that.
    # Otherwise, tell the user to send their CPF to revoke.
    case get_pending_consent(from) do
      %{cpf_cnpj: cpf} ->
        case Lgpd.revoke_consent(cpf, from, "Solicitado pelo titular via WhatsApp") do
          {:ok, _} ->
            clear_pending_consent(from)
            "✅ Autorização LGPD revogada com sucesso. Seus dados não serão mais utilizados. " <>
              "Para consultar apólices novamente, será necessário autorizar novamente."

          {:error, :not_found} ->
            "Não há autorização LGPD ativa para este CPF neste número. Nenhuma ação necessária."
        end

      nil ->
        "Para revogar sua autorização LGPD, *informe seu CPF ou CNPJ*. " <>
          "Assim que identificarmos seu cadastro, a revogação será processada."
    end
  end

  # User said "sim" to consent — record and proceed
  defp reply_give_consent_and_policies(from, _phone_number_id) do
    %{cpf_cnpj: cpf} = get_pending_consent(from)

    case Lgpd.give_consent(cpf, from) do
      {:ok, _consent} ->
        clear_pending_consent(from)
        # Now look up policies with the consented CPF
        policies = Policies.get_policies_by_cpf_cnpj(cpf)

        case policies do
          [] ->
            "✅ Autorização LGPD registrada. " <>
              "Não encontrei apólice para o CPF informado. " <>
              "Verifique os dados ou entre em contato: roberto@rsventaja.com"

          [one] ->
            base_url = base_download_url()
            token = Policies.generate_download_token(one.id)
            "✅ Autorização LGPD registrada. " <>
              "Encontrei sua apólice. Clique no link para baixar (válido por 15 minutos):\n#{base_url}?token=#{token}"

          several ->
            base_url = base_download_url()
            lines =
              several
              |> Enum.with_index(1)
              |> Enum.map(fn {p, i} ->
                token = Policies.generate_download_token(p.id)
                "#{i}. #{p.detail || p.customer_name} (#{p.insurer || "N/A"}) – #{format_date(p.end_date)}\n   #{base_url}?token=#{token}"
              end)
            "✅ Autorização LGPD registrada. " <>
              "Encontrei #{length(several)} apólice(s):\n\n#{Enum.join(lines, "\n\n")}"
        end

      {:error, _changeset} ->
        "❌ Não foi possível registrar sua autorização. Tente novamente ou entre em contato: roberto@rsventaja.com"
    end
  end

  # User sent CPF/CNPJ — check consent first
  defp reply_check_consent_then_policies(text, from, _phone_number_id) do
    digits = String.replace(text, ~r/[^0-9]/, "")

    if Lgpd.has_consent?(digits, from) do
      # Consent already on file for this (CPF, phone) pair — proceed directly
      reply_policy_by_cpf_cnpj(text, nil)
    else
      # No consent — store pending and ask
      set_pending_consent(from, digits)
      Lgpd.consent_text()
    end
  end

  # Refusal
  defp reply_consent_refused(from) do
    clear_pending_consent(from)
    "Você optou por não autorizar o tratamento dos seus dados. " <>
      "Sem essa autorização, não posso consultar suas apólices. " <>
      "Caso mude de ideia, envie seu CPF novamente. " <>
      "Para falar com a corretora: roberto@rsventaja.com"
  end

  # ---------------------------------------------------------------------------
  # Existing helpers (unchanged)
  # ---------------------------------------------------------------------------

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
