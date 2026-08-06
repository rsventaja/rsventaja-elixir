defmodule Ersventaja.Atendimento.AtendimentoServer do
  @moduledoc """
  GenServer que gerencia um atendimento ativo via WhatsApp.

  Cada processo representa uma conversa entre um cliente e um atendente,
  intermediada pelo bot do WhatsApp. O GenServer gerencia:
    - Encaminhamento de mensagens entre as partes
    - Timer de inatividade (10 minutos)
    - Encerramento por timeout, cliente ou atendente
    - Persistência de todas as mensagens no banco

  O estado sobrevive a crashes porque está todo no banco de dados.
  """

  use GenServer
  require Logger

  alias Ersventaja.Atendimento
  alias Ersventaja.Whatsapp.MetaApi

  @timeout_ms 10 * 60 * 1000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Inicia um GenServer para o atendimento.

  `data` deve ser um map com:
    - `:atendimento_id` — ID do atendimento no banco
    - `:client_phone` — telefone WhatsApp do cliente
    - `:agent_phone` — telefone WhatsApp do atendente
    - `:phone_number_id` — ID do número comercial do WhatsApp
    - `:category` — categoria do atendimento
    - `:customer_name` — nome do cliente
    - `:cpf_cnpj` — CPF/CNPJ informado
  """
  def start_link(data) do
    GenServer.start_link(__MODULE__, data)
  end

  @doc """
  Envia uma mensagem de texto do cliente para o atendente.
  """
  def client_message(pid, text) do
    GenServer.cast(pid, {:client_message, text})
  end

  @doc """
  Envia uma mensagem de mídia do cliente para o atendente.
  """
  def client_media(pid, media_type, media_id, mime_type, caption \\ nil) do
    GenServer.cast(pid, {:client_media, media_type, media_id, mime_type, caption})
  end

  @doc """
  Envia uma mensagem de texto do atendente para o cliente.
  """
  def agent_message(pid, text) do
    GenServer.cast(pid, {:agent_message, text})
  end

  @doc """
  Envia uma mensagem de mídia do atendente para o cliente.
  """
  def agent_media(pid, media_type, media_id, mime_type, caption \\ nil) do
    GenServer.cast(pid, {:agent_media, media_type, media_id, mime_type, caption})
  end

  @doc """
  Encerra o atendimento a pedido do cliente.
  """
  def end_by_client(pid) do
    GenServer.cast(pid, :end_by_client)
  end

  @doc """
  Encerra o atendimento a pedido do atendente.
  """
  def end_by_agent(pid) do
    GenServer.cast(pid, :end_by_agent)
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(data) do
    atendimento_id = data.atendimento_id
    client_phone = data.client_phone
    agent_phone = data.agent_phone
    phone_number_id = data.phone_number_id
    recovery? = Map.get(data, :recovery, false)

    unless recovery? do
      # Envia mensagem de boas-vindas ao cliente (apenas em criação nova)
      welcome_msg =
        "✅ *Atendimento iniciado!*\n\n" <>
          "Um de nossos atendentes irá responder em breve. " <>
          "Você pode enviar mensagens, fotos, documentos e áudios.\n\n" <>
          "⏰ *Importante:* O atendimento será encerrado automaticamente " <>
          "após 10 minutos de inatividade.\n\n" <>
          "Digite *encerrar* a qualquer momento para finalizar o atendimento."

      MetaApi.send_text(phone_number_id, client_phone, welcome_msg)

      # Salva mensagem de sistema no banco
      Atendimento.add_message(%{
        atendimento_id: atendimento_id,
        direction: "outgoing",
        sender_type: "system",
        content_type: "text",
        content: welcome_msg,
        whatsapp_phone: phone_number_id
      })
    end

    # Agenda timer de inatividade
    timer_ref = Process.send_after(self(), :timeout, @timeout_ms)

    client_name = Map.get(data, :customer_name, "Cliente")
    agent_name = Map.get(data, :agent_name, "Atendente")

    state = %{
      atendimento_id: atendimento_id,
      client_phone: client_phone,
      agent_phone: agent_phone,
      phone_number_id: phone_number_id,
      client_name: client_name,
      agent_name: agent_name,
      status: :active,
      timer_ref: timer_ref
    }

    status_label = if recovery?, do: "recuperado", else: "iniciado"

    Logger.info(
      "[Atendimento] ##{atendimento_id} #{status_label} | Cliente: #{client_phone} | Agente: #{agent_phone}"
    )

    {:ok, state}
  end

  # ---------------------------------------------------------------------------
  # Mensagens de texto
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:client_message, text}, state) do
    if state.status == :active do
      # Salva no banco
      Atendimento.add_message(%{
        atendimento_id: state.atendimento_id,
        direction: "incoming",
        sender_type: "client",
        content_type: "text",
        content: text,
        whatsapp_phone: state.client_phone
      })

      # Encaminha para o atendente com nome do cliente
      prefixed = "*#{state.client_name}:*\n#{text}"
      MetaApi.send_text(state.phone_number_id, state.agent_phone, prefixed)

      Logger.info(
        "[Atendimento] ##{state.atendimento_id} Cliente → Atendente: #{String.slice(text, 0, 100)}"
      )
    end

    {:noreply, reset_timer(state)}
  end

  @impl true
  def handle_cast({:agent_message, text}, state) do
    if state.status == :active do
      # Salva no banco
      Atendimento.add_message(%{
        atendimento_id: state.atendimento_id,
        direction: "outgoing",
        sender_type: "agent",
        content_type: "text",
        content: text,
        whatsapp_phone: state.agent_phone
      })

      # Encaminha para o cliente com nome do atendente
      prefixed = "*#{state.agent_name}:*\n#{text}"
      MetaApi.send_text(state.phone_number_id, state.client_phone, prefixed)

      Logger.info(
        "[Atendimento] ##{state.atendimento_id} Atendente → Cliente: #{String.slice(text, 0, 100)}"
      )
    end

    {:noreply, reset_timer(state)}
  end

  # ---------------------------------------------------------------------------
  # Mensagens de mídia
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:client_media, media_type, media_id, mime_type, caption}, state) do
    if state.status == :active do
      content_label = "#{media_type}: #{media_id}"

      # Salva no banco
      Atendimento.add_message(%{
        atendimento_id: state.atendimento_id,
        direction: "incoming",
        sender_type: "client",
        content_type: media_type,
        content: caption || content_label,
        whatsapp_phone: state.client_phone,
        media_id: media_id,
        mime_type: mime_type
      })

      # Encaminha mídia para o atendente
      forward_media(
        state.phone_number_id,
        state.agent_phone,
        media_type,
        media_id,
        mime_type,
        caption
      )

      Logger.info("[Atendimento] ##{state.atendimento_id} Cliente → Atendente: #{content_label}")
    end

    {:noreply, reset_timer(state)}
  end

  @impl true
  def handle_cast({:agent_media, media_type, media_id, mime_type, caption}, state) do
    if state.status == :active do
      content_label = "#{media_type}: #{media_id}"

      # Salva no banco
      Atendimento.add_message(%{
        atendimento_id: state.atendimento_id,
        direction: "outgoing",
        sender_type: "agent",
        content_type: media_type,
        content: caption || content_label,
        whatsapp_phone: state.agent_phone,
        media_id: media_id,
        mime_type: mime_type
      })

      # Encaminha mídia para o cliente
      forward_media(
        state.phone_number_id,
        state.client_phone,
        media_type,
        media_id,
        mime_type,
        caption
      )

      Logger.info("[Atendimento] ##{state.atendimento_id} Atendente → Cliente: #{content_label}")
    end

    {:noreply, reset_timer(state)}
  end

  # ---------------------------------------------------------------------------
  # Encerramento
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast(:end_by_client, state) do
    end_atendimento(
      state,
      "client",
      "👋 *Atendimento encerrado pelo cliente.* Obrigado por nos contatar!"
    )
  end

  @impl true
  def handle_cast(:end_by_agent, state) do
    end_atendimento(
      state,
      "agent",
      "👋 *Atendimento encerrado pelo atendente.* Obrigado por nos contatar!"
    )
  end

  # ---------------------------------------------------------------------------
  # Timeout
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(:timeout, state) do
    end_atendimento(
      state,
      "timeout",
      "⏰ *Atendimento encerrado por inatividade.* Se precisar de mais ajuda, inicie um novo atendimento."
    )
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp reset_timer(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    timer_ref = Process.send_after(self(), :timeout, @timeout_ms)
    %{state | timer_ref: timer_ref}
  end

  defp end_atendimento(state, ended_by, message) do
    if state.status == :active do
      # Atualiza no banco
      atendimento = Atendimento.get_atendimento(state.atendimento_id)

      if atendimento do
        Atendimento.end_atendimento(atendimento, ended_by)

        # Salva mensagem de sistema
        Atendimento.add_message(%{
          atendimento_id: state.atendimento_id,
          direction: "outgoing",
          sender_type: "system",
          content_type: "text",
          content: message,
          whatsapp_phone: state.phone_number_id
        })
      end

      # Notifica ambas as partes
      MetaApi.send_text(state.phone_number_id, state.client_phone, message)

      if ended_by != "agent" do
        MetaApi.send_text(
          state.phone_number_id,
          state.agent_phone,
          "👋 *Atendimento ##{state.atendimento_id} encerrado.* " <>
            "Motivo: #{humanize_ended_by(ended_by)}."
        )
      end

      Logger.info("[Atendimento] ##{state.atendimento_id} encerrado por: #{ended_by}")
    end

    # Cancela timer pendente
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Para o GenServer
    {:stop, :normal, %{state | status: :ended}}
  end

  defp humanize_ended_by("client"), do: "cliente"
  defp humanize_ended_by("agent"), do: "atendente"
  defp humanize_ended_by("timeout"), do: "tempo de inatividade (10 min)"
  defp humanize_ended_by(_), do: "desconhecido"

  # ---------------------------------------------------------------------------
  # Encaminhamento de mídia
  # ---------------------------------------------------------------------------

  defp forward_media(phone_number_id, to_phone, media_type, media_id, _mime_type, caption) do
    caption_str = caption || ""

    case media_type do
      "image" ->
        MetaApi.send_image_by_media_id(phone_number_id, to_phone, media_id, caption: caption_str)

      "document" ->
        MetaApi.send_document(phone_number_id, to_phone, {:media_id, media_id},
          caption: caption_str,
          filename: "documento"
        )

      "audio" ->
        MetaApi.send_audio_by_media_id(phone_number_id, to_phone, media_id)

      _ ->
        MetaApi.send_text(
          phone_number_id,
          to_phone,
          "[#{String.upcase(media_type)}] #{caption_str}"
        )
    end
  end
end
