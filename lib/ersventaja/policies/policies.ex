defmodule Ersventaja.Policies do
  alias Ersventaja.Repo
  alias Ersventaja.Customers
  alias Ersventaja.Policies.Adapters.RequestAdapter
  alias Ersventaja.Policies.Adapters.ResponseAdapter
  alias Ersventaja.Policies.Models.InsuranceType
  alias Ersventaja.Policies.Models.Insurer
  alias Ersventaja.Policies.Models.Policy

  import Ecto.Changeset, only: [change: 2]
  @bucket "policiesrsventaja"
  @region "sa-east-1"
  @regex ~r/[^\w]/

  import Ecto.Query

  def add_insurer(id, name) do
    Repo.insert!(%Insurer{
      id: id,
      name: name
    })
  end

  def add_insurer(name) do
    Repo.insert!(%Insurer{
      name: name
    })
  end

  def get_insurers() do
    Repo.all(Insurer)
  end

  def delete_insurer(id) do
    insurer = Repo.get!(Insurer, id)
    Repo.delete!(insurer)
  end

  # Insurance Types CRUD

  def add_insurance_type(name) do
    Repo.insert!(%InsuranceType{name: name})
  end

  def get_insurance_types() do
    Repo.all(from(it in InsuranceType, order_by: it.name))
  end

  def delete_insurance_type(id) do
    insurance_type = Repo.get!(InsuranceType, id)
    Repo.delete!(insurance_type)
  end

  def add_policy(attrs) do
    with request <- RequestAdapter.create_policy_request(attrs) do
      # Handle both base64 encoded and binary file content
      file_content =
        case Base.decode64(request.encoded_file) do
          {:ok, decoded} -> decoded
          # Already binary
          :error -> request.encoded_file
        end

      # Find or create customer by CPF/CNPJ
      customer_id =
        case Customers.find_or_create_by_cpf_cnpj(request.customer_cpf_or_cnpj, %{
               name: request.name,
               phone: request.customer_phone,
               email: request.customer_email
             }) do
          {:ok, customer} when not is_nil(customer) -> customer.id
          _ -> nil
        end

      policy =
        Repo.insert!(%Policy{
          customer_id: customer_id,
          detail: request.detail,
          start_date: request.start_date,
          end_date: request.end_date,
          insurer_id: request.insurer_id,
          calculated: false,
          license_plate: request.license_plate,
          insurance_type_id: request.insurance_type_id
        })

      file_name = get_file_name(policy.id)

      @bucket
      |> ExAws.S3.put_object(file_name, file_content)
      |> ExAws.request!(region: @region)

      policy
    end
  end

  def delete_policy(id) do
    policy = Repo.get_by!(Policy, id: String.to_integer(id))
    file_name = get_file_name(policy.id)

    ExAws.S3.delete_object(@bucket, file_name)
    |> ExAws.request!(region: @region)

    Repo.delete!(policy)
  end

  def last_30_days do
    today = Date.utc_today()
    next_month = Date.add(today, 30)

    query =
      from(p in Policy,
        where: p.end_date > ^today and p.end_date <= ^next_month,
        order_by: p.end_date
      )

    policies_from_query(query)
  end

  def get_policies(current_only, name) do
    today = Date.utc_today()

    like = "%#{String.downcase(name) |> String.split(" ") |> Enum.join("%")}%"

    case String.to_atom(current_only) do
      true ->
        query =
          from(p in Policy,
            left_join: c in assoc(p, :customer),
            where:
              p.start_date <= ^today and p.end_date > ^today and
                (like(fragment("lower(?)", c.name), ^like) or
                   like(fragment("lower(?)", p.detail), ^like)),
            order_by: p.end_date
          )

        policies_from_query(query)

      _ ->
        query =
          from(p in Policy,
            left_join: c in assoc(p, :customer),
            where:
              like(fragment("lower(?)", c.name), ^like) or
                like(fragment("lower(?)", p.detail), ^like),
            order_by: p.end_date
          )

        policies_from_query(query)
    end
  end

  def update_status(id, status) do
    Repo.get_by!(Policy, id: String.to_integer(id))
    |> change(calculated: status)
    |> Repo.update!()
  end

  def get_policy(id) when is_integer(id) do
    case Repo.get(Policy, id) do
      nil ->
        nil

      policy ->
        policy
        |> Repo.preload([:insurer, :insurance_type, :customer])
        |> then(fn p -> Map.merge(p, %{file_name: get_file_name(p.id)}) end)
        |> policy_to_response()
    end
  end

  defp policy_to_response(policy) do
    customer = Map.get(policy, :customer)

    %{
      id: policy.id,
      customer_id: policy.customer_id,
      customer_name: customer_name_from(customer),
      insurer: if(policy.insurer, do: policy.insurer.name, else: nil),
      insurer_id: policy.insurer_id,
      insurance_type: if(policy.insurance_type, do: policy.insurance_type.name, else: nil),
      insurance_type_id: policy.insurance_type_id,
      detail: policy.detail,
      start_date: policy.start_date,
      end_date: policy.end_date,
      calculated: policy.calculated,
      file_name: policy.file_name,
      customer_cpf_or_cnpj: customer_cpf_from(customer),
      customer_phone: customer_phone_from(customer),
      customer_email: customer_email_from(customer),
      license_plate: policy.license_plate
    }
  end

  defp customer_name_from(%{name: name}), do: name
  defp customer_name_from(_), do: nil

  defp customer_cpf_from(%{cpf_cnpj: cpf_cnpj}), do: cpf_cnpj
  defp customer_cpf_from(_), do: nil

  defp customer_phone_from(%{phone: phone}), do: phone
  defp customer_phone_from(_), do: nil

  defp customer_email_from(%{email: email}), do: email
  defp customer_email_from(_), do: nil

  def get_policies_without_cpf(limit \\ 100) do
    query =
      from(p in Policy,
        where: is_nil(p.customer_id),
        order_by: [asc: p.id],
        limit: ^limit
      )

    Repo.all(query)
    |> Repo.preload([:insurer, :insurance_type])
    |> Enum.map(&Map.merge(&1, %{file_name: get_file_name(&1.id)}))
  end

  def count_policies_without_cpf() do
    query =
      from(p in Policy,
        where: is_nil(p.customer_id),
        select: count(p.id)
      )

    Repo.one(query)
  end

  def update_policy(id, attrs) when is_integer(id) do
    policy =
      Policy
      |> Repo.get(id)
      |> Repo.preload(:customer)

    case policy do
      nil ->
        {:error, :not_found}

      policy ->
        # ── Update customer record ──────────────────────────────────────────
        new_cpf = Map.get(attrs, "customer_cpf_or_cnpj")
        new_name = Map.get(attrs, "customer_name")
        new_phone = Map.get(attrs, "customer_phone")
        new_email = Map.get(attrs, "customer_email")

        # Normalize CPF to check if it actually changed
        current_cpf_digits = normalize_cpf_cnpj(policy.customer && policy.customer.cpf_cnpj)
        new_cpf_digits = normalize_cpf_cnpj(new_cpf)

        customer_id =
          cond do
            # CPF removed (cleared) → unlink customer
            is_nil(new_cpf) or new_cpf == "" ->
              nil

            # CPF changed → find or create new customer
            new_cpf_digits != "" and new_cpf_digits != current_cpf_digits ->
              case Customers.find_or_create_by_cpf_cnpj(new_cpf, %{
                     name: new_name,
                     phone: new_phone,
                     email: new_email
                   }) do
                {:ok, customer} when not is_nil(customer) -> customer.id
                _ -> policy.customer_id
              end

            # Same CPF, new customer data → update existing customer
            policy.customer && (new_name || new_phone || new_email) ->
              customer_attrs =
                %{}
                |> maybe_put(:name, new_name)
                |> maybe_put(:phone, new_phone)
                |> maybe_put(:email, new_email)

              case Customers.update_customer(policy.customer, customer_attrs) do
                {:ok, _customer} -> policy.customer_id
                _ -> policy.customer_id
              end

            # No changes to customer
            true ->
              policy.customer_id
          end

        # ── Update policy fields ────────────────────────────────────────────
        changeset =
          policy
          |> change(%{
            customer_id: customer_id,
            detail: Map.get(attrs, "detail", policy.detail),
            start_date: parse_date(Map.get(attrs, "start_date")),
            end_date: parse_date(Map.get(attrs, "end_date")),
            insurer_id: parse_integer(Map.get(attrs, "insurer_id")),
            license_plate: Map.get(attrs, "license_plate", policy.license_plate),
            insurance_type_id:
              parse_integer(Map.get(attrs, "insurance_type_id")) || policy.insurance_type_id
          })

        case Repo.update(changeset) do
          {:ok, updated_policy} ->
            updated_policy
            |> Repo.preload([:insurer, :insurance_type, :customer])
            |> then(fn p -> Map.merge(p, %{file_name: get_file_name(p.id)}) end)
            |> policy_to_response()
            |> then(&{:ok, &1})

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil
  defp parse_date(%Date{} = date), do: date

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_integer(nil), do: nil
  defp parse_integer(""), do: nil
  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  def download_policy_file(file_name) do
    case Process.get({:segfy_test_local_pdf, file_name}) do
      nil ->
        case ExAws.S3.get_object(@bucket, file_name) |> ExAws.request(region: @region) do
          {:ok, %{body: body}} -> {:ok, body}
          {:error, reason} -> {:error, reason}
        end

      local_path ->
        File.read(local_path)
    end
  end

  @download_token_validity_seconds 900

  def get_policies_by_cpf_cnpj(cpf_or_cnpj) when is_binary(cpf_or_cnpj) do
    digits = normalize_cpf_cnpj(cpf_or_cnpj)
    if digits == "" or byte_size(digits) < 11, do: [], else: do_get_policies_by_cpf_cnpj(digits)
  end

  def get_policies_by_cpf_cnpj(_), do: []

  @doc """
  Same as `get_policies_by_cpf_cnpj/1` but only returns active policies
  (end_date > today). Used by the WhatsApp bot to avoid showing expired policies.
  """
  def get_active_policies_by_cpf_cnpj(cpf_or_cnpj) when is_binary(cpf_or_cnpj) do
    digits = normalize_cpf_cnpj(cpf_or_cnpj)

    if digits == "" or byte_size(digits) < 11,
      do: [],
      else: do_get_active_policies_by_cpf_cnpj(digits)
  end

  def get_active_policies_by_cpf_cnpj(_), do: []

  defp do_get_policies_by_cpf_cnpj(digits) do
    query =
      from(p in Policy,
        join: c in assoc(p, :customer),
        where:
          not is_nil(c.cpf_cnpj) and c.cpf_cnpj != "" and
            fragment("regexp_replace(?, '[^0-9]', '', 'g')", c.cpf_cnpj) == ^digits,
        order_by: [desc: p.end_date]
      )

    query
    |> Repo.all()
    |> Repo.preload([:insurer, :insurance_type, :customer])
    |> Enum.map(&Map.merge(&1, %{file_name: get_file_name(&1.id)}))
    |> Enum.map(&policy_to_response/1)
  end

  defp do_get_active_policies_by_cpf_cnpj(digits) do
    today = Date.utc_today()

    query =
      from(p in Policy,
        join: c in assoc(p, :customer),
        where:
          not is_nil(c.cpf_cnpj) and c.cpf_cnpj != "" and
            fragment("regexp_replace(?, '[^0-9]', '', 'g')", c.cpf_cnpj) == ^digits and
            p.end_date > ^today,
        order_by: [desc: p.end_date]
      )

    query
    |> Repo.all()
    |> Repo.preload([:insurer, :insurance_type, :customer])
    |> Enum.map(&Map.merge(&1, %{file_name: get_file_name(&1.id)}))
    |> Enum.map(&policy_to_response/1)
  end

  defp normalize_cpf_cnpj(nil), do: ""
  defp normalize_cpf_cnpj(str), do: String.replace(str, ~r/[^0-9]/, "")

  def generate_download_token(policy_id) when is_integer(policy_id) do
    expiry = System.system_time(:second) + @download_token_validity_seconds
    payload = "#{policy_id}:#{expiry}"
    secret = Application.get_env(:ersventaja, :crypto)[:key]
    sig = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.url_encode64(padding: false)
    Base.url_encode64("#{payload}:#{sig}", padding: false)
  end

  def verify_download_token(token) when is_binary(token) do
    secret = Application.get_env(:ersventaja, :crypto)[:key]

    try do
      decoded = Base.url_decode64!(token, padding: false)
      [id_str, expiry_str, sig] = String.split(decoded, ":", parts: 3)
      expiry = String.to_integer(expiry_str)

      if expiry < System.system_time(:second),
        do: nil,
        else: verify_sig_and_return_id(id_str, expiry_str, sig, secret)
    rescue
      _ -> nil
    end
  end

  def verify_download_token(_), do: nil

  defp verify_sig_and_return_id(id_str, expiry_str, sig, secret) do
    payload = "#{id_str}:#{expiry_str}"
    expected = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.url_encode64(padding: false)
    if Plug.Crypto.secure_compare(sig, expected), do: String.to_integer(id_str), else: nil
  end

  defp policies_from_query(query) do
    query
    |> Repo.all()
    |> Repo.preload([:insurer, :insurance_type, :customer])
    |> Enum.map(&Map.merge(&1, %{file_name: get_file_name(&1.id)}))
    |> ResponseAdapter.get_policy_response()
  end

  defp get_file_name(id) do
    secret_key =
      :ersventaja
      |> Application.fetch_env!(:crypto)
      |> Keyword.get(:key)

    hmac =
      :hmac
      |> :crypto.mac(:sha, secret_key, Integer.to_string(id))
      |> Base.encode64()

    "#{Regex.replace(@regex, hmac, "")}.pdf"
  end
end
