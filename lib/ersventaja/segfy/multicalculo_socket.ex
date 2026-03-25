defmodule Ersventaja.Segfy.MulticalculoSocket do
  @moduledoc """
  Coleta eventos Socket.IO (Engine.IO v4) no endpoint usado pelo HFy (`STEP` / `RESULT`),
  usando o mesmo UUID de `config.callback` como `roomId` na conexão.

  Os prêmios por seguradora observados no front normalmente vêm nestes eventos, não no body
  do `POST …/vehicle/version/1.0/calculate`.
  """

  require Logger

  alias Ersventaja.Segfy
  alias Ersventaja.Segfy.{Client, MulticalculoSocket.Connection}

  @default_join_timeout_ms 15_000
  # RESULT costuma chegar alguns segundos após o último STEP; 12s fechava cedo demais.
  @default_idle_ms 35_000
  @default_drain_timeout_ms 95_000
  @default_hard_timeout_ms 120_000

  @doc """
  Conecta ao Socket.IO, entra na sala `room_id`, executa `calculate_fun/0` e agrega eventos
  até idle (após HTTP OK) ou timeout.

  Retorna `{calc_result, events}` — `events` é sempre uma lista (vazia se o WS falhar).
  """
  def collect_during_calculate(room_id, calculate_fun, opts \\ [])
      when is_binary(room_id) and is_function(calculate_fun, 0) do
    if Segfy.multicalculo_socket_enabled?() do
      do_collect(room_id, calculate_fun, opts)
    else
      {calculate_fun.(), []}
    end
  end

  defp do_collect(room_id, calculate_fun, opts) do
    join_timeout = Keyword.get(opts, :join_timeout_ms, @default_join_timeout_ms)
    idle_ms = Keyword.get(opts, :idle_ms, @default_idle_ms)
    drain_timeout = Keyword.get(opts, :drain_timeout_ms, @default_drain_timeout_ms)
    hard_timeout_ms = Keyword.get(opts, :hard_timeout_ms, @default_hard_timeout_ms)

    parent = self()
    sock_ref = make_ref()

    state = %{
      parent: parent,
      sock_ref: sock_ref,
      room_id: room_id,
      results: [],
      closed: false,
      join_sent: false,
      idle_ms: idle_ms,
      hard_timeout_ms: hard_timeout_ms,
      idle_timer_ref: nil,
      hard_timer_ref: nil,
      phase: :handshake,
      drain: false
    }

    url = Segfy.socket_io_websocket_url()
    origin = Segfy.socket_io_origin()

    headers = [
      {"Origin", origin},
      {"User-Agent", Client.user_agent()}
    ]

    case WebSockex.start(url, Connection, state, extra_headers: headers) do
      {:ok, pid} ->
        receive do
          {:segfy_ws, ^sock_ref, :joined} ->
            calc = calculate_fun.()
            ok = calculate_http_ok?(calc)
            WebSockex.cast(pid, {:calculate_done, ok})

            receive do
              {:segfy_ws, ^sock_ref, {:done, events}} ->
                {calc, normalize_events(events)}

              {:segfy_ws, ^sock_ref, {:error, reason}} ->
                Logger.warning(
                  "[Segfy MulticalculoSocket] disconnect durante drain: #{inspect(reason)}"
                )

                {calc, normalize_events([])}
            after
              drain_timeout ->
                _ = Process.exit(pid, :kill)

                Logger.warning(
                  "[Segfy MulticalculoSocket] drain timeout (#{drain_timeout}ms) room=#{short_id(room_id)}"
                )

                {calc, []}
            end

          {:segfy_ws, ^sock_ref, {:error, reason}} ->
            _ = Process.exit(pid, :kill)

            Logger.warning("[Segfy MulticalculoSocket] erro antes do join: #{inspect(reason)}")

            run_calculate_only(calculate_fun)
        after
          join_timeout ->
            _ = Process.exit(pid, :kill)

            Logger.warning(
              "[Segfy MulticalculoSocket] join timeout (#{join_timeout}ms) room=#{short_id(room_id)}"
            )

            run_calculate_only(calculate_fun)
        end

      {:error, reason} ->
        Logger.warning("[Segfy MulticalculoSocket] start falhou: #{inspect(reason)}")
        run_calculate_only(calculate_fun)
    end
  end

  defp run_calculate_only(fun), do: {fun.(), []}

  defp short_id(<<a::binary-size(8), _::binary>>), do: a <> "…"
  defp short_id(other), do: inspect(other)

  defp calculate_http_ok?({:ok, resp}) when is_map(resp) do
    status = resp["status"] || resp[:status] || resp["Status"]
    normalized = normalize_status_value(status)
    normalized == "OK"
  end

  defp calculate_http_ok?(_), do: false

  defp normalize_status_value(s) when is_binary(s), do: s |> String.trim() |> String.upcase()

  defp normalize_status_value(s) when is_atom(s),
    do: s |> Atom.to_string() |> normalize_status_value()

  defp normalize_status_value(_), do: ""

  defp normalize_events(events) when is_list(events) do
    out = Enum.map(events, &normalize_event/1)
    maybe_log_all_results_zero_premium(out)
    out
  end

  defp normalize_events(_), do: []

  defp maybe_log_all_results_zero_premium(list) when is_list(list) do
    results = Enum.filter(list, &(Map.get(&1, "socket_action") == "RESULT"))

    if results != [] and
         Enum.all?(results, fn r ->
           case Map.get(r, "premium") do
             nil -> true
             n when n in [0, 0.0] -> true
             _ -> false
           end
         end) do
      keys =
        case List.first(results) do
          %{"raw" => m} when is_map(m) -> m |> Map.keys() |> Enum.sort()
          _ -> []
        end

      Logger.info(
        "[Segfy MulticalculoSocket] Todos os RESULT vieram com prêmio 0/nil — " <>
          "chaves em `data` (1º evento)=#{inspect(keys)}. " <>
          "O HFy no browser pode ainda mostrar valores (sessão diferente ou outro payload)."
      )
    end
  end

  defp normalize_event(%{} = ev) do
    case extract_quote_event(ev) do
      {:ok, socket_action, data} when is_map(data) ->
        row = shape_quote_from_data(data)
        Map.put(row, "socket_action", socket_action)

      :skip ->
        ev
    end
  end

  defp normalize_event(other), do: %{"socket_action" => "UNKNOWN", "raw" => other}

  defp extract_quote_event(ev) when is_map(ev) do
    data =
      Map.get(ev, "data") || Map.get(ev, :data) || Map.get(ev, "Data") || Map.get(ev, :Data)

    if not is_map(data) do
      :skip
    else
      top =
        action_string(
          Map.get(ev, "action") || Map.get(ev, :action) || Map.get(ev, "type") ||
            Map.get(ev, :type)
        )

      inner =
        action_string(
          Map.get(data, "action") || Map.get(data, :action) || Map.get(data, "type") ||
            Map.get(data, :type)
        )

      action = if top != "", do: top, else: inner

      cond do
        action == "RESULT" ->
          {:ok, "RESULT", data}

        action == "STEP" and
            (quote_like_data?(data) or company_named?(company_blob(data))) ->
          {:ok, "STEP", data}

        quote_like_data?(data) ->
          # Segfy às vezes manda prêmio/CIA sem action STEP/RESULT explícita no envelope.
          label = if Map.has_key?(data, "premium"), do: "RESULT", else: "STEP"
          {:ok, label, data}

        true ->
          :skip
      end
    end
  end

  defp action_string(nil), do: ""
  defp action_string(a) when is_atom(a), do: a |> Atom.to_string() |> action_string()

  defp action_string(a) when is_binary(a) do
    a |> String.trim() |> String.upcase()
  end

  defp action_string(_), do: ""

  defp quote_like_data?(data) when is_map(data) do
    Map.has_key?(data, "premium") or Map.has_key?(data, "Premium") or
      Map.has_key?(data, "company_prices") or Map.has_key?(data, "companyPrices") or
      company_named?(company_blob(data))
  end

  defp quote_like_data?(_), do: false

  defp company_blob(data) when is_map(data) do
    Map.get(data, "company") || Map.get(data, "Company") || %{}
  end

  defp company_blob(_), do: %{}

  defp company_named?(%{"name" => n}) when is_binary(n), do: String.trim(n) != ""
  defp company_named?(%{"Name" => n}) when is_binary(n), do: String.trim(n) != ""

  defp company_named?(%{"full_name" => n}) when is_binary(n), do: String.trim(n) != ""
  defp company_named?(%{"FullName" => n}) when is_binary(n), do: String.trim(n) != ""

  defp company_named?(%{} = m) do
    case Map.get(m, :name) || Map.get(m, :full_name) do
      n when is_binary(n) -> String.trim(n) != ""
      _ -> false
    end
  end

  defp company_named?(_), do: false

  defp shape_quote_from_data(data) when is_map(data) do
    company = company_blob(data)

    name =
      Map.get(company, "full_name") || Map.get(company, "FullName") ||
        Map.get(company, "name") || Map.get(company, "Name") ||
        Map.get(company, :full_name) || Map.get(company, :name)

    status_raw = Map.get(data, "status") || Map.get(data, "Status")

    %{
      "company_name" => name,
      "premium" => extract_display_premium(data),
      "franchise" => Map.get(data, "franchise") || Map.get(data, "Franchise"),
      "commission" => Map.get(data, "commission") || Map.get(data, "Commission"),
      "status" => status_raw,
      "result_detail" => extract_result_detail(data),
      "quotation" => Map.get(data, "quotation") || Map.get(data, "Quotation"),
      "raw" => data
    }
  end

  defp extract_result_detail(data) when is_map(data) do
    parts =
      [
        Map.get(data, "message"),
        Map.get(data, "Message"),
        Map.get(data, "error"),
        Map.get(data, "Error"),
        Map.get(data, "reason"),
        Map.get(data, "Reason"),
        Map.get(data, "failure_reason"),
        Map.get(data, "description"),
        Map.get(data, "Description")
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case parts do
      [] -> nil
      _ -> parts |> Enum.join(" — ") |> String.slice(0, 240)
    end
  end

  defp extract_result_detail(_), do: nil

  defp extract_display_premium(data) when is_map(data) do
    candidates = premium_candidate_numbers(data)

    case Enum.find(candidates, &(is_number(&1) and &1 > 0)) do
      n when is_number(n) ->
        n

      _ ->
        case sum_company_prices(Map.get(data, "company_prices") || Map.get(data, "companyPrices")) do
          s when is_number(s) and s > 0 -> s
          _ -> List.first(candidates)
        end
    end
  end

  defp premium_candidate_numbers(data) when is_map(data) do
    paths = [
      ["premium"],
      ["Premium"],
      ["annual_premium"],
      ["annualPremium"],
      ["total_premium"],
      ["totalPremium"],
      ["valor_premio"],
      ["valorPremio"],
      ["premio"],
      ["Premio"],
      ["quote", "premium"],
      ["quote", "Premium"],
      ["quotation", "premium"],
      ["Quotation", "Premium"],
      ["price"],
      ["Price"]
    ]

    paths
    |> Enum.map(&dig_string_key_path(data, &1))
    |> Enum.map(&coerce_number/1)
    |> Enum.filter(&is_number/1)
  end

  # Segfy às vezes envia `quote` / `quotation` como UUID (string). `get_in/2` usaria Access na
  # string e quebra com FunctionClauseError — só descemos quando o valor intermediário é mapa.
  defp dig_string_key_path(data, keys) when is_map(data) and is_list(keys),
    do: dig_string_key_path_reduce(data, keys)

  defp dig_string_key_path(_, _), do: nil

  defp dig_string_key_path_reduce(acc, []), do: acc

  defp dig_string_key_path_reduce(acc, [key | rest]) when is_map(acc) do
    case Map.get(acc, key) do
      nil ->
        nil

      next when rest == [] ->
        next

      next when is_map(next) ->
        dig_string_key_path_reduce(next, rest)

      _ ->
        nil
    end
  end

  defp dig_string_key_path_reduce(_, _), do: nil

  defp coerce_number(nil), do: nil
  defp coerce_number(n) when is_integer(n), do: n * 1.0
  defp coerce_number(n) when is_float(n), do: n

  defp coerce_number(n) when is_binary(n) do
    case Float.parse(String.trim(String.replace(n, ",", "."))) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp coerce_number(_), do: nil

  defp sum_company_prices(m) when is_map(m) do
    s =
      Enum.reduce(m, 0.0, fn
        {_k, v}, acc when is_number(v) ->
          acc + v * 1.0

        {_k, v}, acc when is_binary(v) ->
          case coerce_number(v) do
            nil -> acc
            n -> acc + n
          end

        {_k, v}, acc when is_map(v) ->
          case sum_company_prices(v) do
            nil -> acc
            x when is_number(x) -> acc + x
          end

        _, acc ->
          acc
      end)

    if s > 0, do: s, else: nil
  end

  defp sum_company_prices(_), do: nil
end

defmodule Ersventaja.Segfy.MulticalculoSocket.Connection do
  @moduledoc false
  use WebSockex

  require Logger

  @impl true
  def handle_connect(_conn, state), do: {:ok, state}

  @impl true
  def handle_frame({:text, "2"}, state) do
    {:reply, {:text, "3"}, state}
  end

  def handle_frame({:text, <<"0", _::binary>>}, %{join_sent: false} = state) do
    join = "40" <> Jason.encode!(%{roomId: state.room_id})
    {:reply, {:text, join}, %{state | join_sent: true, phase: :wait_ack}}
  end

  # Antes do handler genérico `wait_ack`, senão `42[...]` seria ignorado nessa fase.
  def handle_frame({:text, <<"42", json::binary>>}, state) do
    {:ok, handle_event_json(json, state)}
  end

  def handle_frame({:text, msg}, %{phase: :wait_ack} = state) when is_binary(msg) do
    if msg == "40" or String.starts_with?(msg, "40") do
      send(state.parent, {:segfy_ws, state.sock_ref, :joined})
      hard_ref = Process.send_after(self(), :hard_timeout, state.hard_timeout_ms)

      {:ok, %{state | phase: :collecting, hard_timer_ref: hard_ref}}
    else
      {:ok, state}
    end
  end

  def handle_frame({:text, _other}, state), do: {:ok, state}

  def handle_frame({:binary, _}, state), do: {:ok, state}

  @impl true
  def handle_cast({:calculate_done, true}, state) do
    state = cancel_idle(state)
    ref = Process.send_after(self(), :idle_done, state.idle_ms)
    {:ok, %{state | phase: :draining, drain: true, idle_timer_ref: ref}}
  end

  def handle_cast({:calculate_done, false}, state) do
    notify_done(state, [])
    {:close, %{state | closed: true}}
  end

  @impl true
  def handle_info(:idle_done, %{phase: :draining, closed: false} = state) do
    notify_done(state, state.results)
    {:close, %{state | closed: true}}
  end

  def handle_info(:idle_done, state), do: {:ok, state}

  def handle_info(:hard_timeout, %{closed: false} = state) do
    notify_done(state, state.results)
    {:close, %{state | closed: true}}
  end

  def handle_info(:hard_timeout, state), do: {:ok, state}

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def handle_disconnect(_map, %{closed: true} = state), do: {:ok, state}

  def handle_disconnect(%{reason: reason}, state) do
    unless state.closed do
      send(state.parent, {:segfy_ws, state.sock_ref, {:error, reason}})
    end

    {:ok, state}
  end

  defp handle_event_json(json, state) do
    case Jason.decode(json) do
      {:ok, [room, payload]} when is_binary(room) ->
        if String.trim(room) != String.trim(state.room_id) do
          state
        else
          case payload do
            %{} = pl ->
              results = [pl | state.results]
              state = %{state | results: results}
              maybe_reset_idle(state)

            _ ->
              state
          end
        end

      _ ->
        state
    end
  end

  defp maybe_reset_idle(%{phase: :draining, drain: true} = state) do
    state = cancel_idle(state)
    ref = Process.send_after(self(), :idle_done, state.idle_ms)
    %{state | idle_timer_ref: ref}
  end

  defp maybe_reset_idle(state), do: state

  defp cancel_idle(%{idle_timer_ref: ref} = s) when ref != nil do
    Process.cancel_timer(ref)
    %{s | idle_timer_ref: nil}
  end

  defp cancel_idle(s), do: s

  defp notify_done(state, results) do
    unless state.closed do
      send(state.parent, {:segfy_ws, state.sock_ref, {:done, Enum.reverse(results)}})
    end
  end
end
