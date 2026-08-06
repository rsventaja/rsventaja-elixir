defmodule Ersventaja.Atendimento do
  @moduledoc """
  Contexto para gestão de atendimentos via WhatsApp.

  Gerencia agentes de atendimento, atendimentos ativos/finalizados,
  e mensagens trocadas entre clientes e atendentes.
  """

  alias Ersventaja.Atendimento.Models.AtendimentoAgent
  alias Ersventaja.Atendimento.Models.Atendimento
  alias Ersventaja.Atendimento.Models.AtendimentoMessage
  alias Ersventaja.Repo

  import Ecto.Query
  require Logger

  # ---------------------------------------------------------------------------
  # Agentes (AtendimentoAgent CRUD)
  # ---------------------------------------------------------------------------

  @doc """
  Lista todos os agentes de atendimento cadastrados.
  """
  def list_agents do
    Repo.all(from(a in AtendimentoAgent, where: a.active == true, order_by: a.name))
  end

  @doc """
  Busca um agente pelo ID (levanta Ecto.NoResultsError se não encontrado).
  """
  def get_agent!(id), do: Repo.get!(AtendimentoAgent, id)

  @doc """
  Busca um agente pelo ID, retornando nil se não encontrado.
  """
  def get_agent(id), do: Repo.get(AtendimentoAgent, id)

  @doc """
  Cria um novo agente de atendimento.
  """
  def create_agent(attrs) do
    # Se já existe um agente (mesmo inativo) com este telefone, reativa e atualiza o nome
    digits = normalize_phone_digits(attrs["phone"] || attrs[:phone] || "")

    existing =
      if digits != "" do
        Repo.one(
          from(a in AtendimentoAgent,
            where: fragment("regexp_replace(?, '[^0-9]', '', 'g')", a.phone) == ^digits
          )
        )
      end

    if existing do
      existing
      |> AtendimentoAgent.changeset(Map.merge(attrs, %{active: true}))
      |> Repo.update()
    else
      %AtendimentoAgent{}
      |> AtendimentoAgent.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Atualiza um agente existente.
  """
  def update_agent(%AtendimentoAgent{} = agent, attrs) do
    agent
    |> AtendimentoAgent.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Desativa um agente (soft delete). O agente não aparecerá mais na listagem
  nem será atribuído a novos atendimentos, mas seu nome permanece no histórico.
  """
  def delete_agent(%AtendimentoAgent{} = agent) do
    agent
    |> AtendimentoAgent.changeset(%{active: false})
    |> Repo.update()
  end

  @doc """
  Retorna um agente aleatório da lista de cadastrados.
  Retorna nil se não houver agentes.
  """
  def get_random_agent do
    agents = list_agents()

    if agents == [] do
      nil
    else
      Enum.random(agents)
    end
  end

  @doc """
  Verifica se um número de telefone pertence a um agente cadastrado.
  """
  def is_agent_number?(phone) when is_binary(phone) do
    digits = normalize_phone_digits(phone)

    if digits == "" do
      false
    else
      Repo.exists?(
        from(a in AtendimentoAgent,
          where: a.active == true,
          where:
            fragment(
              "regexp_replace(?, '[^0-9]', '', 'g')",
              a.phone
            ) == ^digits
        )
      )
    end
  end

  def is_agent_number?(_), do: false

  # ---------------------------------------------------------------------------
  # Atendimentos
  # ---------------------------------------------------------------------------

  @doc """
  Cria um novo atendimento.
  """
  def create_atendimento(attrs) do
    %Atendimento{}
    |> Atendimento.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Busca um atendimento pelo ID.
  """
  def get_atendimento(id), do: Repo.get(Atendimento, id)

  @doc """
  Busca um atendimento pelo ID com preload de mensagens e agente.
  """
  def get_atendimento_with_relations(id) do
    Atendimento
    |> Repo.get(id)
    |> Repo.preload([:messages, :agent, :customer])
  end

  @doc """
  Busca o atendimento ativo para um dado telefone WhatsApp de cliente.
  Retorna nil se não houver atendimento ativo.
  """
  def get_active_atendimento_by_phone(whatsapp_phone) do
    from(a in Atendimento,
      where: a.whatsapp_phone == ^whatsapp_phone,
      where: a.status == "active",
      order_by: [desc: a.started_at],
      limit: 1
    )
    |> Repo.one()
    |> Repo.preload([:agent, :customer])
  end

  @doc """
  Busca o atendimento ativo associado a um agente (pelo telefone do agente).
  Retorna nil se não houver.
  """
  def get_active_atendimento_for_agent(agent_phone) do
    digits = normalize_phone_digits(agent_phone)

    if digits == "" do
      nil
    else
      from(a in Atendimento,
        join: ag in AtendimentoAgent,
        on: a.agent_id == ag.id,
        where: ag.active == true,
        where:
          fragment(
            "regexp_replace(?, '[^0-9]', '', 'g')",
            ag.phone
          ) == ^digits,
        where: a.status == "active",
        order_by: [desc: a.started_at],
        limit: 1
      )
      |> Repo.one()
      |> Repo.preload([:agent, :customer])
    end
  end

  @doc """
  Finaliza um atendimento, registrando status, timestamp e motivo.
  """
  def end_atendimento(%Atendimento{} = atendimento, ended_by) do
    atendimento
    |> Atendimento.changeset(%{
      status: if(ended_by == "timeout", do: "expired", else: "ended"),
      ended_at: DateTime.utc_now(),
      ended_by: ended_by
    })
    |> Repo.update()
  end

  @doc """
  Lista atendimentos filtrados por status.
  """
  def list_atendimentos(status \\ "active") do
    query = from(a in Atendimento, order_by: [desc: a.started_at])

    query =
      case status do
        "all" -> query
        "active" -> from(a in query, where: a.status == "active")
        "ended" -> from(a in query, where: a.status == "ended")
        "expired" -> from(a in query, where: a.status == "expired")
        _ -> query
      end

    Repo.all(query) |> Repo.preload([:agent, :customer])
  end

  # ---------------------------------------------------------------------------
  # Mensagens
  # ---------------------------------------------------------------------------

  @doc """
  Adiciona uma mensagem a um atendimento.
  """
  def add_message(attrs) do
    %AtendimentoMessage{}
    |> AtendimentoMessage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lista mensagens de um atendimento, ordenadas por data de criação.
  """
  def get_messages(atendimento_id) do
    from(m in AtendimentoMessage,
      where: m.atendimento_id == ^atendimento_id,
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Normaliza um número de telefone para apenas dígitos, removendo código
  de país 55 se presente (WhatsApp envia E.164, mas armazenamos nacional).

  ## Exemplos

      iex> normalize_phone_digits("5511999990001")
      "11999990001"

      iex> normalize_phone_digits("(11) 99999-0001")
      "11999990001"

  """
  def normalize_phone_digits(phone) when is_binary(phone) do
    digits = String.replace(phone, ~r/[^0-9]/, "")

    # Remove country code 55 prefix when ≥12 digits (55 + DDD + number)
    if String.length(digits) >= 12 and String.starts_with?(digits, "55") do
      String.slice(digits, 2..-1//1)
    else
      digits
    end
  end

  def normalize_phone_digits(_), do: ""

  # ---------------------------------------------------------------------------
  # Blocked senders
  # ---------------------------------------------------------------------------

  @doc """
  Verifica se um número está bloqueado.
  """
  def is_blocked?(phone) when is_binary(phone) do
    Repo.exists?(from("blocked_senders", where: [phone: ^phone]))
  end

  def is_blocked?(_), do: false

  @doc """
  Bloqueia um número de telefone.
  """
  def block_sender(phone, blocked_by \\ nil) do
    now = NaiveDateTime.utc_now()

    Repo.insert_all(
      "blocked_senders",
      [
        %{phone: phone, blocked_by: blocked_by, inserted_at: now, updated_at: now}
      ],
      on_conflict: :nothing
    )
  end

  @doc """
  Desbloqueia um número de telefone.
  """
  def unblock_sender(phone) do
    Repo.delete_all(from("blocked_senders", where: [phone: ^phone]))
  end

  @doc """
  Lista todos os números bloqueados.
  """
  def list_blocked_senders do
    Repo.all(
      from(b in "blocked_senders",
        select: [:phone, :blocked_by, :inserted_at],
        order_by: [desc: :inserted_at]
      )
    )
  end

  # ---------------------------------------------------------------------------
  # Recovery after restart
  # ---------------------------------------------------------------------------

  @doc """
  Chamado no boot da aplicação. Recupera atendimentos ativos que ficaram
  órfãos após um restart.

  Para cada atendimento ativo:
  - Se a última mensagem foi há mais de 10 minutos → expira
  - Se ainda dentro da janela → recria o GenServer

  Retorna uma lista de mapas com os dados para iniciar os GenServers.
  """
  def recover_active_atendimentos do
    atendimentos =
      Repo.all(from(a in Atendimento, where: a.status == "active"))
      |> Repo.preload(:agent)

    now = NaiveDateTime.utc_now()
    phone_number_id = Application.get_env(:ersventaja, :whatsapp)[:phone_number_id] || ""

    Enum.map(atendimentos, fn att ->
      last_activity = get_last_activity_time(att.id)

      inactivity_seconds =
        if last_activity do
          NaiveDateTime.diff(now, last_activity, :second)
        else
          NaiveDateTime.diff(now, att.started_at, :second)
        end

      if inactivity_seconds >= 600 do
        # Mais de 10 min de inatividade → expira
        case end_atendimento(att, "timeout") do
          {:ok, _} ->
            Logger.info(
              "[Atendimento] ##{att.id} expired on recovery (inactive for #{inactivity_seconds}s)"
            )

          {:error, reason} ->
            Logger.error(
              "[Atendimento] ##{att.id} failed to expire on recovery: #{inspect(reason)}"
            )
        end

        nil
      else
        # Ainda ativo → dados para recriar o GenServer (modo recovery)
        %{
          atendimento_id: att.id,
          client_phone: att.whatsapp_phone,
          agent_phone: (att.agent && att.agent.phone) || "",
          phone_number_id: phone_number_id,
          category: att.category,
          customer_name: att.customer_name || "Cliente",
          agent_name: (att.agent && att.agent.name) || "Atendente",
          cpf_cnpj: att.cpf_cnpj,
          recovery: true
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp get_last_activity_time(atendimento_id) do
    msg =
      from(m in AtendimentoMessage,
        where: m.atendimento_id == ^atendimento_id,
        order_by: [desc: m.inserted_at],
        limit: 1
      )
      |> Repo.one()

    if msg, do: msg.inserted_at, else: nil
  end
end
