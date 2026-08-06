defmodule Ersventaja.WhatsappBot do
  alias Ersventaja.Lgpd
  alias Ersventaja.Policies
  alias Ersventaja.Whatsapp.MetaApi
  require Logger

  # ETS table for tracking pending consent state per phone number.
  # Key = whatsapp phone number string, Value = %{cpf_cnpj: "...", timestamp: DateTime}
  @pending_consent_table :whatsapp_pending_consent

  # ETS table for tracking atendimento flow state per phone number.
  # Key = whatsapp phone number string,
  # Value = %{step: :waiting_cpf | :waiting_category | :waiting_details,
  #            cpf: "...", customer_name: "...", category: "..."}
  @atendimento_flow_table :whatsapp_atendimento_flow

  # Interactive message IDs — must match between sent messages and webhook replies
  @list_id_apolice "apolice"
  @list_id_renovacao "renovacao"
  @list_id_contato "contato"
  @list_id_produtos "produtos"
  @list_id_revogar "revogar"
  @list_id_atendimento "atendimento"
  @btn_id_consent_sim "consent_sim"
  @btn_id_consent_nao "consent_nao"
  @btn_id_cat_duvida "cat_duvida"
  @btn_id_cat_sinistro "cat_sinistro"
  @btn_id_cat_troca_veiculo "cat_troca_veiculo"

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

    unless :ets.whereis(@atendimento_flow_table) != :undefined do
      @atendimento_flow_table =
        :ets.new(@atendimento_flow_table, [:set, :public, :named_table, read_concurrency: true])
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

    # Check for active atendimento routing
    cond do
      is_agent_number?(from) ->
        route_agent_text_to_atendimento(phone_number_id, from, text)

      has_active_atendimento?(from) ->
        route_client_text_to_atendimento(phone_number_id, from, text)

      true ->
        handle_text_message(phone_number_id, from, text)
    end
  end

  defp handle_message(phone_number_id, %{
         "from" => from,
         "type" => "interactive",
         "interactive" => interactive
       }) do
    # Check for active atendimento routing first
    cond do
      is_agent_number?(from) ->
        # Agents don't use interactive messages in atendimento — fall through to menu
        send_main_menu(phone_number_id, from)

      has_active_atendimento?(from) ->
        # Client in active atendimento — still allow interactive (e.g., buttons)
        handle_interactive_message(phone_number_id, from, interactive)

      true ->
        handle_interactive_message(phone_number_id, from, interactive)
    end
  end

  defp handle_message(phone_number_id, %{
         "from" => from,
         "type" => type
       } = msg)
       when type in ["image", "audio", "document"] do
    # Media messages — route to atendimento if active
    cond do
      is_agent_number?(from) ->
        route_agent_media_to_atendimento(phone_number_id, from, msg)

      has_active_atendimento?(from) ->
        route_client_media_to_atendimento(phone_number_id, from, msg)

      true ->
        MetaApi.send_text(
          phone_number_id,
          from,
          "No momento só consigo responder a mensagens de texto ou botões interativos. " <>
            "Toque nos botões ou envie *menu* para ver as opções."
        )
    end
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
      # Atendimento flow — check ETS state for this phone
      is_in_atendimento_flow?(from) ->
        handle_atendimento_flow_step(phone_number_id, from, text)

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
    cond do
      # Atendimento category selection
      btn_id in [@btn_id_cat_duvida, @btn_id_cat_sinistro, @btn_id_cat_troca_veiculo] ->
        handle_atendimento_category(phone_number_id, from, btn_id)

      btn_id == @btn_id_consent_sim ->
        give_consent_and_send_policies(phone_number_id, from)

      btn_id == @btn_id_consent_nao ->
        handle_consent_refused(phone_number_id, from)

      true ->
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

      @list_id_atendimento ->
        ask_for_cpf_atendimento(phone_number_id, from)

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
          %{id: @list_id_contato, title: "📞 Contato", description: "Fale com a corretora"},
          %{id: @list_id_atendimento, title: "🎫 Atendimento", description: "Fale com um atendente"},
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

  # ---------------------------------------------------------------------------
  # Atendimento flow — ETS state helpers
  # ---------------------------------------------------------------------------

  defp get_atendimento_flow(from) do
    case :ets.lookup(@atendimento_flow_table, from) do
      [{^from, data}] -> data
      [] -> nil
    end
  end

  defp set_atendimento_flow(from, data) do
    :ets.insert(@atendimento_flow_table, {from, Map.put(data, :timestamp, DateTime.utc_now())})
  end

  defp clear_atendimento_flow(from) do
    :ets.delete(@atendimento_flow_table, from)
  end

  defp is_in_atendimento_flow?(from) do
    case get_atendimento_flow(from) do
      %{step: _} -> true
      nil -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Atendimento flow — step handlers
  # ---------------------------------------------------------------------------

  defp ask_for_cpf_atendimento(phone_number_id, from) do
    set_atendimento_flow(from, %{step: :waiting_cpf})

    MetaApi.send_text(
      phone_number_id,
      from,
      "Para iniciar o atendimento, *informe seu CPF ou CNPJ* (apenas números ou com pontuação)."
    )
  end

  defp handle_atendimento_flow_step(phone_number_id, from, text) do
    flow = get_atendimento_flow(from)

    case flow.step do
      :waiting_cpf ->
        handle_atendimento_cpf(phone_number_id, from, text)

      :waiting_category ->
        # User sent text instead of clicking a category button — remind them
        send_atendimento_category_buttons(phone_number_id, from, flow)

      :waiting_details ->
        handle_atendimento_details(phone_number_id, from, text, flow)
    end
  end

  defp handle_atendimento_cpf(phone_number_id, from, text) do
    digits = String.replace(text, ~r/[^0-9]/, "")

    if String.length(digits) in [11, 14] do
      # Look up customer name
      customer = Ersventaja.Customers.get_by_cpf_cnpj(digits)
      customer_name = if customer, do: customer.name, else: "Cliente"

      flow = %{
        step: :waiting_category,
        cpf: digits,
        customer_name: customer_name
      }

      set_atendimento_flow(from, flow)

      send_atendimento_category_buttons(phone_number_id, from, flow)
    else
      MetaApi.send_text(
        phone_number_id,
        from,
        "❌ *CPF/CNPJ inválido.* Por favor, informe um CPF (11 dígitos) ou CNPJ (14 dígitos)."
      )
    end
  end

  defp send_atendimento_category_buttons(phone_number_id, from, flow) do
    greeting = if flow.customer_name != "Cliente",
      do: "Olá, *#{flow.customer_name}*! ",
      else: ""

    MetaApi.send_interactive_buttons(
      phone_number_id,
      from,
      "#{greeting}Qual o *motivo do atendimento*?",
      [
        %{id: @btn_id_cat_duvida, title: "❓ Dúvida"},
        %{id: @btn_id_cat_sinistro, title: "🚨 Sinistro"},
        %{id: @btn_id_cat_troca_veiculo, title: "🚗 Troca de veículo"}
      ],
      footer: "Escolha uma das opções acima"
    )
  end

  defp handle_atendimento_category(phone_number_id, from, btn_id) do
    flow = get_atendimento_flow(from)

    {category, prompt} =
      case btn_id do
        @btn_id_cat_duvida ->
          {"duvida",
           "Digite sua *dúvida em uma única mensagem*. Se precisar, anexe arquivos ou fotos.\n\n" <>
             "✏️ Escreva abaixo:"}

        @btn_id_cat_sinistro ->
          {"sinistro",
           "Esperamos que esteja tudo bem! 🙏\n\n" <>
             "Por favor, nos dê *mais detalhes sobre a ocorrência*:\n" <>
             "• O que aconteceu?\n" <>
             "• Quando ocorreu?\n" <>
             "• Onde ocorreu?\n\n" <>
             "Se tiver *fotos ou documentos*, pode anexá-los.\n\n" <>
             "✏️ Escreva abaixo:"}

        @btn_id_cat_troca_veiculo ->
          {"troca_veiculo",
           "Para a troca de veículo, precisamos de algumas informações:\n\n" <>
             "• *Qual a data prevista para retirada do veículo?*\n" <>
             "• Se já possuir a *nota fiscal*, pode anexá-la.\n\n" <>
             "✏️ Escreva abaixo:"}
      end

    new_flow = Map.merge(flow, %{step: :waiting_details, category: category})
    set_atendimento_flow(from, new_flow)

    MetaApi.send_text(phone_number_id, from, prompt)
  end

  defp handle_atendimento_details(phone_number_id, from, text, flow) do
    # Create the atendimento
    create_and_start_atendimento(phone_number_id, from, text, flow)
    clear_atendimento_flow(from)
  end

  # ---------------------------------------------------------------------------
  # Atendimento — creation and GenServer start
  # ---------------------------------------------------------------------------

  defp create_and_start_atendimento(phone_number_id, from, details_text, flow) do
    agent = Ersventaja.Atendimento.get_random_agent()

    if is_nil(agent) do
      MetaApi.send_text(
        phone_number_id,
        from,
        "❌ Não há atendentes disponíveis no momento. " <>
          "Por favor, entre em contato pelo e-mail: roberto@rsventaja.com"
      )
    else
      # Create atendimento in DB
      case Ersventaja.Atendimento.create_atendimento(%{
        whatsapp_phone: from,
        cpf_cnpj: flow.cpf,
        customer_name: flow.customer_name,
        category: flow.category,
        status: "active",
        started_at: DateTime.utc_now(),
        agent_id: agent.id
      }) do
        {:ok, atendimento} ->
          # Start GenServer
          server_data = %{
            atendimento_id: atendimento.id,
            client_phone: from,
            agent_phone: agent.phone,
            phone_number_id: phone_number_id,
            category: flow.category,
            customer_name: flow.customer_name,
            cpf_cnpj: flow.cpf
          }

          # Create customer record if needed
          if flow.customer_name != "Cliente" do
            Ersventaja.Customers.find_or_create_by_cpf_cnpj(flow.cpf, %{
              name: flow.customer_name,
              phone: from
            })
          end

          case Ersventaja.Atendimento.AtendimentoSupervisor.start_child(server_data) do
            {:ok, pid} ->
              Logger.info("[WhatsApp] Atendimento ##{atendimento.id} started | PID: #{inspect(pid)}")

              # Forward the initial client message to the GenServer
              Ersventaja.Atendimento.AtendimentoServer.client_message(pid, details_text)

              # Send summary to agent
              category_label =
                case flow.category do
                  "duvida" -> "Dúvida"
                  "sinistro" -> "Notificação de Sinistro"
                  "troca_veiculo" -> "Troca de Veículo"
                end

              MetaApi.send_text(
                phone_number_id,
                agent.phone,
                "🔔 *Novo Atendimento ##{atendimento.id}*\n\n" <>
                  "*Cliente:* #{flow.customer_name}\n" <>
                  "*CPF/CNPJ:* #{flow.cpf}\n" <>
                  "*Categoria:* #{category_label}\n" <>
                  "*WhatsApp:* #{from}\n\n" <>
                  "*Mensagem do cliente:*\n#{details_text}\n\n" <>
                  "Responda esta mensagem para iniciar o atendimento."
              )

            {:error, {:already_started, pid}} ->
              Logger.warning("[WhatsApp] Atendimento ##{atendimento.id} already started")
              Ersventaja.Atendimento.AtendimentoServer.client_message(pid, details_text)

            {:error, reason} ->
              Logger.error("[WhatsApp] Failed to start atendimento GenServer: #{inspect(reason)}")

              MetaApi.send_text(
                phone_number_id,
                from,
                "❌ Não foi possível iniciar o atendimento. " <>
                  "Por favor, tente novamente ou entre em contato pelo e-mail: roberto@rsventaja.com"
              )
          end

        {:error, changeset} ->
          Logger.error("[WhatsApp] Failed to create atendimento: #{inspect(changeset.errors)}")

          MetaApi.send_text(
            phone_number_id,
            from,
            "❌ Não foi possível criar o atendimento. " <>
              "Por favor, tente novamente ou entre em contato pelo e-mail: roberto@rsventaja.com"
          )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Atendimento routing — text messages
  # ---------------------------------------------------------------------------

  defp is_agent_number?(from) do
    Ersventaja.Atendimento.is_agent_number?(from)
  end

  defp has_active_atendimento?(from) do
    Ersventaja.Atendimento.get_active_atendimento_by_phone(from) != nil
  end

  defp route_agent_text_to_atendimento(phone_number_id, from, text) do
    case Ersventaja.Atendimento.get_active_atendimento_for_agent(from) do
      %{id: att_id} ->
        # Find the GenServer PID by looking up children of the supervisor
        pid = find_atendimento_pid(att_id)

        if pid do
          # Check for end commands from agent
          if String.downcase(String.trim(text)) in ["encerrar", "finalizar", "terminar"] do
            Ersventaja.Atendimento.AtendimentoServer.end_by_agent(pid)
          else
            Ersventaja.Atendimento.AtendimentoServer.agent_message(pid, text)
          end
        else
          Logger.warning("[WhatsApp] No GenServer found for atendimento ##{att_id}")
        end

      nil ->
        MetaApi.send_text(
          phone_number_id,
          from,
          "Você não tem nenhum atendimento ativo no momento."
        )
    end
  end

  defp route_client_text_to_atendimento(phone_number_id, from, text) do
    case Ersventaja.Atendimento.get_active_atendimento_by_phone(from) do
      %{id: att_id} ->
        pid = find_atendimento_pid(att_id)

        if pid do
          # Check for end command
          if String.downcase(String.trim(text)) in ["encerrar", "finalizar", "terminar"] do
            Ersventaja.Atendimento.AtendimentoServer.end_by_client(pid)
          else
            Ersventaja.Atendimento.AtendimentoServer.client_message(pid, text)
          end
        else
          Logger.warning("[WhatsApp] No GenServer found for atendimento ##{att_id}")
        end

      nil ->
        # Shouldn't happen, but handle gracefully
        send_main_menu(phone_number_id, from)
    end
  end

  # ---------------------------------------------------------------------------
  # Atendimento routing — media messages
  # ---------------------------------------------------------------------------

  defp route_agent_media_to_atendimento(phone_number_id, from, msg) do
    case Ersventaja.Atendimento.get_active_atendimento_for_agent(from) do
      %{id: att_id} ->
        pid = find_atendimento_pid(att_id)

        if pid do
          media_type = msg["type"]
          media_id = get_in(msg, [media_type, "id"])
          mime_type = get_in(msg, [media_type, "mime_type"]) || mime_type_for(msg)
          caption = get_in(msg, [media_type, "caption"])

          Ersventaja.Atendimento.AtendimentoServer.agent_media(
            pid, media_type, media_id, mime_type, caption
          )
        else
          Logger.warning("[WhatsApp] No GenServer found for atendimento ##{att_id}")
        end

      nil ->
        MetaApi.send_text(
          phone_number_id,
          from,
          "Você não tem nenhum atendimento ativo no momento."
        )
    end
  end

  defp route_client_media_to_atendimento(phone_number_id, from, msg) do
    case Ersventaja.Atendimento.get_active_atendimento_by_phone(from) do
      %{id: att_id} ->
        pid = find_atendimento_pid(att_id)

        if pid do
          media_type = msg["type"]
          media_id = get_in(msg, [media_type, "id"])
          mime_type = get_in(msg, [media_type, "mime_type"]) || mime_type_for(msg)
          caption = get_in(msg, [media_type, "caption"])

          Ersventaja.Atendimento.AtendimentoServer.client_media(
            pid, media_type, media_id, mime_type, caption
          )
        else
          Logger.warning("[WhatsApp] No GenServer found for atendimento ##{att_id}")
        end

      nil ->
        send_main_menu(phone_number_id, from)
    end
  end

  defp mime_type_for(%{"type" => "image"}), do: "image/jpeg"
  defp mime_type_for(%{"type" => "audio"}), do: "audio/ogg"
  defp mime_type_for(%{"type" => "document"}), do: "application/pdf"
  defp mime_type_for(_), do: "application/octet-stream"

  # ---------------------------------------------------------------------------
  # Atendimento — GenServer PID lookup
  # ---------------------------------------------------------------------------

  defp find_atendimento_pid(atendimento_id) do
    child_id = :"atendimento_#{atendimento_id}"

    Ersventaja.Atendimento.AtendimentoSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, :worker, _} -> pid
      _ -> nil
    end)
  end
end
