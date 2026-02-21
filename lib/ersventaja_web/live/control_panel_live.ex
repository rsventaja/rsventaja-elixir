defmodule ErsventajaWeb.ControlPanelLive do
  use ErsventajaWeb, :live_view
  import ErsventajaWeb.Components.Navbar
  import ErsventajaWeb.Components.Hero
  import ErsventajaWeb.Components.Toast

  alias Ersventaja.Policies
  alias Ersventaja.Policies.OCR
  alias Ersventaja.UserManager.Guardian
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, session, socket) do
    token = Map.get(session, "guardian_default_token")
    case token && Guardian.resource_from_token(token) do
      {:ok, user, _claims} ->
        policies = Policies.last_30_days()
        insurers = Policies.get_insurers()

        socket =
          socket
          |> assign(current_user: user)
          |> assign(active_tab: "due")
          |> assign(policies: policies)
          |> assign(insurers: insurers)
          |> assign(query_current: "")
          |> assign(query_current_result: [])
          |> assign(query: "")
          |> assign(query_result: [])
          |> assign(insert_form: %{
            name: "",
            insurer_id: "",
            detail: "",
            start_date: "",
            end_date: "",
            customer_cpf_or_cnpj: "",
            customer_phone: "",
            customer_email: "",
            encoded_file: nil
          })
          |> assign(adding_policy: false)
          |> assign(new_insurer_name: "")
          |> assign(file_selected_shown: false)
          |> assign(processing_ocr: false)
          |> assign(upload_checking: false)
          |> assign(ocr_complete: false)
          |> assign(ocr_file_name: nil)
          |> assign(ocr_file_content: nil)
          |> assign(selected_policy: nil)
          |> assign(editing_policy: false)
          |> assign(edit_form: %{})
          |> allow_upload(:file, accept: ~w(.pdf), max_entries: 1, max_file_size: 10_000_000, auto_upload: true)

        {:ok, socket}

      _ ->
        {:ok, redirect(socket, to: "/login")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = Map.get(params, "tab", "due")
    socket = assign(socket, active_tab: tab)

    # Refresh insurers list when switching to insurers tab
    socket = if tab == "insurers" do
      assign(socket, insurers: Policies.get_insurers())
    else
      socket
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    # Close policy details when switching tabs
    socket = assign(socket, selected_policy: nil)
    {:noreply, push_patch(socket, to: "/controlpanel?tab=#{tab}")}
  end

  @impl true
  def handle_event("update_renewal", %{"id" => id} = params, socket) do
    # Get the current policy to toggle its calculated status
    policy = Enum.find(socket.assigns.policies, fn p -> Integer.to_string(p.id) == id end)

    # Determine new status: if checkbox sends "value" => "on", it means it's being checked
    # Otherwise, toggle based on current state
    new_status = case params do
      %{"value" => "on"} -> true
      %{"value" => _} -> false
      _ -> if policy, do: !policy.calculated, else: false
    end

    Policies.update_status(id, new_status)
    policies = Policies.last_30_days()
    {:noreply, assign(socket, policies: policies)}
  end

  @impl true
  def handle_event("query_current", %{"query" => query}, socket) do
    if String.length(query) > 0 do
      result = Policies.get_policies("true", query)
      {:noreply, assign(socket, query_current_result: result, query_current: "")}
    else
      {:noreply, socket |> put_flash(:warning, "Favor preencher o nome para realizar a busca.")}
    end
  end

  @impl true
  def handle_event("query_all", %{"query" => query}, socket) do
    if String.length(query) > 0 do
      result = Policies.get_policies("false", query)
      {:noreply, assign(socket, query_result: result, query: "")}
    else
      {:noreply, socket |> put_flash(:warning, "Favor preencher o nome para realizar a busca.")}
    end
  end

  @impl true
  def handle_event("noop", _params, socket) do
    # No-op handler to capture clicks and prevent propagation to parent elements
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_policy_details", %{"id" => id}, socket) do
    require Logger
    Logger.info("delete_policy_details event received for id: #{inspect(id)}")

    try do
      Policies.delete_policy(to_string(id))
      Logger.info("Policy #{id} deleted successfully from details view")

      # Remove from all lists and close details
      policies = Policies.last_30_days()
      query_result = Enum.reject(socket.assigns.query_result, fn p -> p.id == id end)
      query_current_result = Enum.reject(socket.assigns.query_current_result, fn p -> p.id == id end)

      socket =
        socket
        |> assign(
          selected_policy: nil,
          policies: policies,
          query_result: query_result,
          query_current_result: query_current_result
        )
        |> put_flash(:success, "Apólice excluída com sucesso!")

      {:noreply, socket}
    rescue
      e ->
        Logger.error("Error deleting policy #{id}: #{inspect(e)}")
        {:noreply, socket |> put_flash(:error, "Erro ao excluir a apólice.")}
    end
  end

  @impl true
  def handle_event("delete_policy", %{"id" => id}, socket) do
    require Logger
    Logger.info("delete_policy event received for id: #{inspect(id)}")

    try do
      Policies.delete_policy(id)
      Logger.info("Policy #{id} deleted successfully")

      query_result = Enum.reject(socket.assigns.query_result, fn p -> p.id == String.to_integer(id) end)

      socket =
        socket
        |> assign(query_result: query_result)
        |> put_flash(:success, "Apólice excluída com sucesso!")

      {:noreply, socket}
    rescue
      e ->
        Logger.error("Error deleting policy #{id}: #{inspect(e)}")
        {:noreply, socket |> put_flash(:error, "Erro ao excluir a apólice.")}
    end
  end

  @impl true
  def handle_event("view_policy", %{"id" => id}, socket) do
    policy_id = String.to_integer(id)
    # Find policy in all available lists
    policy = find_policy_by_id(socket, policy_id)
    {:noreply, assign(socket, selected_policy: policy)}
  end

  @impl true
  def handle_event("close_policy_details", _params, socket) do
    {:noreply, assign(socket, selected_policy: nil, editing_policy: false, edit_form: %{})}
  end

  @impl true
  def handle_event("start_edit_policy", _params, socket) do
    policy = socket.assigns.selected_policy
    edit_form = %{
      "customer_name" => policy.customer_name || "",
      "detail" => policy.detail || "",
      "start_date" => if(policy.start_date, do: Date.to_iso8601(policy.start_date), else: ""),
      "end_date" => if(policy.end_date, do: Date.to_iso8601(policy.end_date), else: ""),
      "insurer_id" => if(policy.insurer_id, do: to_string(policy.insurer_id), else: ""),
      "customer_cpf_or_cnpj" => policy[:customer_cpf_or_cnpj] || "",
      "customer_phone" => policy[:customer_phone] || "",
      "customer_email" => policy[:customer_email] || "",
      "license_plate" => policy[:license_plate] || ""
    }
    {:noreply, assign(socket, editing_policy: true, edit_form: edit_form)}
  end

  @impl true
  def handle_event("cancel_edit_policy", _params, socket) do
    {:noreply, assign(socket, editing_policy: false, edit_form: %{})}
  end

  @impl true
  def handle_event("update_edit_form", %{"edit_form" => form_params}, socket) do
    edit_form = Map.merge(socket.assigns.edit_form, form_params)
    {:noreply, assign(socket, edit_form: edit_form)}
  end

  @impl true
  def handle_event("save_policy", %{"edit_form" => form_params}, socket) do
    policy_id = socket.assigns.selected_policy.id

    attrs = %{
      "customer_name" => String.upcase(form_params["customer_name"] || ""),
      "detail" => String.upcase(form_params["detail"] || ""),
      "start_date" => form_params["start_date"],
      "end_date" => form_params["end_date"],
      "insurer_id" => form_params["insurer_id"],
      "customer_cpf_or_cnpj" => form_params["customer_cpf_or_cnpj"],
      "customer_phone" => form_params["customer_phone"],
      "customer_email" => form_params["customer_email"],
      "license_plate" => form_params["license_plate"]
    }

    case Policies.update_policy(policy_id, attrs) do
      {:ok, updated_policy} ->
        # Refresh all policy lists
        policies = Policies.last_30_days()

        # Update query results if the policy is in them
        query_result = update_policy_in_list(socket.assigns.query_result, updated_policy)
        query_current_result = update_policy_in_list(socket.assigns.query_current_result, updated_policy)

        socket =
          socket
          |> assign(
            selected_policy: updated_policy,
            editing_policy: false,
            edit_form: %{},
            policies: policies,
            query_result: query_result,
            query_current_result: query_current_result
          )
          |> put_flash(:success, "Apólice atualizada com sucesso!")

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket |> put_flash(:error, "Erro ao atualizar a apólice. Verifique os dados e tente novamente.")}
    end
  end

  @impl true
  def handle_event("validate_insert", %{"insert_form" => form_params}, socket) do
    insert_form = Map.merge(socket.assigns.insert_form, form_params)
    socket = assign(socket, insert_form: insert_form)
    # Check for completed uploads
    check_and_process_uploads(socket)
  end

  @impl true
  def handle_event("insert_policy", %{"insert_form" => form_params}, socket) do
    socket = assign(socket, adding_policy: true)

    if valid_insert_form?(form_params, socket) do
      # Use file content from OCR processing if available, otherwise consume upload
      file = if socket.assigns[:ocr_file_content] do
        socket.assigns.ocr_file_content
      else
        # Fallback: consume uploaded file if OCR wasn't processed
        [consumed_file] = consume_uploaded_entries(socket, :file, fn %{path: path}, _entry ->
          content = File.read!(path)
          encoded = Base.encode64(content)
          {:ok, encoded}
        end)
        consumed_file
      end

      attrs = %{
        "name" => String.upcase(form_params["name"] || ""),
        "detail" => String.upcase(form_params["detail"] || ""),
        "start_date" => form_params["start_date"],
        "end_date" => form_params["end_date"],
        "insurer_id" => String.to_integer(form_params["insurer_id"]),
        "encoded_file" => file,
        "customer_cpf_or_cnpj" => form_params["customer_cpf_or_cnpj"],
        "customer_phone" => form_params["customer_phone"],
        "customer_email" => form_params["customer_email"],
        "license_plate" => form_params["license_plate"]
      }

      Policies.add_policy(attrs)
      policies = Policies.last_30_days()

      socket =
        socket
        |> put_flash(:success, "Cadastro realizado com sucesso!")
        |> assign(
          policies: policies,
          insert_form: %{
            name: "",
            insurer_id: "",
            detail: "",
            start_date: "",
            end_date: "",
            customer_cpf_or_cnpj: "",
            customer_phone: "",
            customer_email: "",
            encoded_file: nil
          },
          adding_policy: false,
          ocr_file_name: nil,
          ocr_file_content: nil,
          ocr_complete: false
        )

      {:noreply, socket}
    else
      {:noreply, socket |> put_flash(:warning, "Favor preencher todos os campos antes de prosseguir!") |> assign(adding_policy: false)}
    end
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :file, ref)}
  end

  @impl true
  def handle_event("file_selected", _params, socket) do
    require Logger
    Logger.info("File selected event received, starting periodic upload check")
    # Reset OCR complete flag when new file is selected
    socket = assign(socket, ocr_complete: false)
    # Start periodic check for upload completion
    Process.send_after(self(), :periodic_upload_check, 1000)
    {:noreply, socket}
  end

  @impl true
  def handle_event("progress", %{"upload" => "file", "entry" => entry_ref, "progress" => progress}, socket) do
    require Logger
    Logger.info("Progress event received: entry=#{inspect(entry_ref)}, progress=#{inspect(progress)}, processing_ocr=#{socket.assigns.processing_ocr}")

    # Convert progress to number if it's a string
    progress_num = case progress do
      p when is_integer(p) -> p
      p when is_binary(p) ->
        case Integer.parse(p) do
          {num, _} -> num
          :error ->
            Logger.warn("Could not parse progress as integer: #{inspect(p)}")
            0
        end
      _ ->
        Logger.warn("Unexpected progress type: #{inspect(progress)}")
        0
    end

    Logger.info("Parsed progress: #{progress_num}")

    # Check if upload is complete (progress is 100) and process OCR
    if progress_num >= 100 && not socket.assigns.processing_ocr do
      Logger.info("Upload complete (progress 100%), checking entries...")
      # Small delay to ensure entry is marked as done
      Process.send_after(self(), :check_upload_after_progress, 500)
      {:noreply, socket}
    else
      if socket.assigns.processing_ocr do
        Logger.debug("Already processing OCR, ignoring progress event")
      end
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create_insurer", %{"name" => name}, socket) do
    if String.trim(name) != "" do
      try do
        Policies.add_insurer(String.trim(name))
        insurers = Policies.get_insurers()
        {:noreply, socket |> put_flash(:success, "Operação realizada com sucesso!") |> assign(insurers: insurers, new_insurer_name: "")}
      rescue
        _ ->
          {:noreply, socket |> put_flash(:error, "Erro ao realizar a operação. Verifique se a seguradora não está sendo usada em alguma apólice.")}
      end
    else
      {:noreply, socket |> put_flash(:error, "Erro ao realizar a operação. Verifique se a seguradora não está sendo usada em alguma apólice.")}
    end
  end

  @impl true
  def handle_event("update_insurer_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, new_insurer_name: name)}
  end

  @impl true
  def handle_event("delete_insurer", %{"id" => id}, socket) do
    try do
      Policies.delete_insurer(String.to_integer(id))
      insurers = Policies.get_insurers()
      {:noreply, socket |> put_flash(:success, "Operação realizada com sucesso!") |> assign(insurers: insurers)}
    rescue
      _ ->
        {:noreply, socket |> put_flash(:error, "Erro ao realizar a operação. Verifique se a seguradora não está sendo usada em alguma apólice.")}
    end
  end

  @impl true
  def handle_event("check_upload_complete", _params, socket) do
    require Logger
    Logger.info("check_upload_complete event received")
    check_and_process_uploads(socket)
  end

  # Private helper functions


  defp check_and_process_uploads(socket) do
    require Logger
    {completed_entries, in_progress_entries} = uploaded_entries(socket, :file)

    Logger.info("check_and_process_uploads called - completed: #{length(completed_entries)}, in_progress: #{length(in_progress_entries)}, processing_ocr: #{socket.assigns.processing_ocr}")

    # If there are in-progress uploads, start periodic checking
    if length(in_progress_entries) > 0 && not Map.get(socket.assigns, :upload_checking, false) do
      Logger.info("Upload in progress, starting periodic check")
      socket = assign(socket, upload_checking: true)
      Process.send_after(self(), :periodic_upload_check, 1000)
      {:noreply, socket}
    else
      if length(completed_entries) > 0 do
        Logger.info("Completed entries details: #{inspect(Enum.map(completed_entries, fn e -> %{ref: e.ref, done?: e.done?, client_name: e.client_name} end))}")
      end

      if length(completed_entries) > 0 && not socket.assigns.processing_ocr do
        completed_entry = Enum.find(completed_entries, fn e -> e.done? end)

        if completed_entry do
          Logger.info("Found completed upload entry, starting OCR. File: #{completed_entry.client_name}")
          socket = assign(socket, processing_ocr: true, upload_checking: false)

          # Consume entry to get file content for OCR
          # The file will be re-attached via JavaScript to keep it visible
          try do
            result = consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
              content = File.read!(path)
              encoded = Base.encode64(content)
              {:ok, %{content: content, encoded: encoded, client_name: entry.client_name}}
            end)

            case result do
              [%{content: file_content, encoded: encoded_content, client_name: client_name}] ->
                # Store file content in socket for form submission
                socket = assign(socket,
                  ocr_file_content: encoded_content,
                  ocr_file_name: client_name
                )

                # Save file content to a temporary file for OCR processing
                temp_file = System.tmp_dir!() |> Path.join("ocr_#{:rand.uniform(1_000_000)}.pdf")
                File.write!(temp_file, file_content)
                Logger.info("Saved file to temp location: #{temp_file}")

                insurers = socket.assigns.insurers
                Logger.info("Processing OCR with #{length(insurers)} insurers available, file path: #{temp_file}")

                pid = self()
                Task.start(fn ->
                  Logger.info("OCR task started for file: #{temp_file}")
                  try do
                    case OCR.extract_policy_info(temp_file, insurers) do
                      {:ok, info} ->
                        Logger.info("OCR completed successfully")
                        send(pid, {:ocr_complete, info})
                      {:error, reason} ->
                        Logger.error("OCR failed: #{inspect(reason)}")
                        send(pid, {:ocr_error, reason})
                    end
                  after
                    # Clean up temp file
                    if File.exists?(temp_file), do: File.rm(temp_file)
                  end
                end)

                {:noreply, socket}
              _ ->
                Logger.error("Failed to consume upload entry")
                {:noreply, assign(socket, processing_ocr: false, upload_checking: false)}
            end
          rescue
            e ->
              Logger.error("Error processing file for OCR: #{inspect(e)}")
              {:noreply, assign(socket, processing_ocr: false, upload_checking: false)}
          end
        else
          Logger.warn("No done? entry found in completed entries")
          {:noreply, socket}
        end
      else
        if socket.assigns.processing_ocr do
          Logger.debug("Already processing OCR, skipping")
        end
        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_info(:check_upload_after_progress, socket) do
    require Logger
    Logger.info("Checking upload after progress event")
    check_and_process_uploads(socket)
  end

  @impl true
  def handle_info(:periodic_upload_check, socket) do
    require Logger
    {completed_entries, in_progress_entries} = uploaded_entries(socket, :file)

    Logger.info("Periodic upload check - Completed: #{length(completed_entries)}, In progress: #{length(in_progress_entries)}")

    if length(in_progress_entries) > 0 do
      Logger.info("Upload still in progress, will check again in 1 second")
      # Schedule another check in 1 second
      Process.send_after(self(), :periodic_upload_check, 1000)
      {:noreply, socket}
    else
      # No more in progress, check if we have completed entries
      Logger.info("No more in-progress uploads, checking for completed entries")
      socket = assign(socket, upload_checking: false)
      check_and_process_uploads(socket)
    end
  end

  @impl true
  def handle_info({:ocr_complete, info}, socket) do
    require Logger
    Logger.info("Received OCR complete message with info: #{inspect(Map.keys(info))}")

    # Handle both string and atom keys, and nil values
    start_date = Map.get(info, "start_date") || Map.get(info, :start_date)
    end_date = Map.get(info, "end_date") || Map.get(info, :end_date)
    customer_name = Map.get(info, "customer_name") || Map.get(info, :customer_name) || ""
    customer_cpf_or_cnpj = Map.get(info, "customer_cpf_or_cnpj") || Map.get(info, :customer_cpf_or_cnpj) || ""
    customer_phone = Map.get(info, "customer_phone") || Map.get(info, :customer_phone) || ""
    customer_email = Map.get(info, "customer_email") || Map.get(info, :customer_email) || ""
    insurer_id = Map.get(info, "insurer_id") || Map.get(info, :insurer_id)
    license_plate = Map.get(info, "license_plate") || Map.get(info, :license_plate) || ""

    Logger.info("Extracted data - name: #{customer_name}, insurer_id: #{inspect(insurer_id)}, license_plate: #{license_plate}")

    # Use license_plate for detail if it's a car insurance (has license plate)
    detail = if license_plate != "", do: license_plate, else: ""

    # Format dates for HTML date inputs (YYYY-MM-DD)
    start_date_str = if start_date, do: Date.to_iso8601(start_date), else: ""
    end_date_str = if end_date, do: Date.to_iso8601(end_date), else: ""
    insurer_id_str = if insurer_id, do: Integer.to_string(insurer_id), else: ""

    updated_form = socket.assigns.insert_form
    |> Map.put("name", customer_name)
    |> Map.put("start_date", start_date_str)
    |> Map.put("end_date", end_date_str)
    |> Map.put("customer_cpf_or_cnpj", customer_cpf_or_cnpj)
    |> Map.put("customer_phone", customer_phone)
    |> Map.put("customer_email", customer_email)
    |> Map.put("detail", detail)
    |> Map.put("insurer_id", insurer_id_str)

    Logger.info("Form updated with extracted data")
    socket =
      socket
      |> assign(insert_form: updated_form, processing_ocr: false, ocr_complete: true)
      |> put_flash(:success, "Informações extraídas do PDF com sucesso!")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:ocr_error, reason}, socket) do
    require Logger
    Logger.error("OCR error received: #{inspect(reason)}")
    error_message = format_ocr_error(reason)
    socket =
      socket
      |> assign(processing_ocr: false)
      |> put_flash(:warning, "Não foi possível extrair informações do PDF: #{error_message}. Preencha os campos manualmente.")

    {:noreply, socket}
  end

  @impl true
  def handle_info(msg, socket) do
    require Logger
    Logger.debug("Unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # Private helper functions

  defp valid_insert_form?(form, socket) do
    has_file = Enum.any?(socket.assigns.uploads.file.entries) ||
               Map.has_key?(socket.assigns, :ocr_file_content)

    String.length(form["name"] || "") > 0 &&
      String.length(form["detail"] || "") > 0 &&
      String.length(form["insurer_id"] || "") > 0 &&
      String.length(form["start_date"] || "") > 0 &&
      String.length(form["end_date"] || "") > 0 &&
      has_file
  end

  defp calculate_days(end_date) when is_binary(end_date) do
    today = Date.utc_today()
    end_date = Date.from_iso8601!(end_date)
    Date.diff(end_date, today)
  end

  defp calculate_days(%Date{} = end_date) do
    today = Date.utc_today()
    Date.diff(end_date, today)
  end

  defp file_url(file_name) do
    "https://policiesrsventaja.s3-sa-east-1.amazonaws.com/#{file_name}"
  end

  defp format_date(date) when is_binary(date) do
    date
    |> Date.from_iso8601!()
    |> format_date()
  end

  defp format_date(%Date{} = date) do
    Calendar.strftime(date, "%d/%m/%Y")
  end

  defp error_to_string(:too_large), do: "Arquivo muito grande"
  defp error_to_string(:too_many_files), do: "Muitos arquivos"
  defp error_to_string(:not_accepted), do: "Tipo de arquivo não aceito"

  defp find_policy_by_id(socket, id) do
    # Search in all available policy lists
    Enum.find(socket.assigns.policies, fn p -> p.id == id end) ||
    Enum.find(socket.assigns.query_result, fn p -> p.id == id end) ||
    Enum.find(socket.assigns.query_current_result, fn p -> p.id == id end) ||
    # If not found in cached lists, fetch from database
    Policies.get_policy(id)
  end

  defp update_policy_in_list(list, updated_policy) do
    Enum.map(list, fn p ->
      if p.id == updated_policy.id, do: updated_policy, else: p
    end)
  end

  defp format_ocr_error(reason) when is_tuple(reason) do
    case reason do
      {:ocr_error, message} when is_binary(message) -> message
      {:ocr_error, _} -> "Erro no processamento OCR"
      {:ocr_exit, _} -> "Erro ao executar OCR"
      {:parsing_error, message} when is_binary(message) -> "Erro ao analisar o documento: #{message}"
      {:parsing_error, _} -> "Erro ao analisar o documento"
      {:file_write_error, _} -> "Erro ao salvar arquivo temporário"
      {:invalid_base64, _} -> "Arquivo inválido"
      _ -> "Erro desconhecido: #{inspect(reason)}"
    end
  end

  defp format_ocr_error(reason) when is_atom(reason) do
    case reason do
      :invalid_input -> "Entrada inválida"
      :invalid_base64 -> "Arquivo inválido"
      _ -> "Erro: #{inspect(reason)}"
    end
  end

  defp format_ocr_error(reason) when is_binary(reason), do: reason
  defp format_ocr_error(reason), do: "Erro: #{inspect(reason)}"

  @impl true
  def render(assigns) do
    ~H"""
    <.toast flash={@flash} />
    <style>
      body { margin: 0; padding: 0; font-family: 'Playfair Display', Georgia, serif; color: #504f4f; }

      /* Main Content */
      .main-content { padding-top: 0; background-color: white; min-height: 100vh; }
      .section { padding: 3em 2em; text-align: center; width: 100%; max-width: 100%; }

      /* Tabs */
      .tab-button { padding: 1em 1.5em; font-size: 16px; font-weight: 500; border: none; background: transparent; cursor: pointer; transition: all 0.2s; font-family: 'Playfair Display', Georgia, serif; display: flex; align-items: center; justify-content: center; gap: 0.5em; }
      .tab-button.active { background: linear-gradient(90deg, #3D5FA3 0%, #4A7AC2 35%, #5B9BD5 70%, #7DCDEB 100%); color: white; border-radius: 4px; }
      .tab-button:not(.active) { color: #666; }
      .tab-button:not(.active):hover { background-color: rgba(61, 95, 163, 0.1); border-radius: 4px; }
      .tab-button i { margin: 0; }

      /* Buttons */
      .btn-primary { background: linear-gradient(90deg, #3D5FA3 0%, #4A7AC2 35%, #5B9BD5 70%, #7DCDEB 100%); color: white; padding: 12px 24px; border: none; border-radius: 4px; cursor: pointer; text-decoration: none; display: inline-flex; align-items: center; justify-content: center; gap: 0.5em; box-shadow: 0 2px 4px rgba(0,0,0,0.1); transition: all 0.2s; font-family: 'Playfair Display', Georgia, serif; font-size: 16px; }
      .btn-primary:hover { background: rgba(255, 255, 255, 0.85); color: #1e3a6e; font-weight: 600; border: 1px solid #7DCDEB; }
      .btn-primary i { margin: 0; }
      .btn-danger { background: linear-gradient(90deg, #dc2626 0%, #ef4444 100%); color: white; padding: 8px 16px; border: none; border-radius: 4px; cursor: pointer; font-weight: 500; font-family: 'Playfair Display', Georgia, serif; font-size: 14px; display: inline-flex; align-items: center; justify-content: center; gap: 0.5em; box-shadow: 0 2px 4px rgba(0,0,0,0.1); transition: all 0.2s; }
      .btn-danger:hover { background: rgba(255, 255, 255, 0.9); color: #991b1b; font-weight: 600; border: 1px solid #fca5a5; }
      .btn-danger i { margin: 0; }

      /* Tables */
      .table-container { background: white; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); padding: 2em; margin: 2em 0; }
      .table-container table { width: 100%; border-collapse: collapse; }
      .table-container th { padding: 1em; text-align: left; font-size: 14px; font-weight: 600; color: #504f4f; border-bottom: 2px solid #e5e7eb; font-family: 'Playfair Display', Georgia, serif; }
      .table-container td { padding: 1em; font-size: 15px; color: #504f4f; border-bottom: 1px solid #f3f4f6; font-family: 'Playfair Display', Georgia, serif; }
      .table-container tr:hover { background-color: #f9fafb; }
      .table-container tr.hover-row { transition: all 0.2s ease; }
      .table-container tr.hover-row:hover { background-color: #e0f2fe; box-shadow: 0 2px 4px rgba(74, 122, 194, 0.1); }
      .table-container tr.hover-row td:first-child { border-left: 3px solid transparent; }
      .table-container tr.hover-row:hover td:first-child { border-left: 3px solid #4A7AC2; }

      /* Secondary Button */
      .btn-secondary { background: linear-gradient(90deg, #64748b 0%, #94a3b8 100%); color: white; padding: 8px 16px; border: none; border-radius: 4px; cursor: pointer; font-weight: 500; font-family: 'Playfair Display', Georgia, serif; font-size: 14px; display: inline-flex; align-items: center; justify-content: center; gap: 0.5em; box-shadow: 0 2px 4px rgba(0,0,0,0.1); transition: all 0.2s; }
      .btn-secondary:hover { background: rgba(255, 255, 255, 0.9); color: #475569; font-weight: 600; border: 1px solid #cbd5e1; }

      /* Success Button */
      .btn-success { background: linear-gradient(90deg, #059669 0%, #10b981 100%); color: white; padding: 8px 16px; border: none; border-radius: 4px; cursor: pointer; font-weight: 500; font-family: 'Playfair Display', Georgia, serif; font-size: 14px; display: inline-flex; align-items: center; justify-content: center; gap: 0.5em; box-shadow: 0 2px 4px rgba(0,0,0,0.1); transition: all 0.2s; }
      .btn-success:hover { background: rgba(255, 255, 255, 0.9); color: #059669; font-weight: 600; border: 1px solid #6ee7b7; }

      /* Forms - Override Tailwind and browser defaults */
      input, select, textarea {
        border-radius: 8px !important;
        border: 2px solid #e5e7eb !important;
      }

      .form-input {
        width: 100% !important;
        padding: 12px !important;
        border: 2px solid #e5e7eb !important;
        border-radius: 8px !important;
        font-size: 15px !important;
        font-family: 'Playfair Display', Georgia, serif !important;
        box-sizing: border-box !important;
        height: 44px !important;
        line-height: 1.5 !important;
        transition: all 0.2s ease !important;
        background-color: white !important;
        -webkit-appearance: none !important;
        -moz-appearance: none !important;
        appearance: none !important;
      }
      .form-input:focus {
        outline: none !important;
        border-color: #4A7AC2 !important;
        box-shadow: 0 0 0 3px rgba(74, 122, 194, 0.1) !important;
      }
      .form-input:hover {
        border-color: #cbd5e1 !important;
      }

      select.form-input {
        width: 100% !important;
        min-width: 0 !important;
        height: 44px !important;
        padding: 12px 40px 12px 12px !important;
        overflow: visible !important;
        text-overflow: clip !important;
        white-space: normal !important;
        word-wrap: break-word !important;
        background: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 30 8" width="30"><path fill="%234A7AC2" d="M0,0l6,8l6-8"/></svg>') center right no-repeat !important;
        background-size: 20px !important;
        background-position: right 12px center !important;
        cursor: pointer !important;
      }
      select.form-input:hover {
        border-color: #cbd5e1 !important;
      }
      select.form-input:focus {
        border-color: #4A7AC2 !important;
        box-shadow: 0 0 0 3px rgba(74, 122, 194, 0.1) !important;
      }
      select.form-input option {
        white-space: normal !important;
        padding: 12px !important;
        border-radius: 4px !important;
        background: white !important;
      }

      input[type="date"].form-input {
        cursor: pointer !important;
        position: relative !important;
      }
      input[type="date"].form-input::-webkit-calendar-picker-indicator {
        cursor: pointer !important;
        opacity: 1 !important;
        width: 20px !important;
        height: 20px !important;
        padding: 4px !important;
        margin-left: 8px !important;
        filter: invert(0.5) sepia(1) saturate(5) hue-rotate(200deg) !important;
      }
      input[type="date"].form-input::-webkit-inner-spin-button,
      input[type="date"].form-input::-webkit-clear-button {
        display: none !important;
      }

      /* File input styling */
      input[type="file"].form-input {
        font-size: 15px !important;
        padding: 12px !important;
        cursor: pointer !important;
        width: 100% !important;
        max-width: 100% !important;
        min-width: 0 !important;
        box-sizing: border-box !important;
        display: block !important;
        height: auto !important;
        min-height: 44px !important;
      }
      input[type="file"].form-input::file-selector-button {
        font-size: 14px !important;
        font-family: 'Playfair Display', Georgia, serif !important;
        padding: 10px 16px !important;
        margin-right: 10px !important;
        border-radius: 8px !important;
        border: none !important;
        background: linear-gradient(90deg, #3D5FA3 0%, #4A7AC2 35%, #5B9BD5 70%, #7DCDEB 100%) !important;
        color: white !important;
        font-weight: 500 !important;
        cursor: pointer !important;
        transition: all 0.2s ease !important;
        white-space: nowrap !important;
        flex-shrink: 1 !important;
      }
      /* Hide the default file name text to prevent overflow */
      input[type="file"].form-input::after {
        content: "" !important;
        display: none !important;
      }
      input[type="file"].form-input::file-selector-button:hover {
        background: rgba(255, 255, 255, 0.3) !important;
        color: #1e3a6e !important;
        font-weight: 600 !important;
        border: 1px solid #7DCDEB !important;
      }
      input[type="file"].form-input::-webkit-file-upload-button {
        font-size: 14px !important;
        font-family: 'Playfair Display', Georgia, serif !important;
        padding: 10px 16px !important;
        margin-right: 10px !important;
        border-radius: 8px !important;
        border: none !important;
        background: linear-gradient(90deg, #3D5FA3 0%, #4A7AC2 35%, #5B9BD5 70%, #7DCDEB 100%) !important;
        color: white !important;
        font-weight: 500 !important;
        cursor: pointer !important;
        transition: all 0.2s ease !important;
        white-space: nowrap !important;
      }
      input[type="file"].form-input::-webkit-file-upload-button:hover {
        background: rgba(255, 255, 255, 0.3) !important;
        color: #1e3a6e !important;
        font-weight: 600 !important;
        border: 1px solid #7DCDEB !important;
      }
      /* Hide the default file name text that appears after the button */
      input[type="file"].form-input::after {
        content: "" !important;
      }
    </style>

    <div class="min-h-screen bg-gray-50">
      <.navbar />
      <.hero title="Painel de Controle" subtitle="Gerenciamento de Apólices" />

      <!-- Main Content -->
      <div class="main-content" style="max-width: 1400px; margin: 0 auto; padding: 3em 2em;">
        <!-- Tabs -->
        <div class="bg-white rounded-lg shadow-md mb-6 p-4">
          <nav class="flex flex-wrap gap-2">
            <button
              phx-click="switch_tab"
              phx-value-tab="due"
              class={"tab-button #{if @active_tab == "due", do: "active", else: ""}"}
            >
              <i class="fas fa-clock"></i>
              Apólices a vencer
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="current"
              class={"tab-button #{if @active_tab == "current", do: "active", else: ""}"}
            >
              <i class="fas fa-search"></i>
              Buscar apólices vigentes
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="all"
              class={"tab-button #{if @active_tab == "all", do: "active", else: ""}"}
            >
              <i class="fas fa-list"></i>
              Buscar apólices
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="register"
              class={"tab-button #{if @active_tab == "register", do: "active", else: ""}"}
            >
              <i class="fas fa-plus-circle"></i>
              Cadastrar apólice
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="insurers"
              class={"tab-button #{if @active_tab == "insurers", do: "active", else: ""}"}
            >
              <i class="fas fa-building"></i>
              Configurar seguradoras
            </button>
          </nav>
        </div>

        <%= if @selected_policy do %>
          <!-- Policy Details View -->
          <div class="table-container">
            <div style="margin-bottom: 1.5em; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 1em;">
              <button
                phx-click="close_policy_details"
                class="btn-secondary"
                style="display: inline-flex; align-items: center; gap: 0.5em; padding: 10px 20px; font-size: 15px;"
              >
                <i class="fas fa-arrow-left"></i>
                Voltar
              </button>

              <%= if !@editing_policy do %>
                <button
                  phx-click="start_edit_policy"
                  class="btn-primary"
                  style="display: inline-flex; align-items: center; gap: 0.5em; padding: 10px 20px; font-size: 15px;"
                >
                  <i class="fas fa-edit"></i>
                  Editar
                </button>
              <% end %>
            </div>

            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: 'Playfair Display', Georgia, serif;">
              <%= if @editing_policy, do: "Editar Apólice", else: "Detalhes da Apólice" %>
            </h2>

            <%= if @editing_policy do %>
              <!-- Edit Form -->
              <form phx-submit="save_policy" phx-change="update_edit_form">
                <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1.5em; margin-bottom: 2em;">
                  <!-- Customer Info Card -->
                  <div style="background: linear-gradient(135deg, #f8fafc 0%, #e2e8f0 100%); border-radius: 12px; padding: 1.5em; box-shadow: 0 2px 8px rgba(0,0,0,0.05);">
                    <h3 style="color: #4A7AC2; font-family: 'Playfair Display', Georgia, serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
                      <i class="fas fa-user"></i> Dados do Cliente
                    </h3>
                    <div style="display: flex; flex-direction: column; gap: 1em;">
                      <div>
                        <label style="font-size: 13px; color: #64748b; display: block; margin-bottom: 0.25em;">Nome</label>
                        <input
                          type="text"
                          name="edit_form[customer_name]"
                          value={@edit_form["customer_name"]}
                          class="form-input"
                          placeholder="Nome completo"
                        />
                      </div>
                      <div>
                        <label style="font-size: 13px; color: #64748b; display: block; margin-bottom: 0.25em;">CPF/CNPJ</label>
                        <input
                          type="text"
                          name="edit_form[customer_cpf_or_cnpj]"
                          value={@edit_form["customer_cpf_or_cnpj"]}
                          class="form-input mask-cpf-cnpj"
                          placeholder="000.000.000-00 ou 00.000.000/0000-00"
                          maxlength="18"
                          phx-hook="MaskCpfCnpj"
                          id="edit-cpf-cnpj"
                        />
                      </div>
                      <div>
                        <label style="font-size: 13px; color: #64748b; display: block; margin-bottom: 0.25em;">Telefone</label>
                        <input
                          type="text"
                          name="edit_form[customer_phone]"
                          value={@edit_form["customer_phone"]}
                          class="form-input mask-phone"
                          placeholder="(00) 00000-0000"
                          maxlength="15"
                          phx-hook="MaskPhone"
                          id="edit-phone"
                        />
                      </div>
                      <div>
                        <label style="font-size: 13px; color: #64748b; display: block; margin-bottom: 0.25em;">E-mail</label>
                        <input
                          type="email"
                          name="edit_form[customer_email]"
                          value={@edit_form["customer_email"]}
                          class="form-input"
                          placeholder="email@example.com"
                        />
                      </div>
                    </div>
                  </div>

                  <!-- Policy Info Card -->
                  <div style="background: linear-gradient(135deg, #f0f9ff 0%, #e0f2fe 100%); border-radius: 12px; padding: 1.5em; box-shadow: 0 2px 8px rgba(0,0,0,0.05);">
                    <h3 style="color: #4A7AC2; font-family: 'Playfair Display', Georgia, serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
                      <i class="fas fa-file-contract"></i> Dados da Apólice
                    </h3>
                    <div style="display: flex; flex-direction: column; gap: 1em;">
                      <div>
                        <label style="font-size: 13px; color: #64748b; display: block; margin-bottom: 0.25em;">Seguradora</label>
                        <select
                          name="edit_form[insurer_id]"
                          class="form-input"
                        >
                          <option value="">Selecione uma seguradora</option>
                          <%= for insurer <- @insurers do %>
                            <option value={insurer.id} selected={@edit_form["insurer_id"] == to_string(insurer.id)}>
                              <%= insurer.name %>
                            </option>
                          <% end %>
                        </select>
                      </div>
                      <div>
                        <label style="font-size: 13px; color: #64748b; display: block; margin-bottom: 0.25em;">Informações Adicionais</label>
                        <input
                          type="text"
                          name="edit_form[detail]"
                          value={@edit_form["detail"]}
                          class="form-input"
                          placeholder="Detalhes da apólice"
                          maxlength="50"
                        />
                      </div>
                      <div>
                        <label style="font-size: 13px; color: #64748b; display: block; margin-bottom: 0.25em;">Placa do Veículo</label>
                        <input
                          type="text"
                          name="edit_form[license_plate]"
                          value={@edit_form["license_plate"]}
                          class="form-input"
                          placeholder="ABC-1234"
                        />
                      </div>
                    </div>
                  </div>

                  <!-- Dates Card -->
                  <div style="background: linear-gradient(135deg, #f0fdf4 0%, #dcfce7 100%); border-radius: 12px; padding: 1.5em; box-shadow: 0 2px 8px rgba(0,0,0,0.05);">
                    <h3 style="color: #059669; font-family: 'Playfair Display', Georgia, serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
                      <i class="fas fa-calendar-alt"></i> Vigência
                    </h3>
                    <div style="display: flex; flex-direction: column; gap: 1em;">
                      <div>
                        <label style="font-size: 13px; color: #64748b; display: block; margin-bottom: 0.25em;">Início</label>
                        <input
                          type="date"
                          name="edit_form[start_date]"
                          value={@edit_form["start_date"]}
                          class="form-input"
                        />
                      </div>
                      <div>
                        <label style="font-size: 13px; color: #64748b; display: block; margin-bottom: 0.25em;">Vencimento</label>
                        <input
                          type="date"
                          name="edit_form[end_date]"
                          value={@edit_form["end_date"]}
                          class="form-input"
                        />
                      </div>
                    </div>
                  </div>
                </div>

                <!-- Form Actions -->
                <div style="display: flex; gap: 1em; flex-wrap: wrap; justify-content: flex-end;">
                  <button
                    type="button"
                    phx-click="cancel_edit_policy"
                    class="btn-secondary"
                    style="padding: 12px 24px; font-size: 15px; display: inline-flex; align-items: center; gap: 0.5em;"
                  >
                    <i class="fas fa-times"></i> Cancelar
                  </button>
                  <button
                    type="submit"
                    class="btn-success"
                    style="padding: 12px 24px; font-size: 15px; display: inline-flex; align-items: center; gap: 0.5em;"
                  >
                    <i class="fas fa-save"></i> Salvar
                  </button>
                </div>
              </form>
            <% else %>
              <!-- View Mode -->
              <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1.5em;">
                <!-- Customer Info Card -->
                <div style="background: linear-gradient(135deg, #f8fafc 0%, #e2e8f0 100%); border-radius: 12px; padding: 1.5em; box-shadow: 0 2px 8px rgba(0,0,0,0.05);">
                  <h3 style="color: #4A7AC2; font-family: 'Playfair Display', Georgia, serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
                    <i class="fas fa-user"></i> Dados do Cliente
                  </h3>
                  <div style="display: flex; flex-direction: column; gap: 0.75em;">
                    <div>
                      <span style="font-size: 13px; color: #64748b; display: block;">Nome</span>
                      <span style="font-size: 16px; color: #1e293b; font-weight: 500;"><%= @selected_policy.customer_name %></span>
                    </div>
                    <%= if @selected_policy[:customer_cpf_or_cnpj] && @selected_policy.customer_cpf_or_cnpj != "" do %>
                      <div>
                        <span style="font-size: 13px; color: #64748b; display: block;">CPF/CNPJ</span>
                        <span style="font-size: 16px; color: #1e293b; font-weight: 500;"><%= @selected_policy.customer_cpf_or_cnpj %></span>
                      </div>
                    <% end %>
                    <%= if @selected_policy[:customer_phone] && @selected_policy.customer_phone != "" do %>
                      <div>
                        <span style="font-size: 13px; color: #64748b; display: block;">Telefone</span>
                        <span style="font-size: 16px; color: #1e293b; font-weight: 500;">
                          <a href={"tel:#{@selected_policy.customer_phone}"} style="color: #4A7AC2; text-decoration: none;">
                            <i class="fas fa-phone" style="margin-right: 0.25em;"></i>
                            <%= @selected_policy.customer_phone %>
                          </a>
                        </span>
                      </div>
                    <% end %>
                    <%= if @selected_policy[:customer_email] && @selected_policy.customer_email != "" do %>
                      <div>
                        <span style="font-size: 13px; color: #64748b; display: block;">E-mail</span>
                        <span style="font-size: 16px; color: #1e293b; font-weight: 500;">
                          <a href={"mailto:#{@selected_policy.customer_email}"} style="color: #4A7AC2; text-decoration: none;">
                            <i class="fas fa-envelope" style="margin-right: 0.25em;"></i>
                            <%= @selected_policy.customer_email %>
                          </a>
                        </span>
                      </div>
                    <% end %>
                  </div>
                </div>

                <!-- Policy Info Card -->
                <div style="background: linear-gradient(135deg, #f0f9ff 0%, #e0f2fe 100%); border-radius: 12px; padding: 1.5em; box-shadow: 0 2px 8px rgba(0,0,0,0.05);">
                  <h3 style="color: #4A7AC2; font-family: 'Playfair Display', Georgia, serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
                    <i class="fas fa-file-contract"></i> Dados da Apólice
                  </h3>
                  <div style="display: flex; flex-direction: column; gap: 0.75em;">
                    <div>
                      <span style="font-size: 13px; color: #64748b; display: block;">Seguradora</span>
                      <span style="font-size: 16px; color: #1e293b; font-weight: 500;"><%= @selected_policy.insurer || "Não informada" %></span>
                    </div>
                    <div>
                      <span style="font-size: 13px; color: #64748b; display: block;">Informações Adicionais</span>
                      <span style="font-size: 16px; color: #1e293b; font-weight: 500;"><%= @selected_policy.detail || "—" %></span>
                    </div>
                    <%= if @selected_policy[:license_plate] && @selected_policy.license_plate != "" do %>
                      <div>
                        <span style="font-size: 13px; color: #64748b; display: block;">Placa do Veículo</span>
                        <span style="font-size: 16px; color: #1e293b; font-weight: 600; background-color: #fef3c7; padding: 4px 12px; border-radius: 6px; display: inline-block;">
                          <i class="fas fa-car" style="margin-right: 0.25em; color: #92400e;"></i>
                          <%= @selected_policy.license_plate %>
                        </span>
                      </div>
                    <% end %>
                  </div>
                </div>

                <!-- Dates Card -->
                <div style="background: linear-gradient(135deg, #f0fdf4 0%, #dcfce7 100%); border-radius: 12px; padding: 1.5em; box-shadow: 0 2px 8px rgba(0,0,0,0.05);">
                  <h3 style="color: #059669; font-family: 'Playfair Display', Georgia, serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
                    <i class="fas fa-calendar-alt"></i> Vigência
                  </h3>
                  <div style="display: flex; flex-direction: column; gap: 0.75em;">
                    <div>
                      <span style="font-size: 13px; color: #64748b; display: block;">Início</span>
                      <span style="font-size: 16px; color: #1e293b; font-weight: 500;"><%= format_date(@selected_policy.start_date) %></span>
                    </div>
                    <div>
                      <span style="font-size: 13px; color: #64748b; display: block;">Vencimento</span>
                      <span style="font-size: 16px; color: #1e293b; font-weight: 500;"><%= format_date(@selected_policy.end_date) %></span>
                    </div>
                    <div>
                      <span style="font-size: 13px; color: #64748b; display: block;">Dias Restantes</span>
                      <% days = calculate_days(@selected_policy.end_date) %>
                      <span style={"font-size: 16px; font-weight: 600; padding: 4px 12px; border-radius: 6px; display: inline-block; #{if days <= 0, do: "background-color: #fee2e2; color: #991b1b;", else: if days <= 30, do: "background-color: #fef3c7; color: #92400e;", else: "background-color: #d1fae5; color: #065f46;"}"}>
                        <%= if days <= 0, do: "Vencida", else: "#{days} dias" %>
                      </span>
                    </div>
                  </div>
                </div>
              </div>

              <!-- Actions -->
              <div style="margin-top: 2em; display: flex; gap: 1em; flex-wrap: wrap; justify-content: space-between; align-items: center;">
                <div style="display: flex; gap: 1em; flex-wrap: wrap;">
                  <a
                    href={file_url(@selected_policy.file_name)}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="btn-primary"
                    style="padding: 12px 24px; font-size: 15px; display: inline-flex; align-items: center; gap: 0.5em;"
                  >
                    <i class="fas fa-file-pdf"></i> Abrir PDF
                  </a>
                  <%= if @selected_policy[:customer_phone] && @selected_policy.customer_phone != "" do %>
                    <a
                      href={"https://wa.me/+55#{String.replace(@selected_policy.customer_phone, ~r/\D/, "")}"}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="btn-success"
                      style="padding: 12px 24px; font-size: 15px; display: inline-flex; align-items: center; gap: 0.5em; background-color: #25D366; border-color: #25D366;"
                    >
                      <i class="fab fa-whatsapp"></i> WhatsApp
                    </a>
                  <% end %>
                </div>
                <button
                  phx-click="delete_policy_details"
                  phx-value-id={@selected_policy.id}
                  class="btn-danger"
                  style="padding: 12px 24px; font-size: 15px;"
                  data-confirm="Tem certeza que deseja excluir esta apólice? Esta ação não pode ser desfeita."
                >
                  <i class="fas fa-trash-alt"></i> Excluir Apólice
                </button>
              </div>
            <% end %>
          </div>
        <% else %>

        <%= if @active_tab == "due" do %>
          <div class="table-container">
            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: 'Playfair Display', Georgia, serif;">Apólices com vencimento nos próximos 30 dias</h2>
            <div class="overflow-x-auto">
              <table>
                <thead>
                  <tr>
                    <th>Calculado?</th>
                    <th>Dias Restantes</th>
                    <th>Nome</th>
                    <th>Seguradora</th>
                    <th>Informações Adicionais</th>
                    <th>Início</th>
                    <th>Vencimento</th>
                    <th>Ação</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for policy <- @policies do %>
                    <tr id={"policy-due-#{policy.id}"} phx-click="view_policy" phx-value-id={policy.id} style="cursor: pointer;" class="hover-row">
                      <td phx-click="update_renewal" phx-value-id={policy.id} style="cursor: pointer;">
                        <input
                          type="checkbox"
                          checked={policy.calculated}
                          style="width: 20px; height: 20px; cursor: pointer; pointer-events: none;"
                        />
                      </td>
                      <td>
                        <span style={"padding: 6px 12px; border-radius: 20px; font-size: 13px; font-weight: 600; #{if calculate_days(policy.end_date) <= 7, do: "background-color: #fee2e2; color: #991b1b;", else: "background-color: #fef3c7; color: #92400e;"}"}>
                          <%= calculate_days(policy.end_date) %> dias
                        </span>
                      </td>
                      <td style="font-weight: 500;"><%= policy.customer_name %></td>
                      <td><%= policy.insurer %></td>
                      <td><%= policy.detail %></td>
                      <td><%= format_date(policy.start_date) %></td>
                      <td><%= format_date(policy.end_date) %></td>
                      <td phx-click="noop">
                        <a
                          href={file_url(policy.file_name)}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="btn-primary"
                          style="padding: 8px 16px; font-size: 14px;"
                        >
                          <i class="fas fa-file-pdf"></i> Abrir
                        </a>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>

        <%= if @active_tab == "current" do %>
          <div class="table-container">

            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: 'Playfair Display', Georgia, serif;">Buscar apólices vigentes</h2>

            <form phx-submit="query_current" style="margin-bottom: 2em;">
              <div style="max-width: 600px;">
                <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">
                  Digite parte ou o nome do cliente
                </label>
                <div style="display: flex; gap: 0.75em;">
                  <input
                    type="text"
                    name="query"
                    value={@query_current}
                    class="form-input"
                    placeholder="Nome do cliente..."
                  />
                  <button
                    type="submit"
                    class="btn-primary"
                  >
                    <i class="fas fa-search"></i>
                    <span>Buscar</span>
                  </button>
                </div>
              </div>
            </form>

            <%= if length(@query_current_result) > 0 do %>
              <div class="overflow-x-auto">
                <table>
                  <thead>
                    <tr>
                      <th>Dias Restantes</th>
                      <th>Nome</th>
                      <th>Seguradora</th>
                      <th>Informações Adicionais</th>
                      <th>Início</th>
                      <th>Vencimento</th>
                      <th>Ação</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for policy <- @query_current_result do %>
                      <tr id={"policy-current-#{policy.id}"} phx-click="view_policy" phx-value-id={policy.id} style="cursor: pointer;" class="hover-row">
                        <td>
                          <span style="padding: 6px 12px; border-radius: 20px; font-size: 13px; font-weight: 600; background-color: #d1fae5; color: #065f46;">
                            <%= calculate_days(policy.end_date) %> dias
                          </span>
                        </td>
                        <td style="font-weight: 500;"><%= policy.customer_name %></td>
                        <td><%= policy.insurer %></td>
                        <td><%= policy.detail %></td>
                        <td><%= format_date(policy.start_date) %></td>
                        <td><%= format_date(policy.end_date) %></td>
                        <td phx-click="noop">
                          <a href={file_url(policy.file_name)} target="_blank" rel="noopener noreferrer" class="btn-primary" style="padding: 8px 16px; font-size: 14px;">
                            <i class="fas fa-file-pdf"></i> Abrir
                          </a>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if @active_tab == "all" do %>
          <div class="table-container">

            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: 'Playfair Display', Georgia, serif;">Buscar apólices</h2>

            <form phx-submit="query_all" style="margin-bottom: 2em;">
              <div style="max-width: 600px;">
                <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">
                  Digite parte ou o nome do cliente
                </label>
                <div style="display: flex; gap: 0.75em;">
                  <input
                    type="text"
                    name="query"
                    value={@query}
                    class="form-input"
                    placeholder="Nome do cliente..."
                  />
                  <button
                    type="submit"
                    class="btn-primary"
                  >
                    <i class="fas fa-search"></i>
                    <span>Buscar</span>
                  </button>
                </div>
              </div>
            </form>

            <%= if length(@query_result) > 0 do %>
              <div class="overflow-x-auto">
                <table>
                  <thead>
                    <tr>
                      <th>Nome</th>
                      <th>Seguradora</th>
                      <th>Informações Adicionais</th>
                      <th>Início</th>
                      <th>Vencimento</th>
                      <th>Ações</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for policy <- @query_result do %>
                      <tr id={"policy-all-#{policy.id}"} phx-click="view_policy" phx-value-id={policy.id} style="cursor: pointer;" class="hover-row">
                        <td style="font-weight: 500;"><%= policy.customer_name %></td>
                        <td><%= policy.insurer %></td>
                        <td><%= policy.detail %></td>
                        <td><%= format_date(policy.start_date) %></td>
                        <td><%= format_date(policy.end_date) %></td>
                        <td phx-click="noop" phx-value-stop="true">
                          <div style="display: flex; align-items: center; gap: 0.75em;">
                            <a href={file_url(policy.file_name)} target="_blank" rel="noopener noreferrer" class="btn-primary" style="padding: 8px 16px; font-size: 14px;">
                              <i class="fas fa-file-pdf"></i> Abrir
                            </a>
                            <button
                              phx-click="delete_policy"
                              phx-value-id={policy.id}
                              class="btn-danger"
                              data-confirm="Tem certeza que deseja excluir esta apólice? Esta ação não pode ser desfeita."
                            >
                              <i class="fas fa-trash-alt"></i> Excluir
                            </button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if @active_tab == "register" do %>
          <div class="table-container">

            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: 'Playfair Display', Georgia, serif;">Cadastrar apólice</h2>

            <%= if @adding_policy do %>
              <div class="flex justify-center items-center py-8">
                <div class="flex items-center space-x-3">
                  <i class="fas fa-spinner fa-spin text-brand-blue text-2xl"></i>
                  <span class="text-lg text-gray-600">Processando...</span>
                </div>
              </div>
            <% end %>

            <form phx-submit="insert_policy" phx-change="validate_insert" phx-drop-target={@uploads.file.ref} enctype="multipart/form-data" class="space-y-6">
              <input type="hidden" name="insert_form[encoded_file]" value={@insert_form["encoded_file"] || ""} />

              <!-- Arquivo PDF - sempre visível -->
              <div style="margin-bottom: 1.5em;">
                <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f; font-family: 'Playfair Display', Georgia, serif;">Arquivo PDF</label>
                <div style="position: relative; width: 100%; min-width: 0;" id="file-upload-container">
                  <%= if Map.get(assigns, :ocr_file_name) && !@processing_ocr do %>
                    <div style="padding: 12px; background-color: #f9fafb; border: 2px solid #4A7AC2; border-radius: 8px; color: #059669; font-family: 'Playfair Display', Georgia, serif; font-size: 15px; display: flex; align-items: center; gap: 0.5em;">
                      <i class="fas fa-file-pdf" style="color: #4A7AC2;"></i>
                      <span>✓ Arquivo processado: <%= Map.get(assigns, :ocr_file_name) %></span>
                    </div>
                    <style>
                      /* Hide the LiveView file input when file is processed */
                      #file-upload-input,
                      #file-upload-input ~ * {
                        display: none !important;
                      }
                    </style>
                  <% else %>
                    <.live_file_input
                      upload={@uploads.file}
                      class="form-input"
                      style="font-size: 15px !important; padding: 12px !important; cursor: pointer !important; width: 100% !important; max-width: 100% !important; box-sizing: border-box !important; min-width: 0 !important;"
                      phx-hook="FileSelect"
                      phx-drop-target={@uploads.file.ref}
                      id="file-upload-input"
                    />
                  <% end %>
                </div>
                <%= for {err, idx} <- Enum.with_index(upload_errors(@uploads.file)) do %>
                  <div class="mt-3 bg-red-50 border-l-4 border-red-400 p-3 rounded" id={"upload-error-#{idx}"}>
                    <p class="text-base text-red-700 font-serif"><%= error_to_string(err) %></p>
                  </div>
                <% end %>
                <%= if !Map.get(assigns, :ocr_file_name) && !@processing_ocr do %>
                  <p style="margin-top: 0.75em; font-size: 14px; color: #64748b; font-family: 'Playfair Display', Georgia, serif;">
                    <i class="fas fa-info-circle" style="margin-right: 0.25em;"></i>
                    Selecione um arquivo PDF para carregar automaticamente os dados da apólice.
                  </p>
                <% end %>
              </div>

              <!-- Campos do formulário - só aparecem após PDF ser carregado -->
              <%= if Map.get(assigns, :ocr_file_name) && !@processing_ocr do %>
              <div style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5em; margin-bottom: 1.5em;">
                <div style="min-width: 0;">
                  <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">Nome do proponente</label>
                  <input
                    type="text"
                    name="insert_form[name]"
                    value={@insert_form["name"]}
                    class="form-input"
                    placeholder="Nome completo"
                  />
                </div>

                <div style="min-width: 0;">
                  <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">Seguradora</label>
                  <select
                    name="insert_form[insurer_id]"
                    class="form-input"
                  >
                    <option value="">Selecione uma seguradora</option>
                    <%= for insurer <- @insurers do %>
                      <option value={insurer.id} id={"insurer-option-#{insurer.id}"} selected={@insert_form["insurer_id"] == to_string(insurer.id)}>
                        <%= insurer.name %>
                      </option>
                    <% end %>
                  </select>
                </div>

                <div style="grid-column: span 2;">
                  <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">Informações adicionais</label>
                  <input
                    type="text"
                    name="insert_form[detail]"
                    maxlength="50"
                    value={@insert_form["detail"]}
                    class="form-input"
                    placeholder="Detalhes da apólice"
                  />
                </div>

                <div>
                  <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">Data de início de vigência</label>
                  <input
                    type="date"
                    name="insert_form[start_date]"
                    value={@insert_form["start_date"]}
                    class="form-input"
                  />
                </div>

                <div>
                  <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">Data de fim de vigência</label>
                  <input
                    type="date"
                    name="insert_form[end_date]"
                    value={@insert_form["end_date"]}
                    class="form-input"
                  />
                </div>

                <div style="min-width: 0;">
                  <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">CPF/CNPJ</label>
                  <input
                    type="text"
                    name="insert_form[customer_cpf_or_cnpj]"
                    value={@insert_form["customer_cpf_or_cnpj"]}
                    class="form-input mask-cpf-cnpj"
                    placeholder="000.000.000-00 ou 00.000.000/0000-00"
                    maxlength="18"
                    phx-hook="MaskCpfCnpj"
                    id="insert-cpf-cnpj"
                  />
                </div>

                <div style="min-width: 0;">
                  <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">Telefone</label>
                  <input
                    type="text"
                    name="insert_form[customer_phone]"
                    value={@insert_form["customer_phone"]}
                    class="form-input mask-phone"
                    placeholder="(00) 00000-0000"
                    maxlength="15"
                    phx-hook="MaskPhone"
                    id="insert-phone"
                  />
                </div>

                <div style="grid-column: span 2;">
                  <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">E-mail</label>
                  <input
                    type="email"
                    name="insert_form[customer_email]"
                    value={@insert_form["customer_email"]}
                    class="form-input"
                    placeholder="email@example.com"
                  />
                </div>
              </div>
              <% end %>

              <%= if @processing_ocr do %>
                      <style>
                        @keyframes progress-animation {
                          0% { width: 0%; }
                          10% { width: 10%; }
                          20% { width: 20%; }
                          30% { width: 30%; }
                          40% { width: 40%; }
                          50% { width: 50%; }
                          60% { width: 60%; }
                          70% { width: 70%; }
                          80% { width: 80%; }
                          90%, 100% { width: 90%; }
                        }
                        .ocr-progress-bar-animated {
                          animation: progress-animation 30s linear forwards;
                        }
                        /* Text rotation animation - each text visible for 3s, total 30s cycle */
                        .ocr-text-item {
                          position: absolute;
                          opacity: 0;
                          animation: show-text 30s linear infinite;
                        }
                        @keyframes show-text {
                          0%, 10%, 100% { opacity: 0; }
                          1%, 9% { opacity: 1; }
                        }
                        .ocr-text-item:nth-child(1) { animation-delay: 0s; }
                        .ocr-text-item:nth-child(2) { animation-delay: 3s; }
                        .ocr-text-item:nth-child(3) { animation-delay: 6s; }
                        .ocr-text-item:nth-child(4) { animation-delay: 9s; }
                        .ocr-text-item:nth-child(5) { animation-delay: 12s; }
                        .ocr-text-item:nth-child(6) { animation-delay: 15s; }
                        .ocr-text-item:nth-child(7) { animation-delay: 18s; }
                        .ocr-text-item:nth-child(8) { animation-delay: 21s; }
                        .ocr-text-item:nth-child(9) { animation-delay: 24s; }
                        .ocr-text-item:nth-child(10) { animation-delay: 27s; }
                      </style>
                      <div id="ocr-loading-overlay" style="position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(255, 255, 255, 0.6); z-index: 9999; display: flex; flex-direction: column; justify-content: center; align-items: center; backdrop-filter: blur(2px);">
                        <div style="background-color: white; padding: 3em; border-radius: 16px; box-shadow: 0 10px 40px rgba(0, 0, 0, 0.1); max-width: 500px; text-align: center;">
                          <div style="margin-bottom: 2em;">
                            <i class="fas fa-spinner fa-spin" style="color: #4A7AC2; font-size: 48px;"></i>
                          </div>
                          <h2 style="color: #4A7AC2; font-family: 'Playfair Display', Georgia, serif; font-size: 24px; margin-bottom: 1em; font-weight: 600;">
                            Processando documento...
                          </h2>
                          <div style="color: #504f4f; font-family: 'Playfair Display', Georgia, serif; font-size: 16px; min-height: 30px; display: flex; align-items: center; justify-content: center; position: relative;">
                            <span class="ocr-text-item">Analisando estrutura do documento...</span>
                            <span class="ocr-text-item">Extraindo texto do PDF...</span>
                            <span class="ocr-text-item">Processando imagens com OCR...</span>
                            <span class="ocr-text-item">Identificando campos do documento...</span>
                            <span class="ocr-text-item">Extraindo dados do cliente...</span>
                            <span class="ocr-text-item">Buscando informações da seguradora...</span>
                            <span class="ocr-text-item">Validando datas e valores...</span>
                            <span class="ocr-text-item">Corrigindo erros de leitura...</span>
                            <span class="ocr-text-item">Formatando dados extraídos...</span>
                            <span class="ocr-text-item">Finalizando processamento...</span>
                          </div>
                          <div style="margin-top: 2em; width: 100%; height: 6px; background-color: #e5e7eb; border-radius: 3px; overflow: hidden;">
                            <div class="ocr-progress-bar-animated" style="height: 100%; background: linear-gradient(90deg, #3D5FA3 0%, #4A7AC2 35%, #5B9BD5 70%, #7DCDEB 100%); border-radius: 3px; width: 0%;"></div>
                          </div>
                        </div>
                      </div>
              <% end %>

              <script>
                // Check for completed uploads and trigger OCR
                (function() {
                  const uploadInput = document.getElementById("file-upload-input");
                  if (uploadInput) {
                    let lastChecked = 0;

                    const checkUploads = () => {
                      const now = Date.now();
                      if (now - lastChecked < 500) return;
                      lastChecked = now;

                      const entries = uploadInput.querySelectorAll('[data-phx-entry]');
                      let foundComplete = false;
                      entries.forEach(entry => {
                        const progress = entry.getAttribute('data-phx-entry-progress');
                        if (progress === "100" || entry.classList.contains('phx-done')) {
                          foundComplete = true;
                        }
                      });

                      if (foundComplete) {
                        const form = uploadInput.closest('form');
                        if (form) {
                          const event = new Event('input', { bubbles: true });
                          uploadInput.dispatchEvent(event);
                          const phxChangeEvent = new CustomEvent('phx-change', { bubbles: true });
                          form.dispatchEvent(phxChangeEvent);
                        }
                      }
                    };

                    const intervalId = setInterval(checkUploads, 500);

                    const observer = new MutationObserver(checkUploads);
                    if (uploadInput.parentElement) {
                      observer.observe(uploadInput.parentElement, {
                        childList: true,
                        subtree: true,
                        attributes: true,
                        attributeFilter: ['data-phx-entry-progress', 'class']
                      });
                    }

                    window.addEventListener('beforeunload', function() {
                      clearInterval(intervalId);
                      observer.disconnect();
                    });
                  }
                })();
              </script>

              <!-- Botão de cadastrar - só aparece após PDF ser carregado -->
              <%= if Map.get(assigns, :ocr_file_name) && !@processing_ocr do %>
              <div style="display: flex; flex-direction: column; align-items: flex-end; gap: 1em;">
                <button
                  type="submit"
                  class="btn-primary"
                  style={if @adding_policy, do: "opacity: 0.5; cursor: not-allowed;", else: ""}
                  disabled={@adding_policy}
                >
                  <i class="fas fa-plus-circle"></i>
                  <span>Cadastrar Apólice</span>
                </button>
                <%= if @adding_policy and length(@uploads.file.entries) > 0 do %>
                  <%= for entry <- @uploads.file.entries do %>
                    <div style="width: 100%; max-width: 300px; display: flex; flex-direction: column; gap: 0.5em; margin-top: 0.5em;">
                      <div style="display: flex; justify-content: space-between; align-items: center;">
                        <span style="font-size: 14px; color: #504f4f; font-family: 'Playfair Display', Georgia, serif;">Enviando arquivo...</span>
                        <span style="font-size: 14px; color: #504f4f; font-family: 'Playfair Display', Georgia, serif; font-weight: 500;"><%= entry.progress %>%</span>
                      </div>
                      <div style="width: 100%; height: 8px; background-color: #e5e7eb; border-radius: 4px; overflow: hidden;">
                        <div style={"height: 100%; background: linear-gradient(90deg, #3D5FA3 0%, #4A7AC2 35%, #5B9BD5 70%, #7DCDEB 100%); border-radius: 4px; transition: width 0.3s ease; width: #{entry.progress}%"}></div>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
              <% end %>
            </form>
          </div>
        <% end %>

        <%= if @active_tab == "insurers" do %>
          <div class="table-container">

            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: 'Playfair Display', Georgia, serif;">Configurar Seguradoras</h2>

            <!-- Create New Insurer -->
            <div style="margin-bottom: 3em; padding: 2em; background-color: #f9fafb; border-radius: 8px;">
              <h3 style="font-size: 20px; font-weight: 500; margin-bottom: 1em; color: #504f4f; font-family: 'Playfair Display', Georgia, serif;">Adicionar Nova Seguradora</h3>
              <form phx-submit="create_insurer" phx-change="update_insurer_name" style="display: flex; gap: 0.75em; align-items: flex-end;">
                <div style="flex: 1;">
                  <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">
                    Nome da Seguradora
                  </label>
                  <input
                    type="text"
                    name="name"
                    value={@new_insurer_name}
                    class="form-input"
                    placeholder="Digite o nome da seguradora..."
                    required
                  />
                </div>
                <button
                  type="submit"
                  class="btn-primary"
                  style="height: 44px;"
                >
                  <i class="fas fa-plus"></i>
                  <span>Adicionar</span>
                </button>
              </form>
            </div>

            <!-- List of Insurers -->
            <div>
              <h3 style="font-size: 20px; font-weight: 500; margin-bottom: 1em; color: #504f4f; font-family: 'Playfair Display', Georgia, serif;">Seguradoras Cadastradas</h3>
              <%= if length(@insurers) > 0 do %>
                <div class="overflow-x-auto">
                  <table>
                    <thead>
                      <tr>
                        <th>ID</th>
                        <th>Nome</th>
                        <th>Ações</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for insurer <- @insurers do %>
                        <tr id={"insurer-row-#{insurer.id}"}>
                          <td style="font-weight: 500;"><%= insurer.id %></td>
                          <td style="font-weight: 500;"><%= insurer.name %></td>
                          <td>
                            <button
                              phx-click="delete_insurer"
                              phx-value-id={insurer.id}
                              class="btn-danger"
                            >
                              <i class="fas fa-trash-alt"></i> Excluir
                            </button>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% else %>
                <p style="text-align: center; color: #666; padding: 2em; font-family: 'Playfair Display', Georgia, serif;">Nenhuma seguradora cadastrada ainda.</p>
              <% end %>
            </div>
          </div>
        <% end %>

        <% end %> <!-- End of else for selected_policy -->
      </div>

    </div>
    """
  end
end
