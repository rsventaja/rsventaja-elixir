defmodule Ersventaja.Lgpd do
  @moduledoc """
  LGPD consent management.

  Implements consent collection, storage, and verification per the
  Brazilian Lei Geral de Proteção de Dados (Lei 13.709/2018).

  ## Design decisions

    - Consent is keyed by (CPF/CNPJ + WhatsApp phone) pair. A person can
      consent from multiple phones, and each phone must consent independently.
      This prevents unauthorized access: Bob cannot query Alice's policies
      from his phone just because Alice consented from hers.

    - The exact consent text shown to the user is stored as evidence
      (Art. 8º §2º — burden of proof on the controller).

    - Revocation is supported (Art. 8º §5º). A revoked consent will
      cause the bot to ask for consent again.

    - Every incoming webhook payload is archived verbatim for the
      audit trail.
  """

  alias Ersventaja.Lgpd.Models.Consent
  alias Ersventaja.Repo

  import Ecto.Query

  # ---------------------------------------------------------------------------
  # Consent text shown to users (Portuguese, LGPD-compliant)
  # ---------------------------------------------------------------------------

  @consent_version "1.0"

  @lgpd_consent_text """
  🔒 *LGPD — Autorização de Tratamento de Dados*

  Para consultar sua apólice, a *RS Ventaja* precisa tratar seus dados pessoais
  (CPF/CNPJ) com a finalidade exclusiva de localizar e enviar o documento da
  sua apólice contratada.

  Seus dados:
  • Serão usados apenas para esta finalidade
  • Não serão compartilhados com terceiros
  • Serão armazenados de forma segura
  • Poderão ser eliminados mediante solicitação

  Você pode revogar esta autorização a qualquer momento enviando *revogar*.

  *Responda SIM para autorizar* ou *NÃO para recusar*.
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns the standard LGPD consent text shown to users.
  """
  def consent_text, do: @lgpd_consent_text

  @doc """
  Returns the current consent policy version string.
  """
  def consent_version, do: @consent_version

  @doc """
  Checks whether valid (non-revoked) consent exists for the given
  CPF/CNPJ _and_ WhatsApp phone number pair.

  Both must match — consent given by one phone does not grant access
  to a different phone, even for the same CPF.

  ## Examples

      iex> has_consent?("123.456.789-00", "5511999999999")
      false

  """
  @spec has_consent?(String.t(), String.t()) :: boolean()
  def has_consent?(cpf_cnpj, whatsapp_phone) when is_binary(cpf_cnpj) do
    digits = normalize(cpf_cnpj)

    query =
      from(c in Consent,
        where: c.cpf_cnpj == ^digits,
        where: c.whatsapp_phone == ^whatsapp_phone,
        where: is_nil(c.revoked_at)
      )

    Repo.exists?(query)
  end

  @doc """
  Records that a user gave LGPD consent for the given CPF/CNPJ.

  Consent is per (CPF + phone) pair. The same CPF can consent from
  multiple phones independently; each gets its own record.

  Uses upsert: if this (CPF, phone) pair already has a record (including
  revoked), it is reactivated rather than creating a duplicate.

  ## Parameters

    - `cpf_cnpj` — the normalized (digits-only) CPF or CNPJ
    - `whatsapp_phone` — the WhatsApp phone number that gave consent
    - `opts` — optional overrides for `:source`, `:policy_version`, `:consent_text_shown`
  """
  @spec give_consent(String.t(), String.t(), keyword()) ::
          {:ok, Consent.t()} | {:error, Ecto.Changeset.t()}
  def give_consent(cpf_cnpj, whatsapp_phone, opts \\ []) do
    digits = normalize(cpf_cnpj)

    attrs = %{
      cpf_cnpj: digits,
      consented_at: DateTime.utc_now(),
      whatsapp_phone: whatsapp_phone,
      consent_text_shown: Keyword.get(opts, :consent_text_shown, @lgpd_consent_text),
      policy_version: Keyword.get(opts, :policy_version, @consent_version),
      source: Keyword.get(opts, :source, "whatsapp"),
      revoked_at: nil,
      revocation_reason: nil
    }

    # Upsert on (cpf_cnpj, whatsapp_phone) pair: reactivates a revoked
    # consent or updates an existing one instead of failing with a
    # unique-constraint violation.
    Repo.insert(
      Consent.changeset(%Consent{}, attrs),
      on_conflict: [
        set: [
          consented_at: attrs.consented_at,
          consent_text_shown: attrs.consent_text_shown,
          policy_version: attrs.policy_version,
          source: attrs.source,
          revoked_at: nil,
          revocation_reason: nil,
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        ]
      ],
      conflict_target: [:cpf_cnpj, :whatsapp_phone]
    )
  end

  @doc """
  Revokes a previously-given consent for a specific (CPF, phone) pair.

  Consent is soft-deleted: `revoked_at` is set but the record is kept
  for the audit trail (burden of proof, Art. 8º §2º).

  Returns `{:ok, consent}` on success, `{:error, :not_found}` if no
  active consent exists for the given CPF/CNPJ + phone pair.
  """
  @spec revoke_consent(String.t(), String.t(), String.t() | nil) ::
          {:ok, Consent.t()} | {:error, :not_found}
  def revoke_consent(cpf_cnpj, whatsapp_phone, reason \\ nil) do
    digits = normalize(cpf_cnpj)

    query =
      from(c in Consent,
        where: c.cpf_cnpj == ^digits,
        where: c.whatsapp_phone == ^whatsapp_phone,
        where: is_nil(c.revoked_at)
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      consent ->
        changeset =
          Consent.changeset(consent, %{
            revoked_at: DateTime.utc_now(),
            revocation_reason: reason
          })

        Repo.update(changeset)
    end
  end

  @doc """
  Returns the consent record for a given (CPF/CNPJ, phone) pair, if any.
  """
  @spec get_consent(String.t(), String.t()) :: Consent.t() | nil
  def get_consent(cpf_cnpj, whatsapp_phone) do
    digits = normalize(cpf_cnpj)
    Repo.get_by(Consent, cpf_cnpj: digits, whatsapp_phone: whatsapp_phone)
  end

  # ---------------------------------------------------------------------------
  # Webhook payload archiving (audit trail)
  # ---------------------------------------------------------------------------

  @doc """
  Archives a raw WhatsApp webhook payload for the audit trail.

  Extracts the first message's ID and sender phone for indexing.
  The full raw JSON is stored verbatim.
  """
  @spec store_webhook_payload(map(), String.t()) :: {:ok, map()} | {:error, any()}
  def store_webhook_payload(payload, raw_body) when is_binary(raw_body) do
    message_id = extract_message_id(payload)
    from_phone = extract_from_phone(payload)
    phone_number_id = extract_phone_number_id(payload)

    attrs = %{
      whatsapp_message_id: message_id,
      from_phone: from_phone,
      phone_number_id: phone_number_id,
      raw_payload: raw_body,
      received_at: DateTime.utc_now()
    }

    # Use raw SQL insert for the archive table to avoid needing a schema module
    # (keeps the archive table lightweight — no Ecto schema needed unless queried)
    now_naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all("whatsapp_webhook_payloads", [
      Map.merge(attrs, %{
        inserted_at: now_naive,
        updated_at: now_naive
      })
    ])
    |> case do
      {1, _} -> {:ok, attrs}
      error -> {:error, error}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize(str), do: String.replace(str, ~r/[^0-9]/, "")

  defp extract_message_id(%{"entry" => entries}) when is_list(entries) do
    Enum.find_value(entries, fn entry ->
      # WhatsApp sends either "messages" or "statuses" — check both.
      # get_in with multiple Access.all() levels returns nested lists,
      # so we flatten before searching.
      msg_id =
        entry
        |> get_in(["changes", Access.all(), "value", "messages", Access.all(), "id"])
        |> List.wrap()
        |> List.flatten()
        |> Enum.find(&is_binary/1)

      status_id =
        entry
        |> get_in(["changes", Access.all(), "value", "statuses", Access.all(), "id"])
        |> List.wrap()
        |> List.flatten()
        |> Enum.find(&is_binary/1)

      msg_id || status_id
    end)
  end

  defp extract_message_id(_), do: nil

  defp extract_from_phone(%{"entry" => entries}) when is_list(entries) do
    Enum.find_value(entries, fn entry ->
      # Incoming messages have "from", status updates have "recipient_id"
      from =
        entry
        |> get_in(["changes", Access.all(), "value", "messages", Access.all(), "from"])
        |> List.wrap()
        |> List.flatten()
        |> Enum.find(&is_binary/1)

      recipient =
        entry
        |> get_in(["changes", Access.all(), "value", "statuses", Access.all(), "recipient_id"])
        |> List.wrap()
        |> List.flatten()
        |> Enum.find(&is_binary/1)

      from || recipient
    end)
  end

  defp extract_from_phone(_), do: nil

  defp extract_phone_number_id(%{"entry" => entries}) when is_list(entries) do
    Enum.find_value(entries, fn entry ->
      entry
      |> get_in(["changes", Access.all(), "value", "metadata", "phone_number_id"])
      |> List.wrap()
      |> List.flatten()
      |> Enum.find(&is_binary/1)
    end)
  end

  defp extract_phone_number_id(_), do: nil
end
