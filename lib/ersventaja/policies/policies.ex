defmodule Ersventaja.Policies do
  alias Ersventaja.Repo
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

      policy =
        Repo.insert!(%Policy{
          customer_name: request.name,
          detail: request.detail,
          start_date: request.start_date,
          end_date: request.end_date,
          insurer_id: request.insurer_id,
          calculated: false,
          customer_cpf_or_cnpj: request.customer_cpf_or_cnpj,
          customer_phone: request.customer_phone,
          customer_email: request.customer_email,
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
            where:
              p.start_date <= ^today and p.end_date > ^today and
                (like(fragment("lower(?)", p.customer_name), ^like) or
                   like(fragment("lower(?)", p.detail), ^like)),
            order_by: p.end_date
          )

        policies_from_query(query)

      _ ->
        query =
          from(p in Policy,
            where:
              like(fragment("lower(?)", p.customer_name), ^like) or
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
        |> Repo.preload([:insurer, :insurance_type])
        |> then(fn p -> Map.merge(p, %{file_name: get_file_name(p.id)}) end)
        |> policy_to_response()
    end
  end

  defp policy_to_response(policy) do
    %{
      id: policy.id,
      customer_name: policy.customer_name,
      insurer: if(policy.insurer, do: policy.insurer.name, else: nil),
      insurer_id: policy.insurer_id,
      insurance_type: if(policy.insurance_type, do: policy.insurance_type.name, else: nil),
      insurance_type_id: policy.insurance_type_id,
      detail: policy.detail,
      start_date: policy.start_date,
      end_date: policy.end_date,
      calculated: policy.calculated,
      file_name: policy.file_name,
      customer_cpf_or_cnpj: policy.customer_cpf_or_cnpj,
      customer_phone: policy.customer_phone,
      customer_email: policy.customer_email,
      license_plate: policy.license_plate
    }
  end

  def get_policies_without_cpf(limit \\ 100) do
    query =
      from(p in Policy,
        where: is_nil(p.customer_cpf_or_cnpj) or p.customer_cpf_or_cnpj == "",
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
        where: is_nil(p.customer_cpf_or_cnpj) or p.customer_cpf_or_cnpj == "",
        select: count(p.id)
      )

    Repo.one(query)
  end

  def update_policy_customer_info(id, attrs) when is_integer(id) do
    case Repo.get(Policy, id) do
      nil ->
        {:error, :not_found}

      policy ->
        policy
        |> change(attrs)
        |> Repo.update()
    end
  end

  def update_policy(id, attrs) when is_integer(id) do
    case Repo.get(Policy, id) do
      nil ->
        {:error, :not_found}

      policy ->
        changeset =
          policy
          |> change(%{
            customer_name: Map.get(attrs, "customer_name", policy.customer_name),
            detail: Map.get(attrs, "detail", policy.detail),
            start_date: parse_date(Map.get(attrs, "start_date")),
            end_date: parse_date(Map.get(attrs, "end_date")),
            insurer_id: parse_integer(Map.get(attrs, "insurer_id")),
            customer_cpf_or_cnpj:
              Map.get(attrs, "customer_cpf_or_cnpj", policy.customer_cpf_or_cnpj),
            customer_phone: Map.get(attrs, "customer_phone", policy.customer_phone),
            customer_email: Map.get(attrs, "customer_email", policy.customer_email),
            license_plate: Map.get(attrs, "license_plate", policy.license_plate),
            insurance_type_id:
              parse_integer(Map.get(attrs, "insurance_type_id")) || policy.insurance_type_id
          })

        case Repo.update(changeset) do
          {:ok, updated_policy} ->
            updated_policy
            |> Repo.preload([:insurer, :insurance_type])
            |> then(fn p -> Map.merge(p, %{file_name: get_file_name(p.id)}) end)
            |> policy_to_response()
            |> then(&{:ok, &1})

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

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
    case ExAws.S3.get_object(@bucket, file_name) |> ExAws.request(region: @region) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @download_token_validity_seconds 900

  def get_policies_by_cpf_cnpj(cpf_or_cnpj) when is_binary(cpf_or_cnpj) do
    digits = normalize_cpf_cnpj(cpf_or_cnpj)
    if digits == "" or byte_size(digits) < 11, do: [], else: do_get_policies_by_cpf_cnpj(digits)
  end

  def get_policies_by_cpf_cnpj(_), do: []

  defp do_get_policies_by_cpf_cnpj(digits) do
    # Compare normalized: DB may store "123.456.789-00", we search by digits only
    query =
      from(p in Policy,
        where:
          not is_nil(p.customer_cpf_or_cnpj) and p.customer_cpf_or_cnpj != "" and
            fragment("regexp_replace(?, '[^0-9]', '', 'g')", p.customer_cpf_or_cnpj) == ^digits,
        order_by: [desc: p.end_date]
      )

    query
    |> Repo.all()
    |> Repo.preload([:insurer, :insurance_type])
    |> Enum.map(&Map.merge(&1, %{file_name: get_file_name(&1.id)}))
    |> Enum.map(&policy_to_response/1)
  end

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
    |> Repo.preload([:insurer, :insurance_type])
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
