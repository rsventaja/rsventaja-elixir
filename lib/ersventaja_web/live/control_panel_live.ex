defmodule ErsventajaWeb.ControlPanelLive do
  use ErsventajaWeb, :live_view
  import ErsventajaWeb.Components.Navbar
  import ErsventajaWeb.Components.Hero
  import ErsventajaWeb.Components.Toast

  alias Ersventaja.Policies
  alias Ersventaja.Policies.OCR
  alias Ersventaja.Segfy.Quotation, as: SegfyQuotation
  alias Ersventaja.UserManager.Guardian

  @impl true
  def mount(_params, session, socket) do
    token = Map.get(session, "guardian_default_token")

    case token && Guardian.resource_from_token(token) do
      {:ok, user, _claims} ->
        policies = Policies.last_30_days()
        insurers = Policies.get_insurers()
        insurance_types = Policies.get_insurance_types()

        socket =
          socket
          |> assign(current_user: user)
          |> assign(active_tab: "due")
          |> assign(policies: policies)
          |> assign(insurers: insurers)
          |> assign(insurance_types: insurance_types)
          |> assign(query_current: "")
          |> assign(query_current_result: [])
          |> assign(query: "")
          |> assign(query_result: [])
          |> assign(search_active_only: true)
          |> assign(
            insert_form: %{
              name: "",
              insurer_id: "",
              insurance_type_id: "",
              detail: "",
              start_date: "",
              end_date: "",
              customer_cpf_or_cnpj: "",
              customer_phone: "",
              customer_email: "",
              encoded_file: nil
            }
          )
          |> assign(adding_policy: false)
          |> assign(new_insurer_name: "")
          |> assign(new_insurance_type_name: "")
          |> assign(file_selected_shown: false)
          |> assign(processing_ocr: false)
          |> assign(upload_checking: false)
          |> assign(ocr_complete: false)
          |> assign(ocr_file_name: nil)
          |> assign(ocr_file_content: nil)
          |> assign(selected_policy: nil)
          |> assign(editing_policy: false)
          |> assign(edit_form: %{})
          |> assign(sort_by: "end_date", sort_dir: "asc")
          |> assign(client_query: "")
          |> assign(client_results: nil)
          |> assign(selected_client: nil)
          |> assign(segfy_renewal_loading: false)
          |> assign(segfy_premiums_preview: nil)
          |> assign(segfy_enabled: Ersventaja.Segfy.enabled?())
          |> allow_upload(:file,
            accept: ~w(.pdf),
            max_entries: 1,
            max_file_size: 10_000_000,
            auto_upload: true
          )

        {:ok, socket}

      _ ->
        {:ok, redirect(socket, to: "/login")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = Map.get(params, "tab", "due")
    socket = assign(socket, active_tab: tab)

    # Refresh insurers/insurance_types list when switching to settings tab
    socket =
      if tab == "insurers" do
        assign(socket,
          insurers: Policies.get_insurers(),
          insurance_types: Policies.get_insurance_types()
        )
      else
        socket
      end

    # Set default sort for each tab
    default_sort =
      case tab do
        "due" -> %{sort_by: "end_date", sort_dir: "asc"}
        "current" -> %{sort_by: "end_date", sort_dir: "asc"}
        "all" -> %{sort_by: "customer_name", sort_dir: "asc"}
        "insurers" -> %{sort_by: "name", sort_dir: "asc"}
        "clients" -> %{sort_by: "end_date", sort_dir: "asc"}
        _ -> %{sort_by: "end_date", sort_dir: "asc"}
      end

    socket = assign(socket, default_sort)

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    # Close policy details when switching tabs
    socket =
      assign(socket,
        selected_policy: nil,
        segfy_renewal_loading: false,
        segfy_premiums_preview: nil
      )

    {:noreply, push_patch(socket, to: "/controlpanel?tab=#{tab}")}
  end

  @impl true
  def handle_event("sort", %{"by" => by}, socket) do
    new_dir =
      if socket.assigns.sort_by == by do
        if socket.assigns.sort_dir == "asc", do: "desc", else: "asc"
      else
        "asc"
      end

    {:noreply, assign(socket, sort_by: by, sort_dir: new_dir)}
  end

  @impl true
  def handle_event("sort_by", params, socket) do
    by = params["by"] || params["value"] || socket.assigns.sort_by
    {:noreply, assign(socket, sort_by: by)}
  end

  @impl true
  def handle_event("search_client", %{"name" => name}, socket) do
    if String.length(String.trim(name)) < 2 do
      {:noreply, socket |> put_flash(:warning, "Digite pelo menos 2 caracteres para buscar.")}
    else
      policies = Policies.get_policies("false", name)
      client_results = group_clients_by_cpf(policies)
      {:noreply, assign(socket, client_results: client_results, client_query: name)}
    end
  end

  @impl true
  def handle_event("update_client_query", %{"name" => val}, socket) do
    {:noreply, assign(socket, client_query: val)}
  end

  @impl true
  def handle_event("view_client", %{"index" => index_str}, socket) do
    idx = String.to_integer(index_str)
    client = Enum.at(socket.assigns.client_results, idx)
    {:noreply, assign(socket, selected_client: client)}
  end

  @impl true
  def handle_event("close_client", _params, socket) do
    {:noreply, assign(socket, selected_client: nil)}
  end

  @impl true
  def handle_event("update_renewal", %{"id" => id} = params, socket) do
    # Get the current policy to toggle its calculated status
    policy = Enum.find(socket.assigns.policies, fn p -> Integer.to_string(p.id) == id end)

    # Determine new status: if checkbox sends "value" => "on", it means it's being checked
    # Otherwise, toggle based on current state
    new_status =
      case params do
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
  def handle_event("query_all", %{"query" => query} = params, socket) do
    active_only = Map.get(params, "active_only") == "true"
    socket = assign(socket, search_active_only: active_only)

    if String.length(query) > 0 do
      filter = if active_only, do: "true", else: "false"
      result = Policies.get_policies(filter, query)
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
  def handle_event("segfy_calcular_renovacao", _params, socket) do
    policy = socket.assigns.selected_policy

    if is_nil(policy) do
      {:noreply, socket |> put_flash(:warning, "Nenhuma apólice selecionada.")}
    else
      parent = self()

      Task.start(fn ->
        result = SegfyQuotation.run(policy)
        send(parent, {:segfy_renewal_done, result})
      end)

      {:noreply, assign(socket, segfy_renewal_loading: true, segfy_premiums_preview: nil)}
    end
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

      query_current_result =
        Enum.reject(socket.assigns.query_current_result, fn p -> p.id == id end)

      socket =
        socket
        |> assign(
          selected_policy: nil,
          segfy_renewal_loading: false,
          segfy_premiums_preview: nil,
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

      query_result =
        Enum.reject(socket.assigns.query_result, fn p -> p.id == String.to_integer(id) end)

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

    {:noreply,
     assign(socket,
       selected_policy: policy,
       segfy_renewal_loading: false,
       segfy_premiums_preview: nil
     )}
  end

  @impl true
  def handle_event("close_policy_details", _params, socket) do
    {:noreply,
     assign(socket,
       selected_policy: nil,
       editing_policy: false,
       edit_form: %{},
       segfy_renewal_loading: false,
       segfy_premiums_preview: nil
     )}
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
      "insurance_type_id" =>
        if(policy[:insurance_type_id], do: to_string(policy[:insurance_type_id]), else: ""),
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
      "insurance_type_id" => form_params["insurance_type_id"],
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

        query_current_result =
          update_policy_in_list(socket.assigns.query_current_result, updated_policy)

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
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Erro ao atualizar a apólice. Verifique os dados e tente novamente."
         )}
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
      file =
        if socket.assigns[:ocr_file_content] do
          socket.assigns.ocr_file_content
        else
          # Fallback: consume uploaded file if OCR wasn't processed
          [consumed_file] =
            consume_uploaded_entries(socket, :file, fn %{path: path}, _entry ->
              content = File.read!(path)
              encoded = Base.encode64(content)
              {:ok, encoded}
            end)

          consumed_file
        end

      insurance_type_id =
        case form_params["insurance_type_id"] do
          nil -> nil
          "" -> nil
          val -> String.to_integer(val)
        end

      attrs = %{
        "name" => String.upcase(form_params["name"] || ""),
        "detail" => String.upcase(form_params["detail"] || ""),
        "start_date" => form_params["start_date"],
        "end_date" => form_params["end_date"],
        "insurer_id" => String.to_integer(form_params["insurer_id"]),
        "insurance_type_id" => insurance_type_id,
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
            insurance_type_id: "",
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
      {:noreply,
       socket
       |> put_flash(:warning, "Favor preencher todos os campos antes de prosseguir!")
       |> assign(adding_policy: false)}
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
  def handle_event(
        "progress",
        %{"upload" => "file", "entry" => entry_ref, "progress" => progress},
        socket
      ) do
    require Logger

    Logger.info(
      "Progress event received: entry=#{inspect(entry_ref)}, progress=#{inspect(progress)}, processing_ocr=#{socket.assigns.processing_ocr}"
    )

    # Convert progress to number if it's a string
    progress_num =
      case progress do
        p when is_integer(p) ->
          p

        p when is_binary(p) ->
          case Integer.parse(p) do
            {num, _} ->
              num

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

        {:noreply,
         socket
         |> put_flash(:success, "Operação realizada com sucesso!")
         |> assign(insurers: insurers, new_insurer_name: "")}
      rescue
        _ ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "Erro ao realizar a operação. Verifique se a seguradora não está sendo usada em alguma apólice."
           )}
      end
    else
      {:noreply,
       socket
       |> put_flash(
         :error,
         "Erro ao realizar a operação. Verifique se a seguradora não está sendo usada em alguma apólice."
       )}
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

      {:noreply,
       socket
       |> put_flash(:success, "Operação realizada com sucesso!")
       |> assign(insurers: insurers)}
    rescue
      _ ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Erro ao realizar a operação. Verifique se a seguradora não está sendo usada em alguma apólice."
         )}
    end
  end

  @impl true
  def handle_event("create_insurance_type", %{"name" => name}, socket) do
    if String.trim(name) != "" do
      try do
        Policies.add_insurance_type(String.trim(name))
        insurance_types = Policies.get_insurance_types()

        {:noreply,
         socket
         |> put_flash(:success, "Tipo de seguro adicionado com sucesso!")
         |> assign(insurance_types: insurance_types, new_insurance_type_name: "")}
      rescue
        _ ->
          {:noreply,
           socket
           |> put_flash(
             :error,
             "Erro ao adicionar tipo de seguro. Verifique se o nome já existe."
           )}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Nome do tipo de seguro não pode ser vazio.")}
    end
  end

  @impl true
  def handle_event("update_insurance_type_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, new_insurance_type_name: name)}
  end

  @impl true
  def handle_event("delete_insurance_type", %{"id" => id}, socket) do
    try do
      Policies.delete_insurance_type(String.to_integer(id))
      insurance_types = Policies.get_insurance_types()

      {:noreply,
       socket
       |> put_flash(:success, "Tipo de seguro removido com sucesso!")
       |> assign(insurance_types: insurance_types)}
    rescue
      _ ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Erro ao remover tipo de seguro. Verifique se não está sendo usado em alguma apólice."
         )}
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

    Logger.info(
      "check_and_process_uploads called - completed: #{length(completed_entries)}, in_progress: #{length(in_progress_entries)}, processing_ocr: #{socket.assigns.processing_ocr}"
    )

    # If there are in-progress uploads, start periodic checking
    if length(in_progress_entries) > 0 && not Map.get(socket.assigns, :upload_checking, false) do
      Logger.info("Upload in progress, starting periodic check")
      socket = assign(socket, upload_checking: true)
      Process.send_after(self(), :periodic_upload_check, 1000)
      {:noreply, socket}
    else
      if length(completed_entries) > 0 do
        Logger.info(
          "Completed entries details: #{inspect(Enum.map(completed_entries, fn e -> %{ref: e.ref, done?: e.done?, client_name: e.client_name} end))}"
        )
      end

      if length(completed_entries) > 0 && not socket.assigns.processing_ocr do
        completed_entry = Enum.find(completed_entries, fn e -> e.done? end)

        if completed_entry do
          Logger.info(
            "Found completed upload entry, starting OCR. File: #{completed_entry.client_name}"
          )

          socket = assign(socket, processing_ocr: true, upload_checking: false)

          # Consume entry to get file content for OCR
          # The file will be re-attached via JavaScript to keep it visible
          try do
            result =
              consume_uploaded_entries(socket, :file, fn %{path: path}, entry ->
                content = File.read!(path)
                encoded = Base.encode64(content)
                {:ok, %{content: content, encoded: encoded, client_name: entry.client_name}}
              end)

            case result do
              [%{content: file_content, encoded: encoded_content, client_name: client_name}] ->
                # Store file content in socket for form submission
                socket =
                  assign(socket,
                    ocr_file_content: encoded_content,
                    ocr_file_name: client_name
                  )

                # Save file content to a temporary file for OCR processing
                temp_file = System.tmp_dir!() |> Path.join("ocr_#{:rand.uniform(1_000_000)}.pdf")
                File.write!(temp_file, file_content)
                Logger.info("Saved file to temp location: #{temp_file}")

                insurers = socket.assigns.insurers
                insurance_types = socket.assigns.insurance_types

                Logger.info(
                  "Processing OCR with #{length(insurers)} insurers and #{length(insurance_types)} insurance types available, file path: #{temp_file}"
                )

                pid = self()

                Task.start(fn ->
                  Logger.info("OCR task started for file: #{temp_file}")

                  try do
                    case OCR.extract_policy_info(temp_file, insurers, insurance_types) do
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

    Logger.info(
      "Periodic upload check - Completed: #{length(completed_entries)}, In progress: #{length(in_progress_entries)}"
    )

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

    customer_cpf_or_cnpj =
      Map.get(info, "customer_cpf_or_cnpj") || Map.get(info, :customer_cpf_or_cnpj) || ""

    customer_phone = Map.get(info, "customer_phone") || Map.get(info, :customer_phone) || ""
    customer_email = Map.get(info, "customer_email") || Map.get(info, :customer_email) || ""
    insurer_id = Map.get(info, "insurer_id") || Map.get(info, :insurer_id)
    insurance_type_id = Map.get(info, "insurance_type_id") || Map.get(info, :insurance_type_id)
    license_plate = Map.get(info, "license_plate") || Map.get(info, :license_plate) || ""

    Logger.info(
      "Extracted data - name: #{customer_name}, insurer_id: #{inspect(insurer_id)}, insurance_type_id: #{inspect(insurance_type_id)}, license_plate: #{license_plate}"
    )

    # Use license_plate for detail if it's a car insurance (has license plate)
    detail = if license_plate != "", do: license_plate, else: ""

    # Format dates for HTML date inputs (YYYY-MM-DD)
    start_date_str = if start_date, do: Date.to_iso8601(start_date), else: ""
    end_date_str = if end_date, do: Date.to_iso8601(end_date), else: ""
    insurer_id_str = if insurer_id, do: Integer.to_string(insurer_id), else: ""

    insurance_type_id_str =
      if insurance_type_id, do: Integer.to_string(insurance_type_id), else: ""

    updated_form =
      socket.assigns.insert_form
      |> Map.put("name", customer_name)
      |> Map.put("start_date", start_date_str)
      |> Map.put("end_date", end_date_str)
      |> Map.put("customer_cpf_or_cnpj", customer_cpf_or_cnpj)
      |> Map.put("customer_phone", customer_phone)
      |> Map.put("customer_email", customer_email)
      |> Map.put("detail", detail)
      |> Map.put("insurer_id", insurer_id_str)
      |> Map.put("insurance_type_id", insurance_type_id_str)

    Logger.info("Form updated with extracted data")

    socket =
      socket
      |> assign(insert_form: updated_form, processing_ocr: false, ocr_complete: true)
      |> put_flash(:success, "Informações extraídas do PDF com sucesso!")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:segfy_renewal_done, result}, socket) do
    socket = assign(socket, segfy_renewal_loading: false)

    case result do
      {:ok, info} ->
        msg =
          cond do
            is_binary(info[:quotation_url]) and info[:quotation_url] != "" ->
              "Segfy: foram gerados 2 multicálculos (renovação + novo orçamento) e salvos no mesmo código Gestão. Abra: #{info[:quotation_url]}"

            info[:quotation_id] ->
              extra =
                if info[:codigo_orcamento] do
                  " Código orçamento gestão: #{info.codigo_orcamento}."
                else
                  ""
                end

              "Renovação Segfy calculada. Cotação: #{info[:quotation_id]}.#{extra}"

            true ->
              "Segfy: operação concluída."
          end

        {:noreply,
         socket
         |> assign(segfy_premiums_preview: segfy_build_premiums_preview(info))
         |> put_flash(:success, msg)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(segfy_premiums_preview: nil)
         |> put_flash(:error, format_segfy_renewal_error(reason))}
    end
  end

  @impl true
  def handle_info({:ocr_error, reason}, socket) do
    require Logger
    Logger.error("OCR error received: #{inspect(reason)}")
    error_message = format_ocr_error(reason)

    socket =
      socket
      |> assign(processing_ocr: false)
      |> put_flash(
        :warning,
        "Não foi possível extrair informações do PDF: #{error_message}. Preencha os campos manualmente."
      )

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
    has_file =
      Enum.any?(socket.assigns.uploads.file.entries) ||
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

  defp days_remaining_badge_style(days) do
    bg =
      cond do
        days <= 0 -> "background-color: #fee2e2; color: #991b1b;"
        days <= 30 -> "background-color: #fef3c7; color: #92400e;"
        true -> "background-color: #d1fae5; color: #065f46;"
      end

    "font-size: 16px; font-weight: 600; padding: 4px 12px; border-radius: 6px; display: inline-block; " <>
      bg
  end

  defp days_table_badge_class(days) do
    suffix =
      cond do
        days <= 0 -> "expired"
        days <= 30 -> "soon"
        true -> "ok"
      end

    "days-badge " <> suffix
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
    # If not found in cached lists, fetch from database
    Enum.find(socket.assigns.policies, fn p -> p.id == id end) ||
      Enum.find(socket.assigns.query_result, fn p -> p.id == id end) ||
      Enum.find(socket.assigns.query_current_result, fn p -> p.id == id end) ||
      Policies.get_policy(id)
  end

  defp update_policy_in_list(list, updated_policy) do
    Enum.map(list, fn p ->
      if p.id == updated_policy.id, do: updated_policy, else: p
    end)
  end

  defp format_ocr_error(reason) when is_tuple(reason) do
    case reason do
      {:ocr_error, message} when is_binary(message) ->
        message

      {:ocr_error, _} ->
        "Erro no processamento OCR"

      {:ocr_exit, _} ->
        "Erro ao executar OCR"

      {:parsing_error, message} when is_binary(message) ->
        "Erro ao analisar o documento: #{message}"

      {:parsing_error, _} ->
        "Erro ao analisar o documento"

      {:file_write_error, _} ->
        "Erro ao salvar arquivo temporário"

      {:invalid_base64, _} ->
        "Arquivo inválido"

      _ ->
        "Erro desconhecido: #{inspect(reason)}"
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

  defp segfy_build_premiums_preview(info) when is_map(info) do
    %{
      renovation: segfy_socket_result_rows(Map.get(info, :renovation)),
      new_quotation: segfy_socket_result_rows(Map.get(info, :new_quotation))
    }
  end

  defp segfy_build_premiums_preview(_), do: %{renovation: [], new_quotation: []}

  defp segfy_socket_result_rows(%{multicalculo_socket_results: list}) when is_list(list) do
    list
    |> Enum.filter(&segfy_main_result_row?/1)
    |> deduplicate_by_company()
  end

  defp segfy_socket_result_rows(_), do: []

  # Só mostra RESULT com status "ok" (cotação principal) ou "failure" sem premium
  # Ignora STEP e additional_product
  defp segfy_main_result_row?(%{"socket_action" => "RESULT"} = row) do
    st = (row["status"] || "") |> to_string() |> String.downcase()
    st in ["ok", "failure"]
  end

  defp segfy_main_result_row?(%{"action" => "RESULT"} = row) do
    st = (row["status"] || "") |> to_string() |> String.downcase()
    st in ["ok", "failure"]
  end

  defp segfy_main_result_row?(_), do: false

  # Se há múltiplos RESULT por seguradora, mantém o que tem premium > 0 (ou o último)
  defp deduplicate_by_company(rows) do
    rows
    |> Enum.group_by(fn row ->
      (segfy_display_company(row) || "—") |> String.downcase() |> String.trim()
    end)
    |> Enum.map(fn {_key, group} ->
      Enum.find(group, List.last(group), fn r ->
        p = r["premium"]
        is_number(p) and p > 0
      end)
    end)
    |> Enum.sort_by(fn r ->
      p = r["premium"]
      if is_number(p) and p > 0, do: p, else: 999_999_999
    end)
  end

  defp segfy_display_company(row) when is_map(row) do
    n = Map.get(row, "company_name")

    if is_binary(n) and n != "" do
      n
    else
      case Map.get(row, "raw") do
        %{"company" => c} when is_map(c) ->
          name =
            Map.get(c, "full_name") || Map.get(c, "name")

          if is_binary(name) and name != "", do: name, else: "—"

        _ ->
          "—"
      end
    end
  end

  defp segfy_display_company(_), do: "—"

  defp segfy_display_cell(nil), do: "—"
  defp segfy_display_cell(s) when is_binary(s), do: s
  defp segfy_display_cell(n) when is_number(n), do: to_string(n)
  defp segfy_display_cell(other), do: inspect(other)

  defp segfy_display_money(nil), do: "—"

  defp segfy_display_money(n) when is_number(n) do
    s = :io_lib.format("~.2f", [n * 1.0]) |> List.to_string()

    case String.split(s, ".") do
      [a, b] -> "R$ #{a},#{b}"
      _ -> "R$ #{s}"
    end
  end

  defp segfy_display_money(s) when is_binary(s) do
    case Float.parse(String.replace(s, ",", ".")) do
      {f, _} -> segfy_display_money(f)
      _ -> s
    end
  end

  defp segfy_display_money(other), do: segfy_display_cell(other)

  defp format_segfy_renewal_error(:missing_automation_token),
    do:
      "Token de automação ausente: defina SEGFY_AUTOMATION_TOKEN ou confirme login SSO (cookie segfy_sessiontoken após Firebase)."

  defp format_segfy_renewal_error(:missing_upfy_gate_auth),
    do:
      "Configure SEGFY_FIREBASE_WEB_API_KEY, SEGFY_LOGIN_EMAIL e SEGFY_LOGIN_PASSWORD (login Firebase no gate)."

  defp format_segfy_renewal_error(:missing_firebase_api_key),
    do: "Defina SEGFY_FIREBASE_WEB_API_KEY (Web API Key do Firebase no request verifyPassword)."

  defp format_segfy_renewal_error(:missing_login_email), do: "Defina SEGFY_LOGIN_EMAIL."
  defp format_segfy_renewal_error(:missing_login_password), do: "Defina SEGFY_LOGIN_PASSWORD."

  defp format_segfy_renewal_error(:sso_no_set_cookie),
    do:
      "Login SSO Segfy não devolveu cookies — verifique SEGFY_LOGIN_EMAIL / SEGFY_LOGIN_PASSWORD e a API key Firebase."

  defp format_segfy_renewal_error({:firebase, err}),
    do: "Firebase (login Segfy): #{firebase_err_msg(err)}"

  defp format_segfy_renewal_error(:renewal_list_is_insurer_wizard_not_rows),
    do:
      "A API renewal-list devolve o catálogo de seguradoras (tela), não a tabela de renovações. " <>
        "A lista de casos vem do GET gestão OrcamentosRenovacao (iframe do app) ou do Gate budget/list."

  defp format_segfy_renewal_error(:no_segfy_match),
    do:
      "Nenhum orçamento na Segfy correspondeu a este cliente e vigência. Confira nome, CPF e datas na apólice e na importação Segfy."

  defp format_segfy_renewal_error(:quotation_id_not_found),
    do: "Item da listagem Segfy sem ID de cotação — formato da API pode ter mudado."

  defp format_segfy_renewal_error(:invalid_quotation_id),
    do: "ID de cotação inválido na listagem Segfy."

  defp format_segfy_renewal_error({:http, status, body}),
    do: "Segfy HTTP #{status}: #{String.slice(to_string(body), 0, 280)}"

  defp format_segfy_renewal_error({:invalid_json, _}), do: "Resposta Segfy não é JSON válido."

  defp format_segfy_renewal_error(:policy_pdf_required_for_segfy_payload),
    do:
      "Sem match na Segfy: envie o PDF da apólice para extrair dados via OCR/LLM (OPENAI_API_KEY) ou ajuste cliente/vigência."

  defp format_segfy_renewal_error({:ocr_payload_failed, _}),
    do: "Falha ao montar dados a partir do PDF (OCR/LLM). Verifique o arquivo e OPENAI_API_KEY."

  defp format_segfy_renewal_error({:calculate_failed, mode, reason}),
    do: "Cálculo Segfy (#{mode}): #{format_segfy_renewal_error(reason)}"

  defp format_segfy_renewal_error({:calculate_not_ok, mode, status, msg}),
    do: "Segfy calculate (#{mode}) status=#{inspect(status)} — #{inspect(msg)}"

  defp format_segfy_renewal_error({:salva_failed, mode, reason}),
    do: "Salvar cotação (#{mode}): #{format_segfy_renewal_error(reason)}"

  defp format_segfy_renewal_error(:gestao_prosseguir_not_logged_in),
    do:
      "Gestão Segfy não exibiu a lista de renovações (sessão). Confira login Firebase/SSO e cookie vuex após auth/login no gate."

  defp format_segfy_renewal_error(:gestao_prosseguir_not_renewal_list),
    do:
      "Gestão Segfy não exibiu a grade de renovações (HTML sem lblSegurado — login ou página errada). Confira SSO, cookie vuex após auth/login e se OrcamentosRenovacao abre no browser com a mesma sessão."

  defp format_segfy_renewal_error(err)
       when err in [
              :gestao_prosseguir_no_form,
              :gestao_prosseguir_no_scriptmanager,
              :gestao_prosseguir_no_prosseguir_link,
              :gestao_prosseguir_no_rows
            ],
       do:
         "Não foi possível concluir o passo Prosseguir no Gestão (HTML ASP.NET). Tente de novo ou verifique a linha da apólice."

  defp format_segfy_renewal_error(err)
       when err in [
              :gestao_prosseguir_not_redirect,
              :gestao_prosseguir_bad_redirect,
              :gestao_prosseguir_no_cod_in_redirect,
              :gestao_prosseguir_bad_html,
              :gestao_prosseguir_no_response
            ],
       do:
         "Resposta inesperada do Gestão ao prosseguir renovação. Verifique sessão e tente novamente."

  defp format_segfy_renewal_error(:gestao_prosseguir_redirect_limit),
    do:
      "Muitos redirects no Gestão (limite de saltos). Sessão ou cookie vuex pode estar incompleto."

  defp format_segfy_renewal_error(:gestao_prosseguir_redirect_loop),
    do:
      "Loop de redirects no Gestão (login/sessão). Confira cookie vuex após auth/login no gate e SSO."

  defp format_segfy_renewal_error({:max_redirect_overflow, _}),
    do:
      "Loop de redirects HTTP no Gestão. Rebuild da imagem com a correção (GET sem follow automático no Prosseguir)."

  defp format_segfy_renewal_error(other), do: "Segfy: #{inspect(other)}"

  defp firebase_err_msg(%{"message" => m}) when is_binary(m), do: m
  defp firebase_err_msg(err), do: inspect(err)

  defp group_clients_by_cpf(policies) do
    {with_cpf, without_cpf} =
      Enum.split_with(policies, fn p ->
        p.customer_cpf_or_cnpj && p.customer_cpf_or_cnpj != ""
      end)

    cpf_groups =
      with_cpf
      |> Enum.group_by(fn p -> String.replace(p.customer_cpf_or_cnpj || "", ~r/[^0-9]/, "") end)
      |> Enum.map(fn {_cpf, pols} -> aggregate_client(pols) end)

    no_cpf_groups = Enum.map(without_cpf, fn p -> aggregate_client([p]) end)
    cpf_groups ++ no_cpf_groups
  end

  defp aggregate_client(policies) do
    uniq = fn list -> list |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.uniq() end

    %{
      cpf_cnpj: policies |> Enum.map(& &1.customer_cpf_or_cnpj) |> uniq.() |> List.first(),
      name: policies |> Enum.map(& &1.customer_name) |> uniq.() |> List.first() || "—",
      phones: policies |> Enum.map(& &1.customer_phone) |> uniq.(),
      emails: policies |> Enum.map(& &1.customer_email) |> uniq.(),
      policies: policies
    }
  end

  defp sort_policies(policies, sort_by, sort_dir) do
    sorted =
      case sort_by do
        "customer_name" ->
          Enum.sort_by(policies, &String.downcase(&1.customer_name || ""))

        "insurer" ->
          Enum.sort_by(policies, &String.downcase(to_string(&1.insurer || "")))

        "insurance_type" ->
          Enum.sort_by(policies, &String.downcase(to_string(&1[:insurance_type] || "")))

        "detail" ->
          Enum.sort_by(policies, &String.downcase(to_string(&1.detail || "")))

        "start_date" ->
          Enum.sort_by(policies, &date_sort_key(&1.start_date))

        "end_date" ->
          Enum.sort_by(policies, &date_sort_key(&1.end_date))

        "calculated" ->
          Enum.sort_by(policies, &if(&1.calculated, do: 1, else: 0))

        "name" ->
          Enum.sort_by(policies, &String.downcase(&1.name || ""))

        _ ->
          policies
      end

    if sort_dir == "desc", do: Enum.reverse(sorted), else: sorted
  end

  defp date_sort_key(%Date{} = d), do: {d.year, d.month, d.day}
  defp date_sort_key(s) when is_binary(s), do: s |> Date.from_iso8601!() |> date_sort_key()
  defp date_sort_key(_), do: {0, 0, 0}

  defp sort_icon(sort_by, sort_dir, col) do
    cond do
      sort_by == col && sort_dir == "asc" -> "fas fa-sort-up"
      sort_by == col && sort_dir == "desc" -> "fas fa-sort-down"
      true -> "fas fa-sort"
    end
  end

  defp sort_th_style(_sort_by, _col), do: ""

  defp sort_btn_class(sort_by, col) do
    if sort_by == col, do: "sort-btn active-sort", else: "sort-btn"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.toast flash={@flash} />
    <style>
      .control-panel-body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; }
      #toast-container p { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; }
      body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; color: #504f4f; }

      /* Main Content */
      .main-content { padding-top: 0; background-color: white; min-height: 100vh; }
      .section { padding: 3em 2em; text-align: center; width: 100%; max-width: 100%; }

      /* Tabs */
      .tab-button { padding: 1em 1.5em; font-size: 16px; font-weight: 500; border: none; background: transparent; cursor: pointer; transition: all 0.2s; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; display: flex; align-items: center; justify-content: center; gap: 0.5em; }
      .tab-button.active { background: linear-gradient(90deg, #3D5FA3 0%, #4A7AC2 35%, #5B9BD5 70%, #7DCDEB 100%); color: white; border-radius: 4px; }
      .tab-button:not(.active) { color: #666; }
      .tab-button:not(.active):hover { background-color: rgba(61, 95, 163, 0.1); border-radius: 4px; }
      .tab-button i { margin: 0; }

      /* Buttons */
      .btn-primary { background: linear-gradient(90deg, #3D5FA3 0%, #4A7AC2 35%, #5B9BD5 70%, #7DCDEB 100%); color: white; padding: 12px 24px; border: none; border-radius: 4px; cursor: pointer; text-decoration: none; display: inline-flex; align-items: center; justify-content: center; gap: 0.5em; box-shadow: 0 2px 4px rgba(0,0,0,0.1); transition: all 0.2s; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 16px; }
      .btn-primary:hover { background: rgba(255, 255, 255, 0.85); color: #1e3a6e; font-weight: 600; border: 1px solid #7DCDEB; }
      .btn-primary i { margin: 0; }
      .btn-danger { background: linear-gradient(90deg, #dc2626 0%, #ef4444 100%); color: white; padding: 8px 16px; border: none; border-radius: 4px; cursor: pointer; font-weight: 500; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 14px; display: inline-flex; align-items: center; justify-content: center; gap: 0.5em; box-shadow: 0 2px 4px rgba(0,0,0,0.1); transition: all 0.2s; }
      .btn-danger:hover { background: rgba(255, 255, 255, 0.9); color: #991b1b; font-weight: 600; border: 1px solid #fca5a5; }
      .btn-danger i { margin: 0; }

      /* Tables */
      .table-container { background: white; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1); padding: 2em; margin: 2em 0; }
      .table-container table { width: 100%; border-collapse: collapse; }
      .table-container th { padding: 1em; text-align: left; font-size: 14px; font-weight: 600; color: #504f4f; border-bottom: 2px solid #e5e7eb; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; }
      .table-container td { padding: 1em; font-size: 15px; color: #504f4f; border-bottom: 1px solid #f3f4f6; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; }
      .table-container tr:hover { background-color: #f9fafb; }
      .table-container tr.hover-row { transition: all 0.2s ease; }
      .table-container tr.hover-row:hover { background-color: #e0f2fe; box-shadow: 0 2px 4px rgba(74, 122, 194, 0.1); }
      .table-container tr.hover-row td:first-child { border-left: 3px solid transparent; }
      .table-container tr.hover-row:hover td:first-child { border-left: 3px solid #4A7AC2; }

      /* Secondary Button */
      .btn-secondary { background: linear-gradient(90deg, #64748b 0%, #94a3b8 100%); color: white; padding: 8px 16px; border: none; border-radius: 4px; cursor: pointer; font-weight: 500; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 14px; display: inline-flex; align-items: center; justify-content: center; gap: 0.5em; box-shadow: 0 2px 4px rgba(0,0,0,0.1); transition: all 0.2s; }
      .btn-secondary:hover { background: rgba(255, 255, 255, 0.9); color: #475569; font-weight: 600; border: 1px solid #cbd5e1; }

      /* Success Button */
      .btn-success { background: linear-gradient(90deg, #059669 0%, #10b981 100%); color: white; padding: 8px 16px; border: none; border-radius: 4px; cursor: pointer; font-weight: 500; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 14px; display: inline-flex; align-items: center; justify-content: center; gap: 0.5em; box-shadow: 0 2px 4px rgba(0,0,0,0.1); transition: all 0.2s; }
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
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif !important;
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
        padding: 0 40px 0 14px !important;
        background-color: white !important;
        background-image: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><path fill="%234A7AC2" d="M8 11L2 5h12z"/></svg>') !important;
        background-repeat: no-repeat !important;
        background-size: 16px !important;
        background-position: right 12px center !important;
        cursor: pointer !important;
        font-weight: 500 !important;
        color: #374151 !important;
      }
      select.form-input:hover {
        border-color: #4A7AC2 !important;
      }
      select.form-input:focus {
        border-color: #4A7AC2 !important;
        box-shadow: 0 0 0 3px rgba(74, 122, 194, 0.12) !important;
      }
      select.form-input option {
        background: white !important;
        color: #374151 !important;
        padding: 10px 14px !important;
        font-size: 14px !important;
        font-weight: 400 !important;
      }
      select.form-input option:checked,
      select.form-input option:hover {
        background: linear-gradient(#dbeafe, #dbeafe) !important;
        color: #1d4ed8 !important;
        font-weight: 600 !important;
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
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif !important;
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
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif !important;
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

      /* Tab navigation groups */
      .tab-divider { width: 1px; min-width: 1px; height: 28px; background: #e2e8f0; flex-shrink: 0; align-self: center; margin: 0 4px; }
      .tab-settings-btn { margin-left: auto; flex-shrink: 0; background: none !important; border: none !important; box-shadow: none !important; cursor: pointer; color: #94a3b8; font-size: 18px; padding: 8px 10px !important; border-radius: 6px; transition: color 0.2s, background 0.2s; display: flex; align-items: center; }
      .tab-settings-btn:hover { color: #4A7AC2; background-color: rgba(74,122,194,0.08) !important; }
      .tab-settings-btn.active { color: #4A7AC2; background-color: rgba(74,122,194,0.12) !important; }
      .tab-group-label { font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; color: #cbd5e1; padding: 0 4px; white-space: nowrap; align-self: center; flex-shrink: 0; display: none; }
      @media (min-width: 900px) { .tab-group-label { display: block; } }

      /* Sort headers */
      .sort-th { cursor: pointer; user-select: none; white-space: nowrap; }
      .sort-btn { background: none !important; border: none !important; box-shadow: none !important; cursor: pointer; font-weight: 600; font-size: 14px; color: #504f4f; display: inline-flex; align-items: center; gap: 0.4em; padding: 0 !important; margin: 0 !important; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; outline: none !important; }
      .sort-btn:hover, .sort-btn:focus, .sort-btn:active { background: none !important; box-shadow: none !important; color: #4A7AC2; outline: none !important; }
      .sort-btn .sort-icon { font-size: 10px; color: #cbd5e1; transition: color 0.15s; }
      .sort-btn:hover .sort-icon, .sort-btn:focus .sort-icon { color: #4A7AC2; }
      .sort-btn.active-sort .sort-icon { color: #4A7AC2; }
      .mobile-sort-bar { display: none; align-items: center; justify-content: flex-end; gap: 0.4em; margin-bottom: 0.6em; flex-wrap: nowrap; }
      .mobile-sort-bar-label { font-size: 11px; font-weight: 500; color: #aab4be; white-space: nowrap; flex-shrink: 0; }
      .mobile-sort-bar form { flex: 0 1 auto; margin: 0; }
      .mobile-sort-bar .form-input { border: 1px solid #e2e8f0 !important; background: #fafbfc !important; font-size: 12px !important; height: 30px !important; padding: 0 1.8em 0 0.5em !important; color: #504f4f; min-width: 0; width: auto; }
      .sort-dir-btn { background: #eef2f9; color: #3D5FA3; border: 1px solid #c5d3e8; border-radius: 6px; height: 30px; padding: 0 10px; cursor: pointer; display: flex; align-items: center; justify-content: center; flex-shrink: 0; font-size: 12px; font-weight: 600; gap: 0.3em; white-space: nowrap; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }
      .sort-dir-btn:active { background: #dbe5f5; }

      /* ===== CLIENT SEARCH TAB ===== */
      .client-profile { background: linear-gradient(135deg, #f8fafc 0%, #e2e8f0 100%); border-radius: 12px; padding: 1.5em; margin-bottom: 1.5em; }
      .client-profile-header { display: flex; align-items: center; gap: 1em; margin-bottom: 1.25em; flex-wrap: wrap; }
      .client-avatar { width: 56px; height: 56px; border-radius: 50%; background: linear-gradient(135deg, #3D5FA3, #7DCDEB); display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
      .client-avatar i { color: white; font-size: 24px; }
      .client-name { font-size: 22px; font-weight: 600; color: #1e293b; margin: 0; line-height: 1.2; }
      .client-cpf  { font-size: 13px; color: #64748b; margin: 0.15em 0 0 0; }
      .client-info-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1em; }
      .client-info-card { background: white; border-radius: 8px; padding: 1em 1.25em; box-shadow: 0 1px 4px rgba(0,0,0,0.06); }
      .client-info-label { font-size: 11px; font-weight: 700; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.06em; margin-bottom: 0.5em; display: flex; align-items: center; gap: 0.4em; }
      .client-info-value { font-size: 15px; color: #1e293b; font-weight: 500; display: flex; flex-direction: column; gap: 0.3em; }
      .client-info-value a { color: #4A7AC2; text-decoration: none; }
      .client-info-value a:hover { text-decoration: underline; }
      .client-policies-title { font-size: 18px; font-weight: 600; color: #504f4f; margin: 1.5em 0 0.75em; display: flex; align-items: center; gap: 0.5em; }
      .policy-cards-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 1em; }
      .policy-card-item { background: white; border: 1px solid #e2e8f0; border-radius: 10px; padding: 1.25em; cursor: pointer; transition: all 0.2s; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
      .policy-card-item:hover { border-color: #4A7AC2; box-shadow: 0 4px 12px rgba(74,122,194,0.15); transform: translateY(-1px); }
      .policy-card-top { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 0.75em; }
      .policy-card-insurer { font-size: 13px; font-weight: 600; color: #4A7AC2; }
      .policy-card-detail { font-size: 13px; color: #64748b; margin-top: 0.25em; }
      .policy-card-dates { font-size: 13px; color: #64748b; display: flex; flex-direction: column; gap: 0.2em; margin-top: 0.5em; }
      .policy-card-dates span { display: flex; align-items: center; gap: 0.4em; }
      .days-badge { padding: 3px 10px; border-radius: 20px; font-size: 12px; font-weight: 600; display: inline-block; }
      .days-badge.expired  { background: #fee2e2; color: #991b1b; }
      .days-badge.soon     { background: #fef3c7; color: #92400e; }
      .days-badge.ok       { background: #d1fae5; color: #065f46; }

      @media (max-width: 640px) {
        .policy-cards-grid { grid-template-columns: 1fr; }
        .client-info-grid  { grid-template-columns: 1fr; }
        .client-name { font-size: 18px; }
      }

      /* ===== MOBILE RESPONSIVE ===== */
      @media (max-width: 768px) {
        /* Main content */
        .main-content-pad { padding: 0.75em !important; }

        /* Tabs: horizontal scroll, no wrap */
        .tab-nav-scroll {
          overflow-x: auto;
          -webkit-overflow-scrolling: touch;
          scrollbar-width: none;
          flex-wrap: nowrap !important;
          padding-bottom: 2px;
        }
        .tab-nav-scroll::-webkit-scrollbar { display: none; }
        .tab-button {
          white-space: nowrap;
          padding: 0.65em 0.9em !important;
          font-size: 13px !important;
        }

        /* Table containers */
        .table-container { padding: 1em !important; margin: 0.5em 0 !important; }
        .table-container h2 { font-size: 20px !important; margin-bottom: 0.75em !important; }
        .table-container h3 { font-size: 16px !important; }

        /* Policy details cards */
        .details-grid { grid-template-columns: 1fr !important; }

        /* Form grids — override inline styles with !important */
        .form-grid-2 { grid-template-columns: 1fr !important; }
        .form-grid-span-2 { grid-column: span 1 !important; }

        /* Search form row */
        .search-row { flex-direction: column !important; }
        .search-row .btn-primary { width: 100%; justify-content: center; }

        /* Insurer add form */
        .insurer-form-row { flex-direction: column !important; align-items: stretch !important; }
        .insurer-form-row .btn-primary { width: 100%; justify-content: center; height: auto !important; padding: 12px !important; }

        /* Action button groups in details */
        .action-group { flex-direction: column !important; align-items: stretch !important; }
        .action-group a, .action-group button { width: 100%; justify-content: center; }

        /* Policy details header */
        .details-header { flex-direction: column !important; align-items: stretch !important; }
        .details-header button { width: 100%; justify-content: center; }
      }

      /* Show mobile sort bar, hide sort icons in card headers (headers are hidden) */
      @media (max-width: 640px) {
        .mobile-sort-bar { display: flex; }
      }

      /* Responsive tables → card layout on small screens */
      @media (max-width: 640px) {
        .responsive-table,
        .responsive-table tbody,
        .responsive-table tr,
        .responsive-table td { display: block !important; }

        .responsive-table thead { display: none !important; }

        .responsive-table tr {
          border: 1px solid #e2e8f0 !important;
          border-radius: 10px !important;
          margin-bottom: 0.75em !important;
          padding: 0.5em 0.75em !important;
          box-shadow: 0 1px 4px rgba(0,0,0,0.07) !important;
          background: white !important;
        }
        .responsive-table tr:hover { background-color: #f0f9ff !important; }
        .responsive-table tr.hover-row:hover td:first-child { border-left: none !important; }

        .responsive-table td {
          display: flex !important;
          align-items: center !important;
          justify-content: space-between !important;
          border: none !important;
          border-bottom: 1px solid #f1f5f9 !important;
          padding: 0.45em 0.25em !important;
          font-size: 14px !important;
          gap: 0.5em;
          min-height: 36px;
        }
        .responsive-table td:last-child { border-bottom: none !important; }

        .responsive-table td[data-label]::before {
          content: attr(data-label);
          font-size: 11px !important;
          font-weight: 700 !important;
          color: #94a3b8 !important;
          text-transform: uppercase !important;
          letter-spacing: 0.06em !important;
          white-space: nowrap;
          flex-shrink: 0;
          min-width: 75px;
        }

        .responsive-table td.td-action {
          justify-content: flex-end !important;
          padding-top: 0.6em !important;
          gap: 0.5em;
          flex-wrap: wrap;
          border-bottom: none !important;
        }
        .responsive-table td.td-action::before { display: none !important; }
      }
    </style>

    <div class="control-panel-body min-h-screen bg-gray-50">
      <.navbar />
      <.hero title="Painel de Controle" subtitle="Gerenciamento de Apólices" />

      <!-- Main Content -->
      <div class="main-content main-content-pad" style="max-width: 1400px; margin: 0 auto; padding: 3em 2em;">
        <!-- Tabs -->
        <div class="bg-white rounded-lg shadow-md mb-6 p-4" style="overflow: hidden;">
          <nav class="tab-nav-scroll flex gap-1" style="align-items: center;">

            <%# ── Grupo 1: Urgência ── %>
            <button
              phx-click="switch_tab" phx-value-tab="due"
              class={"tab-button #{if @active_tab == "due", do: "active", else: ""}"}
            >
              <i class="fas fa-bell"></i> A Vencer
            </button>

            <span class="tab-divider"></span>

            <%# ── Grupo 2: Consulta ── %>
            <button
              phx-click="switch_tab" phx-value-tab="clients"
              class={"tab-button #{if @active_tab == "clients", do: "active", else: ""}"}
            >
              <i class="fas fa-user-circle"></i> Clientes
            </button>

            <span class="tab-divider"></span>

            <button
              phx-click="switch_tab" phx-value-tab="all"
              class={"tab-button #{if @active_tab == "all", do: "active", else: ""}"}
            >
              <i class="fas fa-list"></i> Apólices
            </button>

            <span class="tab-divider"></span>

            <%# ── Grupo 3: Gestão ── %>
            <button
              phx-click="switch_tab" phx-value-tab="register"
              class={"tab-button #{if @active_tab == "register", do: "active", else: ""}"}
            >
              <i class="fas fa-plus-circle"></i> Nova Apólice
            </button>

            <%# ── Configurações (direita) ── %>
            <button
              phx-click="switch_tab" phx-value-tab="insurers"
              class={"tab-settings-btn #{if @active_tab == "insurers", do: "active", else: ""}"}
              title="Configurar seguradoras"
            >
              <i class="fas fa-cog"></i>
            </button>

          </nav>
        </div>

        <%= if @selected_policy do %>
          <!-- Policy Details View -->
          <div class="table-container">
            <div class="details-header" style="margin-bottom: 1.5em; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 1em;">
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

            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">
              <%= if @editing_policy, do: "Editar Apólice", else: "Detalhes da Apólice" %>
            </h2>

            <%= if @editing_policy do %>
              <!-- Edit Form -->
              <form phx-submit="save_policy" phx-change="update_edit_form">
                <div class="form-grid-2" style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1.5em; margin-bottom: 2em;">
                  <!-- Customer Info Card -->
                  <div style="background: linear-gradient(135deg, #f8fafc 0%, #e2e8f0 100%); border-radius: 12px; padding: 1.5em; box-shadow: 0 2px 8px rgba(0,0,0,0.05);">
                    <h3 style="color: #4A7AC2; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
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
                    <h3 style="color: #4A7AC2; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
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
                        <label style="font-size: 13px; color: #64748b; display: block; margin-bottom: 0.25em;">Tipo de Seguro</label>
                        <select
                          name="edit_form[insurance_type_id]"
                          class="form-input"
                        >
                          <option value="">Selecione um tipo</option>
                          <%= for type <- @insurance_types do %>
                            <option value={type.id} selected={@edit_form["insurance_type_id"] == to_string(type.id)}>
                              <%= type.name %>
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
                    <h3 style="color: #059669; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
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
                <div class="action-group" style="display: flex; gap: 1em; flex-wrap: wrap; justify-content: flex-end;">
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
              <div class="details-grid" style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 1.5em;">
                <!-- Customer Info Card -->
                <div style="background: linear-gradient(135deg, #f8fafc 0%, #e2e8f0 100%); border-radius: 12px; padding: 1.5em; box-shadow: 0 2px 8px rgba(0,0,0,0.05);">
                  <h3 style="color: #4A7AC2; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
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
                  <h3 style="color: #4A7AC2; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
                    <i class="fas fa-file-contract"></i> Dados da Apólice
                  </h3>
                  <div style="display: flex; flex-direction: column; gap: 0.75em;">
                    <div>
                      <span style="font-size: 13px; color: #64748b; display: block;">Seguradora</span>
                      <span style="font-size: 16px; color: #1e293b; font-weight: 500;"><%= @selected_policy.insurer || "Não informada" %></span>
                    </div>
                    <div>
                      <span style="font-size: 13px; color: #64748b; display: block;">Tipo de Seguro</span>
                      <span style="font-size: 16px; color: #1e293b; font-weight: 500;"><%= @selected_policy[:insurance_type] || "Não informado" %></span>
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
                  <h3 style="color: #059669; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 18px; margin-bottom: 1em; display: flex; align-items: center; gap: 0.5em;">
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
                      <span style={days_remaining_badge_style(days)}>
                        <%= if days <= 0, do: "Vencida", else: "#{days} dias" %>
                      </span>
                    </div>
                  </div>
                </div>
              </div>

              <!-- Actions -->
              <div class="action-group" style="margin-top: 2em; display: flex; gap: 1em; flex-wrap: wrap; justify-content: space-between; align-items: center;">
                <div class="action-group" style="display: flex; gap: 1em; flex-wrap: wrap;">
                  <a
                    href={"/policies/#{@selected_policy.id}/pdf"}
                    class="btn-primary"
                    style="padding: 12px 24px; font-size: 15px; display: inline-flex; align-items: center; gap: 0.5em;"
                  >
                    <i class="fas fa-file-pdf"></i> Baixar PDF
                  </a>
                  <%= if @segfy_enabled do %>
                    <button
                      type="button"
                      phx-click="segfy_calcular_renovacao"
                      disabled={@segfy_renewal_loading}
                      class="btn-primary"
                      style="padding: 12px 24px; font-size: 15px; display: inline-flex; align-items: center; gap: 0.5em; background: linear-gradient(135deg, #0f766e 0%, #0d9488 100%); border: none;"
                      title="Prosseguir no Gestão, calcula renovação + novas seguradoras e devolve o link do multicálculo (app.segfy.com)"
                    >
                      <%= if @segfy_renewal_loading do %>
                        <i class="fas fa-spinner fa-spin"></i> Calculando na Segfy…
                      <% else %>
                        <i class="fas fa-sync-alt"></i> Gerar cotação Segfy (link)
                      <% end %>
                    </button>
                  <% end %>
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

              <%= if @segfy_premiums_preview do %>
                <% ren = Map.get(@segfy_premiums_preview, :renovation, []) %>
                <% newq = Map.get(@segfy_premiums_preview, :new_quotation, []) %>
                <div style="margin-top: 1.75em;">
                  <h3 style="color: #0f766e; font-size: 18px; margin: 0 0 1em 0; display: flex; align-items: center; gap: 0.5em;">
                    <i class="fas fa-chart-line"></i> Cotações
                  </h3>
                  <%= if ren == [] and newq == [] do %>
                    <p style="font-size: 14px; color: #64748b; margin: 0;">
                      Nenhum resultado recebido das seguradoras.
                    </p>
                  <% end %>
                  <%= if ren != [] do %>
                    <h4 style="margin: 0 0 0.75em 0; font-size: 14px; color: #64748b; font-weight: 500; text-transform: uppercase; letter-spacing: 0.05em;">Renovação</h4>
                    <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; margin-bottom: 1.5em;">
                      <%= for row <- ren do %>
                        <% has_premium = is_number(row["premium"]) and row["premium"] > 0 %>
                        <div style={"padding: 16px; border-radius: 10px; border: 1px solid #{if has_premium, do: "#99f6e4", else: "#fecaca"}; background: #{if has_premium, do: "linear-gradient(135deg, #f0fdfa 0%, #ccfbf1 100%)", else: "#fef2f2"};"}>
                          <div style="font-size: 13px; color: #64748b; margin-bottom: 4px;"><%= segfy_display_company(row) %></div>
                          <%= if has_premium do %>
                            <div style="font-size: 22px; font-weight: 700; color: #0f766e;"><%= segfy_display_money(row["premium"]) %></div>
                            <div style="font-size: 12px; color: #64748b; margin-top: 6px;">
                              Franquia: <strong><%= segfy_display_money(row["franchise"]) %></strong>
                            </div>
                          <% else %>
                            <div style="font-size: 14px; color: #dc2626;">Sem cotação</div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                  <%= if newq != [] do %>
                    <h4 style="margin: 0 0 0.75em 0; font-size: 14px; color: #64748b; font-weight: 500; text-transform: uppercase; letter-spacing: 0.05em;">Novo orçamento</h4>
                    <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px;">
                      <%= for row <- newq do %>
                        <% has_premium = is_number(row["premium"]) and row["premium"] > 0 %>
                        <div style={"padding: 16px; border-radius: 10px; border: 1px solid #{if has_premium, do: "#99f6e4", else: "#fecaca"}; background: #{if has_premium, do: "linear-gradient(135deg, #f0fdfa 0%, #ccfbf1 100%)", else: "#fef2f2"};"}>
                          <div style="font-size: 13px; color: #64748b; margin-bottom: 4px;"><%= segfy_display_company(row) %></div>
                          <%= if has_premium do %>
                            <div style="font-size: 22px; font-weight: 700; color: #0f766e;"><%= segfy_display_money(row["premium"]) %></div>
                            <div style="font-size: 12px; color: #64748b; margin-top: 6px;">
                              Franquia: <strong><%= segfy_display_money(row["franchise"]) %></strong>
                            </div>
                          <% else %>
                            <div style="font-size: 14px; color: #dc2626;">Sem cotação</div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>
        <% else %>

        <%= if @active_tab == "due" do %>
          <div class="table-container">
            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Apólices com vencimento nos próximos 30 dias</h2>
            <!-- Mobile sort bar -->
            <div class="mobile-sort-bar">
              <span class="mobile-sort-bar-label">Ordenar</span>
              <form phx-change="sort_by" style="flex: 0 1 auto;">
                <select class="form-input" name="by">
                  <option value="end_date" selected={@sort_by == "end_date"}>Vencimento</option>
                  <option value="customer_name" selected={@sort_by == "customer_name"}>Nome</option>
                  <option value="insurer" selected={@sort_by == "insurer"}>Seguradora</option>
                  <option value="insurance_type" selected={@sort_by == "insurance_type"}>Tipo</option>
                  <option value="calculated" selected={@sort_by == "calculated"}>Calculado</option>
                  <option value="start_date" selected={@sort_by == "start_date"}>Início</option>
                </select>
              </form>
              <button class="sort-dir-btn" phx-click="sort" phx-value-by={@sort_by}>
                <%= if @sort_dir == "asc" do %>
                  <i class="fas fa-arrow-up"></i> Cresc.
                <% else %>
                  <i class="fas fa-arrow-down"></i> Decresc.
                <% end %>
              </button>
            </div>
            <div class="overflow-x-auto">
              <table class="responsive-table">
                <thead>
                  <tr>
                    <th class="sort-th">
                      <button class={sort_btn_class(@sort_by, "calculated")} phx-click="sort" phx-value-by="calculated">
                        Calculado? <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "calculated")}"}></i>
                      </button>
                    </th>
                    <th class="sort-th">
                      <button class={sort_btn_class(@sort_by, "end_date")} phx-click="sort" phx-value-by="end_date">
                        Dias Restantes <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "end_date")}"}></i>
                      </button>
                    </th>
                    <th class="sort-th">
                      <button class={sort_btn_class(@sort_by, "customer_name")} phx-click="sort" phx-value-by="customer_name">
                        Nome <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "customer_name")}"}></i>
                      </button>
                    </th>
                    <th class="sort-th">
                      <button class={sort_btn_class(@sort_by, "insurer")} phx-click="sort" phx-value-by="insurer">
                        Seguradora <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "insurer")}"}></i>
                      </button>
                    </th>
                    <th class="sort-th">
                      <button class={sort_btn_class(@sort_by, "insurance_type")} phx-click="sort" phx-value-by="insurance_type">
                        Tipo <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "insurance_type")}"}></i>
                      </button>
                    </th>
                    <th class="sort-th">
                      <button class={sort_btn_class(@sort_by, "detail")} phx-click="sort" phx-value-by="detail">
                        Informações Adicionais <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "detail")}"}></i>
                      </button>
                    </th>
                    <th class="sort-th">
                      <button class={sort_btn_class(@sort_by, "start_date")} phx-click="sort" phx-value-by="start_date">
                        Início <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "start_date")}"}></i>
                      </button>
                    </th>
                    <th class="sort-th">
                      <button class={sort_btn_class(@sort_by, "end_date")} phx-click="sort" phx-value-by="end_date">
                        Vencimento <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "end_date")}"}></i>
                      </button>
                    </th>
                    <th>Ação</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for policy <- sort_policies(@policies, @sort_by, @sort_dir) do %>
                    <tr id={"policy-due-#{policy.id}"} phx-click="view_policy" phx-value-id={policy.id} style="cursor: pointer;" class="hover-row">
                      <td data-label="Calculado?" phx-click="update_renewal" phx-value-id={policy.id} style="cursor: pointer;">
                        <input
                          type="checkbox"
                          checked={policy.calculated}
                          style="width: 20px; height: 20px; cursor: pointer; pointer-events: none;"
                        />
                      </td>
                      <td data-label="Dias">
                        <span style={"padding: 6px 12px; border-radius: 20px; font-size: 13px; font-weight: 600; #{if calculate_days(policy.end_date) <= 7, do: "background-color: #fee2e2; color: #991b1b;", else: "background-color: #fef3c7; color: #92400e;"}"}>
                          <%= calculate_days(policy.end_date) %> dias
                        </span>
                      </td>
                      <td data-label="Nome" style="font-weight: 500;"><%= policy.customer_name %></td>
                      <td data-label="Seguradora"><%= policy.insurer %></td>
                      <td data-label="Tipo"><%= policy[:insurance_type] || "—" %></td>
                      <td data-label="Detalhe"><%= policy.detail %></td>
                      <td data-label="Início"><%= format_date(policy.start_date) %></td>
                      <td data-label="Vencimento"><%= format_date(policy.end_date) %></td>
                      <td class="td-action" phx-click="noop">
                        <a
                          href={"/policies/#{policy.id}/pdf"}
                          class="btn-primary"
                          style="padding: 8px 16px; font-size: 14px;"
                        >
                          <i class="fas fa-file-pdf"></i> Baixar
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

            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Buscar apólices vigentes</h2>

            <form phx-submit="query_current" style="margin-bottom: 2em;">
              <div style="max-width: 600px;">
                <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">
                  Digite parte ou o nome do cliente
                </label>
                <div class="search-row" style="display: flex; gap: 0.75em;">
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
              <!-- Mobile sort bar -->
              <div class="mobile-sort-bar">
                <span class="mobile-sort-bar-label">Ordenar</span>
                <form phx-change="sort_by" style="flex: 0 1 auto;">
                  <select class="form-input" name="by">
                    <option value="end_date" selected={@sort_by == "end_date"}>Vencimento</option>
                    <option value="customer_name" selected={@sort_by == "customer_name"}>Nome</option>
                    <option value="insurer" selected={@sort_by == "insurer"}>Seguradora</option>
                    <option value="insurance_type" selected={@sort_by == "insurance_type"}>Tipo</option>
                    <option value="start_date" selected={@sort_by == "start_date"}>Início</option>
                  </select>
                </form>
                <button class="sort-dir-btn" phx-click="sort" phx-value-by={@sort_by}>
                  <%= if @sort_dir == "asc" do %>
                    <i class="fas fa-arrow-up"></i> Cresc.
                  <% else %>
                    <i class="fas fa-arrow-down"></i> Decresc.
                  <% end %>
                </button>
              </div>
              <div class="overflow-x-auto">
                <table class="responsive-table">
                  <thead>
                    <tr>
                      <th class="sort-th">
                        <button class={sort_btn_class(@sort_by, "end_date")} phx-click="sort" phx-value-by="end_date">
                          Dias Restantes <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "end_date")}"}></i>
                        </button>
                      </th>
                      <th class="sort-th">
                        <button class={sort_btn_class(@sort_by, "customer_name")} phx-click="sort" phx-value-by="customer_name">
                          Nome <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "customer_name")}"}></i>
                        </button>
                      </th>
                      <th class="sort-th">
                        <button class={sort_btn_class(@sort_by, "insurer")} phx-click="sort" phx-value-by="insurer">
                          Seguradora <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "insurer")}"}></i>
                        </button>
                      </th>
                      <th class="sort-th">
                        <button class={sort_btn_class(@sort_by, "insurance_type")} phx-click="sort" phx-value-by="insurance_type">
                          Tipo <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "insurance_type")}"}></i>
                        </button>
                      </th>
                      <th class="sort-th">
                        <button class={sort_btn_class(@sort_by, "detail")} phx-click="sort" phx-value-by="detail">
                          Informações Adicionais <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "detail")}"}></i>
                        </button>
                      </th>
                      <th class="sort-th">
                        <button class={sort_btn_class(@sort_by, "start_date")} phx-click="sort" phx-value-by="start_date">
                          Início <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "start_date")}"}></i>
                        </button>
                      </th>
                      <th class="sort-th">
                        <button class={sort_btn_class(@sort_by, "end_date")} phx-click="sort" phx-value-by="end_date">
                          Vencimento <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "end_date")}"}></i>
                        </button>
                      </th>
                      <th>Ação</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for policy <- sort_policies(@query_current_result, @sort_by, @sort_dir) do %>
                      <tr id={"policy-current-#{policy.id}"} phx-click="view_policy" phx-value-id={policy.id} style="cursor: pointer;" class="hover-row">
                        <td data-label="Dias">
                          <span style="padding: 6px 12px; border-radius: 20px; font-size: 13px; font-weight: 600; background-color: #d1fae5; color: #065f46;">
                            <%= calculate_days(policy.end_date) %> dias
                          </span>
                        </td>
                        <td data-label="Nome" style="font-weight: 500;"><%= policy.customer_name %></td>
                        <td data-label="Seguradora"><%= policy.insurer %></td>
                        <td data-label="Tipo"><%= policy[:insurance_type] || "—" %></td>
                        <td data-label="Detalhe"><%= policy.detail %></td>
                        <td data-label="Início"><%= format_date(policy.start_date) %></td>
                        <td data-label="Vencimento"><%= format_date(policy.end_date) %></td>
                        <td class="td-action" phx-click="noop">
                          <a href={"/policies/#{policy.id}/pdf"} class="btn-primary" style="padding: 8px 16px; font-size: 14px;">
                            <i class="fas fa-file-pdf"></i> Baixar
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

            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Buscar apólices</h2>

            <form phx-submit="query_all" style="margin-bottom: 2em;">
              <div style="max-width: 600px;">
                <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">
                  Digite parte ou o nome do cliente
                </label>
                <div class="search-row" style="display: flex; gap: 0.75em;">
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
                <label style="display: inline-flex; align-items: center; gap: 0.5em; margin-top: 0.75em; cursor: pointer; font-size: 14px; font-weight: 400; color: #504f4f; user-select: none;">
                  <input type="checkbox" name="active_only" value="true" checked={@search_active_only} style="width: 16px; height: 16px; accent-color: #4A7AC2; cursor: pointer;" />
                  Apenas apólices vigentes
                </label>
              </div>
            </form>

            <%= if length(@query_result) > 0 do %>
              <!-- Mobile sort bar -->
              <div class="mobile-sort-bar">
                <span class="mobile-sort-bar-label">Ordenar</span>
                <form phx-change="sort_by" style="flex: 0 1 auto;">
                  <select class="form-input" name="by">
                    <option value="customer_name" selected={@sort_by == "customer_name"}>Nome</option>
                    <option value="insurer" selected={@sort_by == "insurer"}>Seguradora</option>
                    <option value="insurance_type" selected={@sort_by == "insurance_type"}>Tipo</option>
                    <option value="end_date" selected={@sort_by == "end_date"}>Vencimento</option>
                    <option value="start_date" selected={@sort_by == "start_date"}>Início</option>
                    <option value="detail" selected={@sort_by == "detail"}>Detalhe</option>
                  </select>
                </form>
                <button class="sort-dir-btn" phx-click="sort" phx-value-by={@sort_by}>
                  <%= if @sort_dir == "asc" do %>
                    <i class="fas fa-arrow-up"></i> Cresc.
                  <% else %>
                    <i class="fas fa-arrow-down"></i> Decresc.
                  <% end %>
                </button>
              </div>
              <div class="overflow-x-auto">
                <table class="responsive-table">
                  <thead>
                    <tr>
                      <th class="sort-th" style={sort_th_style(@sort_by, "customer_name")}>
                        <button class="sort-btn" phx-click="sort" phx-value-by="customer_name">
                          Nome <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "customer_name")}"}></i>
                        </button>
                      </th>
                      <th class="sort-th" style={sort_th_style(@sort_by, "insurer")}>
                        <button class="sort-btn" phx-click="sort" phx-value-by="insurer">
                          Seguradora <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "insurer")}"}></i>
                        </button>
                      </th>
                      <th class="sort-th" style={sort_th_style(@sort_by, "insurance_type")}>
                        <button class="sort-btn" phx-click="sort" phx-value-by="insurance_type">
                          Tipo <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "insurance_type")}"}></i>
                        </button>
                      </th>
                      <th class="sort-th" style={sort_th_style(@sort_by, "detail")}>
                        <button class="sort-btn" phx-click="sort" phx-value-by="detail">
                          Informações Adicionais <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "detail")}"}></i>
                        </button>
                      </th>
                      <th class="sort-th" style={sort_th_style(@sort_by, "start_date")}>
                        <button class="sort-btn" phx-click="sort" phx-value-by="start_date">
                          Início <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "start_date")}"}></i>
                        </button>
                      </th>
                      <th class="sort-th" style={sort_th_style(@sort_by, "end_date")}>
                        <button class="sort-btn" phx-click="sort" phx-value-by="end_date">
                          Vencimento <i class={"sort-icon #{sort_icon(@sort_by, @sort_dir, "end_date")}"}></i>
                        </button>
                      </th>
                      <th>Ações</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for policy <- sort_policies(@query_result, @sort_by, @sort_dir) do %>
                      <tr id={"policy-all-#{policy.id}"} phx-click="view_policy" phx-value-id={policy.id} style="cursor: pointer;" class="hover-row">
                        <td data-label="Nome" style="font-weight: 500;"><%= policy.customer_name %></td>
                        <td data-label="Seguradora"><%= policy.insurer %></td>
                        <td data-label="Tipo"><%= policy[:insurance_type] || "—" %></td>
                        <td data-label="Detalhe"><%= policy.detail %></td>
                        <td data-label="Início"><%= format_date(policy.start_date) %></td>
                        <td data-label="Vencimento"><%= format_date(policy.end_date) %></td>
                        <td class="td-action" phx-click="noop" phx-value-stop="true">
                          <a href={"/policies/#{policy.id}/pdf"} class="btn-primary" style="padding: 8px 16px; font-size: 14px;">
                            <i class="fas fa-file-pdf"></i> Baixar
                          </a>
                          <button
                            phx-click="delete_policy"
                            phx-value-id={policy.id}
                            class="btn-danger"
                            data-confirm="Tem certeza que deseja excluir esta apólice? Esta ação não pode ser desfeita."
                          >
                            <i class="fas fa-trash-alt"></i> Excluir
                          </button>
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

            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Nova apólice</h2>

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
                <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Arquivo PDF</label>
                <div style="position: relative; width: 100%; min-width: 0;" id="file-upload-container">
                  <%= if Map.get(assigns, :ocr_file_name) && !@processing_ocr do %>
                    <div style="padding: 12px; background-color: #f9fafb; border: 2px solid #4A7AC2; border-radius: 8px; color: #059669; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 15px; display: flex; align-items: center; gap: 0.5em;">
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
                    <p class="text-base text-red-700"><%= error_to_string(err) %></p>
                  </div>
                <% end %>
                <%= if !Map.get(assigns, :ocr_file_name) && !@processing_ocr do %>
                  <p style="margin-top: 0.75em; font-size: 14px; color: #64748b; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">
                    <i class="fas fa-info-circle" style="margin-right: 0.25em;"></i>
                    Selecione um arquivo PDF para carregar automaticamente os dados da apólice.
                  </p>
                <% end %>
              </div>

              <!-- Campos do formulário - só aparecem após PDF ser carregado -->
              <%= if Map.get(assigns, :ocr_file_name) && !@processing_ocr do %>
              <div class="form-grid-2" style="display: grid; grid-template-columns: repeat(2, 1fr); gap: 1.5em; margin-bottom: 1.5em;">
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

                <div style="min-width: 0;">
                  <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">Tipo de Seguro</label>
                  <select
                    name="insert_form[insurance_type_id]"
                    class="form-input"
                  >
                    <option value="">Selecione um tipo</option>
                    <%= for type <- @insurance_types do %>
                      <option value={type.id} selected={@insert_form["insurance_type_id"] == to_string(type.id)}>
                        <%= type.name %>
                      </option>
                    <% end %>
                  </select>
                </div>

                <div class="form-grid-span-2" style="grid-column: span 2;">
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

                <div class="form-grid-span-2" style="grid-column: span 2;">
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
                          <h2 style="color: #4A7AC2; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 24px; margin-bottom: 1em; font-weight: 600;">
                            Processando documento...
                          </h2>
                          <div style="color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-size: 16px; min-height: 30px; display: flex; align-items: center; justify-content: center; position: relative;">
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
                        <span style="font-size: 14px; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Enviando arquivo...</span>
                        <span style="font-size: 14px; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif; font-weight: 500;"><%= entry.progress %>%</span>
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

            <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Configurar Seguradoras</h2>

            <!-- Create New Insurer -->
            <div style="margin-bottom: 3em; padding: 2em; background-color: #f9fafb; border-radius: 8px;">
              <h3 style="font-size: 20px; font-weight: 500; margin-bottom: 1em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Adicionar Nova Seguradora</h3>
              <form phx-submit="create_insurer" phx-change="update_insurer_name" class="insurer-form-row" style="display: flex; gap: 0.75em; align-items: flex-end;">
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
              <h3 style="font-size: 20px; font-weight: 500; margin-bottom: 1em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Seguradoras Cadastradas</h3>
              <%= if length(@insurers) > 0 do %>
                <div class="overflow-x-auto">
                  <table class="responsive-table">
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
                          <td data-label="ID" style="font-weight: 500;"><%= insurer.id %></td>
                          <td data-label="Nome" style="font-weight: 500;"><%= insurer.name %></td>
                          <td class="td-action">
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
                <p style="text-align: center; color: #666; padding: 2em; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Nenhuma seguradora cadastrada ainda.</p>
              <% end %>
            </div>

            <!-- Insurance Types Management -->
            <div style="margin-top: 3em; border-top: 2px solid #e2e8f0; padding-top: 2em;">
              <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 1.5em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Configurar Tipos de Seguro</h2>

              <!-- Create New Insurance Type -->
              <div style="margin-bottom: 3em; padding: 2em; background-color: #f9fafb; border-radius: 8px;">
                <h3 style="font-size: 20px; font-weight: 500; margin-bottom: 1em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Adicionar Novo Tipo de Seguro</h3>
                <form phx-submit="create_insurance_type" phx-change="update_insurance_type_name" class="insurer-form-row" style="display: flex; gap: 0.75em; align-items: flex-end;">
                  <div style="flex: 1;">
                    <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">
                      Nome do Tipo
                    </label>
                    <input
                      type="text"
                      name="name"
                      value={@new_insurance_type_name}
                      class="form-input"
                      placeholder="Digite o nome do tipo de seguro..."
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

              <!-- List of Insurance Types -->
              <div>
                <h3 style="font-size: 20px; font-weight: 500; margin-bottom: 1em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Tipos de Seguro Cadastrados</h3>
                <%= if length(@insurance_types) > 0 do %>
                  <div class="overflow-x-auto">
                    <table class="responsive-table">
                      <thead>
                        <tr>
                          <th>ID</th>
                          <th>Nome</th>
                          <th>Ações</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for type <- @insurance_types do %>
                          <tr id={"insurance-type-row-#{type.id}"}>
                            <td data-label="ID" style="font-weight: 500;"><%= type.id %></td>
                            <td data-label="Nome" style="font-weight: 500;"><%= type.name %></td>
                            <td class="td-action">
                              <button
                                phx-click="delete_insurance_type"
                                phx-value-id={type.id}
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
                  <p style="text-align: center; color: #666; padding: 2em; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Nenhum tipo de seguro cadastrado ainda.</p>
                <% end %>
              </div>
            </div>

          </div>
        <% end %>

        <%= if @active_tab == "clients" do %>
          <div class="table-container">
            <%= if @selected_client do %>
              <%# ── Client detail view ── %>
              <div class="details-header" style="margin-bottom: 1.5em; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 1em;">
                <button phx-click="close_client" class="btn-secondary" style="display: inline-flex; align-items: center; gap: 0.5em; padding: 10px 20px; font-size: 15px;">
                  <i class="fas fa-arrow-left"></i> Voltar
                </button>
              </div>

              <div class="client-profile">
                <div class="client-profile-header">
                  <div class="client-avatar"><i class="fas fa-user"></i></div>
                  <div>
                    <p class="client-name"><%= @selected_client.name %></p>
                    <%= if @selected_client.cpf_cnpj do %>
                      <p class="client-cpf"><i class="fas fa-id-card" style="margin-right: 0.3em;"></i><%= @selected_client.cpf_cnpj %></p>
                    <% end %>
                  </div>
                  <div style="margin-left: auto; background: linear-gradient(90deg,#3D5FA3,#7DCDEB); color: white; border-radius: 20px; padding: 6px 16px; font-size: 13px; font-weight: 600; white-space: nowrap; flex-shrink: 0;">
                    <%= length(@selected_client.policies) %> apólice<%= if length(@selected_client.policies) != 1, do: "s", else: "" %>
                  </div>
                </div>

                <div class="client-info-grid">
                  <%= if @selected_client.phones != [] do %>
                    <div class="client-info-card">
                      <div class="client-info-label"><i class="fas fa-phone"></i> Telefone<%= if length(@selected_client.phones) > 1, do: "s", else: "" %></div>
                      <div class="client-info-value">
                        <%= for phone <- @selected_client.phones do %>
                          <a href={"https://wa.me/+55#{String.replace(phone, ~r/\D/, "")}"} target="_blank">
                            <i class="fab fa-whatsapp" style="color: #25D366; margin-right: 0.3em;"></i><%= phone %>
                          </a>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                  <%= if @selected_client.emails != [] do %>
                    <div class="client-info-card">
                      <div class="client-info-label"><i class="fas fa-envelope"></i> E-mail<%= if length(@selected_client.emails) > 1, do: "s", else: "" %></div>
                      <div class="client-info-value">
                        <%= for email <- @selected_client.emails do %>
                          <a href={"mailto:#{email}"}><i class="fas fa-envelope" style="margin-right: 0.3em; color: #4A7AC2;"></i><%= email %></a>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

              <div class="client-policies-title">
                <i class="fas fa-file-contract" style="color: #4A7AC2;"></i> Apólices
              </div>
              <div class="overflow-x-auto">
                <table class="responsive-table">
                  <thead>
                    <tr>
                      <th>Seguradora</th>
                      <th>Tipo</th>
                      <th>Detalhe</th>
                      <th>Início</th>
                      <th>Vencimento</th>
                      <th>Dias</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for policy <- @selected_client.policies do %>
                      <% days = calculate_days(policy.end_date) %>
                      <tr class="hover-row" phx-click="view_policy" phx-value-id={policy.id} style="cursor: pointer;">
                        <td data-label="Seguradora" style="font-weight: 500;"><%= policy.insurer || "—" %></td>
                        <td data-label="Tipo"><%= policy[:insurance_type] || "—" %></td>
                        <td data-label="Detalhe"><%= policy.detail || "—" %></td>
                        <td data-label="Início"><%= format_date(policy.start_date) %></td>
                        <td data-label="Vencimento"><%= format_date(policy.end_date) %></td>
                        <td data-label="Dias" class="td-action">
                          <span class={days_table_badge_class(days)}>
                            <%= if days <= 0, do: "Vencida", else: "#{days}d" %>
                          </span>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>

            <% else %>
              <%# ── Search form + results table ── %>
              <h2 style="font-size: 28px; font-weight: 500; margin-bottom: 0.25em; color: #504f4f; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;">Busca de Clientes</h2>
              <p style="font-size: 14px; color: #94a3b8; margin-bottom: 1.5em;">Busque pelo nome para ver todas as apólices e dados do cliente.</p>

              <form phx-submit="search_client" phx-change="update_client_query" style="margin-bottom: 1.5em;">
                <div style="max-width: 480px;">
                  <label style="display: block; font-size: 15px; font-weight: 500; margin-bottom: 0.5em; color: #504f4f;">Nome do cliente</label>
                  <div class="search-row" style="display: flex; gap: 0.75em;">
                    <input
                      type="text"
                      name="name"
                      value={@client_query}
                      class="form-input"
                      placeholder="Digite parte do nome..."
                      autocomplete="off"
                    />
                    <button type="submit" class="btn-primary">
                      <i class="fas fa-search"></i> <span>Buscar</span>
                    </button>
                  </div>
                </div>
              </form>

              <%= if is_nil(@client_results) do %>
                <div style="text-align: center; padding: 3em 1em; color: #94a3b8;">
                  <i class="fas fa-users" style="font-size: 48px; margin-bottom: 0.75em; display: block;"></i>
                  <p style="font-size: 16px; margin: 0;">Digite um nome para buscar o cliente.</p>
                </div>
              <% else %>
                <%= if @client_results == [] do %>
                  <div style="text-align: center; padding: 3em 1em; color: #94a3b8;">
                    <i class="fas fa-user-slash" style="font-size: 48px; margin-bottom: 0.75em; display: block;"></i>
                    <p style="font-size: 16px; margin: 0;">Nenhum cliente encontrado.</p>
                  </div>
                <% else %>
                  <p style="font-size: 13px; color: #94a3b8; margin-bottom: 0.75em;">
                    <%= length(@client_results) %> cliente<%= if length(@client_results) != 1, do: "s encontrados", else: " encontrado" %>
                  </p>
                  <div class="overflow-x-auto">
                    <table class="responsive-table">
                      <thead>
                        <tr>
                          <th>Nome</th>
                          <th>CPF / CNPJ</th>
                          <th>Telefone(s)</th>
                          <th>E-mail(s)</th>
                          <th>Apólices</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for {client, idx} <- Enum.with_index(@client_results) do %>
                          <tr class="hover-row" phx-click="view_client" phx-value-index={idx} style="cursor: pointer;">
                            <td data-label="Nome" style="font-weight: 600; color: #1e293b;"><%= client.name %></td>
                            <td data-label="CPF/CNPJ" style="font-size: 13px; color: #64748b;"><%= client.cpf_cnpj || "—" %></td>
                            <td data-label="Telefone">
                              <%= for {phone, i} <- Enum.with_index(client.phones) do %>
                                <%= if i < 2 do %>
                                  <a href={"https://wa.me/+55#{String.replace(phone, ~r/\D/, "")}"} target="_blank" style="display: block; color: #4A7AC2; text-decoration: none; font-size: 13px; white-space: nowrap;" phx-click="noop">
                                    <i class="fab fa-whatsapp" style="color: #25D366; margin-right: 0.2em;"></i><%= phone %>
                                  </a>
                                <% end %>
                              <% end %>
                              <%= if length(client.phones) > 2 do %>
                                <span style="font-size: 12px; color: #94a3b8;">+<%= length(client.phones) - 2 %> mais</span>
                              <% end %>
                            </td>
                            <td data-label="E-mail">
                              <%= for {email, i} <- Enum.with_index(client.emails) do %>
                                <%= if i < 2 do %>
                                  <a href={"mailto:#{email}"} style="display: block; color: #4A7AC2; text-decoration: none; font-size: 13px;" phx-click="noop">
                                    <%= email %>
                                  </a>
                                <% end %>
                              <% end %>
                              <%= if length(client.emails) > 2 do %>
                                <span style="font-size: 12px; color: #94a3b8;">+<%= length(client.emails) - 2 %> mais</span>
                              <% end %>
                            </td>
                            <td data-label="Apólices" class="td-action">
                              <span style="background: linear-gradient(90deg,#3D5FA3,#7DCDEB); color: white; border-radius: 20px; padding: 4px 12px; font-size: 13px; font-weight: 600; white-space: nowrap;">
                                <%= length(client.policies) %>
                              </span>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              <% end %>
            <% end %>
          </div>
        <% end %>

        <% end %> <!-- End of else for selected_policy -->
      </div>

    </div>
    """
  end
end
