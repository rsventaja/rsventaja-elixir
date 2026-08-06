defmodule Ersventaja.WhatsappBot do
  alias Ersventaja.Lgpd
  alias Ersventaja.Policies
  alias Ersventaja.Whatsapp.MetaApi
  require Logger

  # ETS table for tracking pending consent state per phone number.
  # Key = whatsapp phone number string, Value = %{cpf_cnpj: "...", timestamp: DateTime}
  @pending_consent_table :whatsapp_pending_consent

  # Interactive message IDs — must match between sent messages and webhook replies
  @list_id_apolice "apolice"
  @list_id_renovacao "renovacao"
  @list_id_contato "contato"
  @list_id_produtos "produtos"
  @list_id_revogar "revogar"
  @btn_id_consent_sim "consent_sim"
  @btn_id_consent_nao "consent_nao"

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
    Logger.info("[WhatsApp] Processing #{length(messages)} message(s)")
    Enum.each(messages, fn msg -> handle_message(phone_number_id, msg) end)
  end

  defp process_change(_), do: :ok

  # ---------------------------------------------------------------------------
  # Message routing — dispatches by message type
  # ---------------------------------------------------------------------------

  defp handle_message(phone_number_id, %{
         "from" => from,
         "type" => "text",
         "text" => %{"body" => body}
       }) do
    text = String.trim(String.downcase(body))
    handle_text_message(phone_number_id, from, text)
  end

  defp handle_message(phone_number_id, %{
         "from" => from,
         "type" => "interactive",
         "interactive" => interactive
       }) do
    handle_interactive_message(phone_number_id, from, interactive)
  end

  defp handle_message(phone_number_id, %{"from" => from}) do
    MetaApi.send_text(
      phone_number_id,
      from,
      "No momento só consigo responder a mensagens de texto ou botões interativos. " <>
        "Toque nos botões ou envie *menu* para ver as opções."
    )
  end

  # ---------------------------------------------------------------------------
  # Text message handlers (maintained as fallback)
  # ---------------------------------------------------------------------------

  defp handle_text_message(phone_number_id, from, text) do
    cond do
      # Revocation command — any time
      String.starts_with?(text, "revogar") ->
        handle_revoke(phone_number_id, from)

      # Consent response ("sim") while there's a pending consent for this phone
      is_consent_affirmative(text) and has_pending_consent(from) ->
        give_consent_and_send_policies(phone_number_id, from)

      # Consent refusal ("não") while there's a pending consent for this phone
      is_consent_refusal(text) and has_pending_consent(from) ->
        handle_consent_refused(phone_number_id, from)

      # CPF/CNPJ detected — check consent first
      looks_like_cpf_cnpj(text) ->
        check_consent_then_policies(phone_number_id, from, text)

      # Menu / help keywords — send interactive menu
      text in [
        "menu",
        "oi",
        "ola",
        "olá",
        "help",
        "ajuda",
        "inicio",
        "início",
        "comecar",
        "começar"
      ] ->
        send_main_menu(phone_number_id, from)

      # Old FAQ keyword fallbacks — still respond with relevant info
      text in ["renovação", "renovacao"] ->
        send_renovacao_info(phone_number_id, from)

      text in ["contato", "contato "] ->
        send_contato_info(phone_number_id, from)

      text in ["produtos"] ->
        send_produtos_info(phone_number_id, from)

      text in ["apólice", "apolice", "baixar", "download"] ->
        ask_for_cpf(phone_number_id, from)

      # Default — send the interactive menu
      true ->
        send_main_menu(phone_number_id, from)
    end
  end

  # ---------------------------------------------------------------------------
  # Interactive message handlers (button_reply + list_reply)
  # ---------------------------------------------------------------------------

  defp handle_interactive_message(phone_number_id, from, %{
         "type" => "button_reply",
         "button_reply" => %{"id" => btn_id}
       }) do
    case btn_id do
      @btn_id_consent_sim ->
        give_consent_and_send_policies(phone_number_id, from)

      @btn_id_consent_nao ->
        handle_consent_refused(phone_number_id, from)

      _ ->
        send_main_menu(phone_number_id, from)
    end
  end

  defp handle_interactive_message(phone_number_id, from, %{
         "type" => "list_reply",
         "list_reply" => %{"id" => list_id}
       }) do
    case list_id do
      @list_id_apolice ->
        ask_for_cpf(phone_number_id, from)

      @list_id_renovacao ->
        send_renovacao_info(phone_number_id, from)

      @list_id_contato ->
        send_contato_info(phone_number_id, from)

      @list_id_produtos ->
        send_produtos_info(phone_number_id, from)

      @list_id_revogar ->
        handle_revoke(phone_number_id, from)

      _ ->
        send_main_menu(phone_number_id, from)
    end
  end

  defp handle_interactive_message(phone_number_id, from, _),
    do: send_main_menu(phone_number_id, from)

  # ---------------------------------------------------------------------------
  # Menu (interactive list message)
  # ---------------------------------------------------------------------------

  defp send_main_menu(phone_number_id, from) do
    sections = [
      %{
        title: "Menu principal",
        rows: [
          %{id: @list_id_apolice, title: "📋 Baixar apólice", description: "Informe seu CPF/CNPJ"},
          %{id: @list_id_renovacao, title: "🔄 Renovação", description: "Saiba como renovar"},
          %{id: @list_id_contato, title: "📞 Contato", description: "Fale com a corretora"},
          %{id: @list_id_produtos, title: "🛡️ Produtos", description: "Conheça nossos seguros"},
          %{
            id: @list_id_revogar,
            title: "🔒 Revogar LGPD",
            description: "Revogar autorização de dados"
          }
        ]
      }
    ]

    MetaApi.send_interactive_list(
      phone_number_id,
      from,
      "Olá! Sou o assistente da *RS Ventaja*. Como posso ajudar?",
      "Ver opções",
      sections,
      footer: "Toque no botão para abrir o menu"
    )
  end

  # ---------------------------------------------------------------------------
  # Apólice flow — ask for CPF → consent → send documents
  # ---------------------------------------------------------------------------

  defp ask_for_cpf(phone_number_id, from) do
    MetaApi.send_text(
      phone_number_id,
      from,
      "Para localizar sua apólice, *informe seu CPF ou CNPJ* (apenas números ou com pontuação)."
    )
  end

  defp check_consent_then_policies(phone_number_id, from, text) do
    digits = String.replace(text, ~r/[^0-9]/, "")

    if Lgpd.has_consent?(digits, from) do
      # Consent already on file — proceed directly to find and send policies
      send_active_policies(phone_number_id, from, digits)
    else
      # No consent — store pending and ask via interactive buttons
      set_pending_consent(from, digits)
      send_consent_buttons(phone_number_id, from)
    end
  end

  defp send_consent_buttons(phone_number_id, from) do
    MetaApi.send_interactive_buttons(
      phone_number_id,
      from,
      Lgpd.consent_text(),
      [
        %{id: @btn_id_consent_sim, title: "✅ Sim, autorizo"},
        %{id: @btn_id_consent_nao, title: "❌ Não autorizo"}
      ]
    )
  end

  defp give_consent_and_send_policies(phone_number_id, from) do
    case get_pending_consent(from) do
      %{cpf_cnpj: cpf} ->
        case Lgpd.give_consent(cpf, from) do
          {:ok, _consent} ->
            clear_pending_consent(from)
            MetaApi.send_text(phone_number_id, from, "✅ Autorização LGPD registrada com sucesso.")
            send_active_policies(phone_number_id, from, cpf)

          {:error, _changeset} ->
            MetaApi.send_text(
              phone_number_id,
              from,
              "❌ Não foi possível registrar sua autorização. Tente novamente ou entre em contato: roberto@rsventaja.com"
            )
        end

      nil ->
        # No pending consent — user might have clicked an old button
        send_main_menu(phone_number_id, from)
    end
  end

  defp send_active_policies(phone_number_id, from, cpf_cnpj) do
    policies = Policies.get_active_policies_by_cpf_cnpj(cpf_cnpj)

    case policies do
      [] ->
        MetaApi.send_text(
          phone_number_id,
          from,
          "Não encontrei *apólices vigentes* para o CPF/CNPJ informado. " <>
            "Verifique os dados ou entre em contato: roberto@rsventaja.com\n\n" <>
            "Dica: você pode ter apólices vencidas que não aparecem aqui. " <>
            "Entre em contato com a corretora para mais informações."
        )

      [single_policy] ->
        # Single active policy — send the PDF directly via WhatsApp
        send_policy_document(phone_number_id, from, single_policy)

      several ->
        # Multiple active policies — send summary with links
        send_policies_summary(phone_number_id, from, several)
    end
  end

  # ---------------------------------------------------------------------------
  # Send a single policy PDF directly via WhatsApp
  # ---------------------------------------------------------------------------

  defp send_policy_document(phone_number_id, from, policy) do
    # Build a user-friendly filename
    filename =
      [policy.customer_name, policy.detail, policy.insurer]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" - ")
      |> then(fn s -> String.replace(s, ~r/[\/\\:*?"<>|]/, "_") end)
      |> then(fn s -> "#{s}.pdf" end)

    caption =
      case policy.end_date do
        %Date{} = d -> "Vigente até #{Calendar.strftime(d, "%d/%m/%Y")}"
        s when is_binary(s) -> "Vigente até #{s}"
        _ -> "Apólice vigente"
      end

    case Policies.download_policy_file(policy.file_name) do
      {:ok, file_binary} ->
        case MetaApi.upload_media(phone_number_id, file_binary, "application/pdf") do
          {:ok, media_id} ->
            MetaApi.send_document(phone_number_id, from, {:media_id, media_id},
              filename: filename,
              caption: caption
            )

          {:error, _reason} ->
            Logger.warning("[WhatsApp] Media upload failed for policy #{policy.id}")

            MetaApi.send_text(
              phone_number_id,
              from,
              "❌ Não foi possível enviar sua apólice no momento. " <>
                "Tente novamente ou entre em contato: roberto@rsventaja.com"
            )
        end

      {:error, _reason} ->
        Logger.warning("[WhatsApp] S3 download failed for policy #{policy.id}")

        MetaApi.send_text(
          phone_number_id,
          from,
          "❌ Não foi possível localizar o arquivo da sua apólice. " <>
            "Entre em contato: roberto@rsventaja.com"
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple policies — summary with links
  # ---------------------------------------------------------------------------

  defp send_policies_summary(phone_number_id, from, policies) do
    base_url = base_download_url()

    # Send a header text first
    MetaApi.send_text(
      phone_number_id,
      from,
      "🔍 Encontrei *#{length(policies)} apólice(s) vigente(s)*:"
    )

    # Send each policy's link as a separate message (better UX on WhatsApp)
    policies
    |> Enum.with_index(1)
    |> Enum.each(fn {policy, idx} ->
      token = Policies.generate_download_token(policy.id)
      insurer = policy.insurer || "N/A"
      end_date = format_date(policy.end_date)

      MetaApi.send_text(
        phone_number_id,
        from,
        "*#{idx}. #{policy.detail || policy.customer_name}*\n" <>
          "Seguradora: #{insurer}\n" <>
          "Vigente até: #{end_date}\n" <>
          "📄 #{base_url}?token=#{token}"
      )
    end)
  end

  # ---------------------------------------------------------------------------
  # Revoke consent
  # ---------------------------------------------------------------------------

  defp handle_revoke(phone_number_id, from) do
    case get_pending_consent(from) do
      %{cpf_cnpj: cpf} ->
        case Lgpd.revoke_consent(cpf, from, "Solicitado pelo titular via WhatsApp") do
          {:ok, _} ->
            clear_pending_consent(from)

            MetaApi.send_text(
              phone_number_id,
              from,
              "✅ Autorização LGPD revogada com sucesso. Seus dados não serão mais utilizados. " <>
                "Para consultar apólices novamente, será necessário autorizar novamente."
            )

          {:error, :not_found} ->
            MetaApi.send_text(
              phone_number_id,
              from,
              "Não há autorização LGPD ativa para este CPF neste número. Nenhuma ação necessária."
            )
        end

      nil ->
        MetaApi.send_text(
          phone_number_id,
          from,
          "Para revogar sua autorização LGPD, *informe seu CPF ou CNPJ*. " <>
            "Assim que identificarmos seu cadastro, a revogação será processada."
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Consent refusal
  # ---------------------------------------------------------------------------

  defp handle_consent_refused(phone_number_id, from) do
    clear_pending_consent(from)

    MetaApi.send_text(
      phone_number_id,
      from,
      "Você optou por não autorizar o tratamento dos seus dados. " <>
        "Sem essa autorização, não posso consultar suas apólices. " <>
        "Caso mude de ideia, envie seu CPF novamente. " <>
        "Para falar com a corretora: roberto@rsventaja.com"
    )
  end

  # ---------------------------------------------------------------------------
  # Informational responses
  # ---------------------------------------------------------------------------

  defp send_renovacao_info(phone_number_id, from) do
    MetaApi.send_text(
      phone_number_id,
      from,
      "🔄 *Renovação de Apólice*\n\n" <>
        "Para renovar sua apólice, entre em contato com a RS Ventaja " <>
        "pelo e-mail roberto@rsventaja.com ou pelo telefone. " <>
        "Temos prazer em ajudar!"
    )
  end

  defp send_contato_info(phone_number_id, from) do
    MetaApi.send_text(
      phone_number_id,
      from,
      "📞 *Contato RS Ventaja*\n\n" <>
        "E-mail: roberto@rsventaja.com\n" <>
        "Visite nosso site para mais informações."
    )
  end

  defp send_produtos_info(phone_number_id, from) do
    MetaApi.send_text(
      phone_number_id,
      from,
      "🛡️ *Nossos Produtos*\n\n" <>
        "Trabalhamos com: Seguro Auto, Residencial, Empresarial, " <>
        "Responsabilidade Civil, Vida e Riscos Diversos.\n\n" <>
        "Para cotação ou dúvidas, fale conosco pelo e-mail roberto@rsventaja.com."
    )
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
    :ets.insert(
      @pending_consent_table,
      {from, %{cpf_cnpj: cpf_cnpj, timestamp: DateTime.utc_now()}}
    )
  end

  defp clear_pending_consent(from) do
    :ets.delete(@pending_consent_table, from)
  end

  # ---------------------------------------------------------------------------
  # CPF/CNPJ detection
  # ---------------------------------------------------------------------------

  defp looks_like_cpf_cnpj(text) do
    digits = String.replace(text, ~r/[^0-9]/, "")
    len = String.length(digits)
    len == 11 or len == 14
  end

  # ---------------------------------------------------------------------------
  # URL & formatting helpers
  # ---------------------------------------------------------------------------

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
end
