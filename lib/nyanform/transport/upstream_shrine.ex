defmodule Nyanform.Transport.UpstreamShrine do
  use GenServer

  alias Nyanform.Protocol.{Lifecycle, Message}

  @type transport_config :: %{
          optional(:env_allowlist) => [String.t()],
          optional(:max_message_size) => pos_integer(),
          transport: :stdio | :http,
          command: [String.t()] | nil,
          endpoint: String.t() | nil,
          env: %{String.t() => String.t()} | nil,
          timeout_ms: pos_integer()
        }

  @type state :: %{
          config: transport_config(),
          port: port() | nil,
          http_session: String.t() | nil,
          requests: %{Message.id() => {pid(), reference()}},
          buffer: binary(),
          initialized: boolean(),
          server_info: map() | nil,
          capabilities: map() | nil,
          protocol_revision: String.t() | nil,
          session_id: String.t() | nil,
          downstream_sink: pid() | nil,
          http_stream: Req.Response.t() | nil,
          http_stream_buffer: binary(),
          http_stream_attempted: boolean()
        }

  @spec start_link(transport_config()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @spec set_downstream_sink(pid(), pid()) :: :ok
  def set_downstream_sink(pid, sink_pid) do
    GenServer.cast(pid, {:set_sink, sink_pid})
  end

  @spec request(pid(), Message.t()) :: {:ok, Message.t()} | {:error, term()}
  def request(pid, %Message{} = message) do
    timeout = configured_timeout(pid)

    try do
      GenServer.call(pid, {:request, message}, timeout)
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(pid, {:cancel_request, message.id})
        {:error, :timeout}

      :exit, {:noproc, _} ->
        {:error, :upstream_gone}

      :exit, reason ->
        {:error, {:upstream_exit, reason}}
    end
  end

  @spec send_notification(pid(), Message.t()) :: :ok
  def send_notification(pid, %Message{} = message) do
    GenServer.cast(pid, {:notification, message})
  end

  @spec initialize(pid()) :: {:ok, Message.t()} | {:error, term()}
  def initialize(pid) do
    timeout = configured_timeout(pid)

    try do
      GenServer.call(pid, :initialize, timeout)
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(pid, {:cancel_requests_from, self()})
        {:error, :timeout}

      :exit, reason ->
        {:error, {:upstream_exit, reason}}
    end
  end

  @spec list_tools(pid(), map()) :: {:ok, Message.t()} | {:error, term()}
  def list_tools(pid, params \\ %{}) do
    msg = Message.request(Lifecycle.generate_id(), "tools/list", params)
    request(pid, msg)
  end

  @spec call_tool(pid(), String.t(), map()) :: {:ok, Message.t()} | {:error, term()}
  def call_tool(pid, name, arguments) do
    params = %{"name" => name, "arguments" => arguments}
    msg = Message.request(Lifecycle.generate_id(), "tools/call", params)
    request(pid, msg)
  end

  @spec server_info(pid()) :: map() | nil
  def server_info(pid) do
    GenServer.call(pid, :server_info)
  end

  @spec sync(pid()) :: :ok | {:error, term()}
  def sync(pid) do
    message = Message.request(Lifecycle.generate_id(), "ping", %{})

    case request(pid, message) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  end

  @impl true
  def init(config) do
    case connect(config) do
      {:ok, connected_state} -> {:ok, connected_state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, %Message{} = message}, from, state) do
    case encode_and_send(message, state) do
      {:ok, new_state} ->
        {request_id, _} = from
        ref = Process.monitor(request_id)
        requests = Map.put(state.requests, message.id, {from, ref})
        {:noreply, %{new_state | requests: requests}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:initialize, _from, %{initialized: true} = state) do
    result = %{
      "serverInfo" => state.server_info,
      "capabilities" => state.capabilities,
      "protocolVersion" => state.protocol_revision
    }

    {:reply, {:ok, Message.response(nil, result)}, state}
  end

  def handle_call(:initialize, from, state) do
    client_info = %{"name" => "nyanform-proxy", "version" => "0.1.0"}
    msg = Lifecycle.build_initialize_request(client_info)

    case encode_and_send(msg, state) do
      {:ok, new_state} ->
        {request_id, _} = from
        ref = Process.monitor(request_id)
        requests = Map.put(new_state.requests, msg.id, {from, ref})
        {:noreply, %{new_state | requests: requests}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:server_info, _from, state) do
    {:reply, state.server_info, state}
  end

  def handle_call(:configured_timeout, _from, state) do
    {:reply, state.config.timeout_ms, state}
  end

  @impl true
  def handle_cast({:notification, %Message{} = message}, state) do
    case encode_and_send(message, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason} -> {:noreply, state}
    end
  end

  def handle_cast({:set_sink, sink_pid}, state) do
    {:noreply, %{state | downstream_sink: sink_pid}}
  end

  def handle_cast({:cancel_request, request_id}, state) do
    {:noreply, cancel_request(state, request_id)}
  end

  def handle_cast({:cancel_requests_from, caller_pid}, state) do
    requests =
      state.requests
      |> Enum.reject(fn {_id, {{pid, _tag}, ref}} ->
        if pid == caller_pid and ref, do: Process.demonitor(ref, [:flush])
        pid == caller_pid
      end)
      |> Map.new()

    {:noreply, %{state | requests: requests}}
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    handle_http_data(data, state)
  end

  def handle_info({:ssl, _socket, data}, state) do
    handle_http_data(data, state)
  end

  def handle_info({:tcp_closed, _socket}, state) do
    fail_all_requests(state, :upstream_closed)
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:ssl_closed, _socket}, state) do
    fail_all_requests(state, :upstream_closed)
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    handle_stdio_data(data, state)
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    fail_all_requests(state, {:upstream_exit, status})
    {:stop, {:upstream_exit, status}, %{state | port: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason} = message, state) do
    if Enum.any?(state.requests, fn {_id, {_from, monitor_ref}} -> monitor_ref == ref end) do
      requests =
        state.requests
        |> Enum.reject(fn {_id, {_from, monitor_ref}} -> monitor_ref == ref end)
        |> Map.new()

      {:noreply, %{state | requests: requests}}
    else
      handle_http_stream_message(message, state)
    end
  end

  def handle_info({:http_response, request_id, response}, state) do
    case Map.fetch(state.requests, request_id) do
      {:ok, {from, ref}} ->
        if ref, do: Process.demonitor(ref, [:flush])
        GenServer.reply(from, response)

        next_state =
          state
          |> Map.put(:requests, Map.delete(state.requests, request_id))
          |> maybe_schedule_http_stream()

        {:noreply, next_state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:start_http_stream, state) do
    case start_http_stream(state) do
      {:ok, response, new_state} ->
        {:noreply, %{new_state | http_stream: response, http_stream_buffer: ""}}

      {:error, _reason, new_state} ->
        {:noreply, new_state}
    end
  end

  def handle_info(message, %{http_stream: %Req.Response{} = response} = state) do
    handle_http_stream_message(message, %{state | http_stream: response})
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    close_port(Map.get(state, :port))
    cancel_http_stream(Map.get(state, :http_stream))
    delete_http_session(state)
    :ok
  end

  defp connect(%{transport: :stdio, command: [cmd | args]} = config) do
    env_list = build_isolated_env(config.env, Map.get(config, :env_allowlist, []))

    connected_config =
      config
      |> Map.put(:timeout_ms, normalize_timeout(Map.get(config, :timeout_ms)))
      |> Map.put(
        :max_message_size,
        normalize_max_message_size(Map.get(config, :max_message_size))
      )

    port_args =
      [
        :binary,
        :stream,
        :exit_status,
        args: args,
        env: env_list
      ]

    port = Port.open({:spawn_executable, to_charlist(find_executable(cmd))}, port_args)

    {:ok,
     %{
       config: connected_config,
       port: port,
       requests: %{},
       buffer: <<>>,
       initialized: false,
       server_info: nil,
       capabilities: nil,
       protocol_revision: nil,
       http_session: nil,
       session_id: nil,
       downstream_sink: nil,
       http_stream: nil,
       http_stream_buffer: "",
       http_stream_attempted: false
     }}
  end

  defp connect(%{transport: :stdio, command: []}) do
    {:error, :no_command}
  end

  defp connect(%{transport: :http, endpoint: endpoint} = config) when is_binary(endpoint) do
    timeout_ms = normalize_timeout(Map.get(config, :timeout_ms))
    max_message_size = normalize_max_message_size(Map.get(config, :max_message_size))

    {:ok,
     %{
       config:
         Map.merge(config, %{
           transport: :http,
           endpoint: endpoint,
           timeout_ms: timeout_ms,
           max_message_size: max_message_size
         }),
       port: nil,
       requests: %{},
       buffer: <<>>,
       initialized: false,
       server_info: nil,
       capabilities: nil,
       protocol_revision: nil,
       http_session: nil,
       session_id: nil,
       downstream_sink: nil,
       http_stream: nil,
       http_stream_buffer: "",
       http_stream_attempted: false
     }}
  end

  defp connect(_config) do
    {:error, :invalid_transport_config}
  end

  defp encode_and_send(%Message{} = message, %{config: %{transport: :stdio}, port: port} = state) do
    {:ok, encoded} = Message.encode(message)
    line = encoded <> "\n"
    Port.command(port, line)
    {:ok, state}
  end

  defp encode_and_send(
         %Message{} = message,
         %{config: %{transport: :http, endpoint: endpoint}} = state
       ) do
    case send_http_request(endpoint, message, state) do
      {:ok, nil, new_state} ->
        {:ok, new_state}

      {:ok, reply, new_state} ->
        send(self(), {:http_response, message.id, reply})
        {:ok, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_http_request(endpoint, %Message{} = message, state) do
    body = Message.encode!(message)

    headers = [{"content-type", "application/json"} | http_headers(state)]

    case Req.post(endpoint,
           body: body,
           headers: headers,
           receive_timeout: state.config.timeout_ms,
           raw: true
         ) do
      {:ok, response} ->
        new_session = Req.Response.get_header(response, "mcp-session-id")
        resolved_session = if new_session == [], do: state.http_session, else: hd(new_session)
        new_state = %{state | http_session: resolved_session}

        case response.status do
          status when status in [202, 204] and response.body in ["", nil] ->
            {:ok, nil, new_state}

          status when status in 200..299 ->
            parse_http_response(response, message, new_state)

          _ ->
            {:error, {:http_error, response.status}}
        end

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}
    end
  end

  defp parse_http_response(response, message, state) do
    case response_content_type(response) do
      "application/json" -> parse_json_http_body(response.body, message, state)
      "text/event-stream" -> parse_sse_http_body(response.body, message, state)
      content_type -> {:error, {:unsupported_content_type, content_type}}
    end
  end

  defp parse_json_http_body(body, message, state) when is_binary(body) and body != "" do
    with {:ok, parsed} <- Message.parse(body, state.config.max_message_size) do
      route_http_messages([parsed], message, state)
    end
  end

  defp parse_json_http_body(body, message, state) when is_map(body) and map_size(body) > 0 do
    with {:ok, json} <- Jason.encode(body),
         {:ok, parsed} <- Message.parse(json, state.config.max_message_size) do
      route_http_messages([parsed], message, state)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_json_http_body(body, message, state) when body in ["", nil] do
    route_http_messages([], message, state)
  end

  defp parse_sse_http_body(body, message, state) when is_binary(body) do
    with {:ok, messages} <- parse_complete_sse(body, state.config.max_message_size) do
      route_http_messages(messages, message, state)
    end
  end

  defp route_http_messages(messages, request_message, state) do
    {reply, routed_state} =
      Enum.reduce(messages, {nil, state}, fn incoming, {reply, current_state} ->
        cond do
          incoming.id == request_message.id and Message.response?(incoming) ->
            {{:ok, incoming}, maybe_store_initialize_result(incoming, current_state)}

          incoming.id == request_message.id and Message.error?(incoming) ->
            {{:error, incoming}, current_state}

          true ->
            {reply, process_incoming(incoming, current_state)}
        end
      end)

    {:ok, reply, routed_state}
  end

  defp parse_complete_sse(body, max_message_size) do
    body
    |> String.replace("\r\n", "\n")
    |> String.split("\n\n")
    |> parse_sse_events(max_message_size)
  end

  defp parse_sse_events(events, max_message_size) do
    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, messages} ->
      case parse_sse_event(event, max_message_size) do
        {:ok, nil} -> {:cont, {:ok, messages}}
        {:ok, message} -> {:cont, {:ok, [message | messages]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_sse_event(event, max_message_size) do
    data =
      event
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case line do
          "data:" <> value -> [String.trim_leading(value, " ")]
          _ -> []
        end
      end)
      |> Enum.join("\n")

    if data == "" do
      {:ok, nil}
    else
      Message.parse(data, max_message_size)
    end
  end

  defp response_content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [content_type | _] ->
        content_type
        |> String.split(";", parts: 2)
        |> hd()
        |> String.trim()
        |> String.downcase()

      [] ->
        nil
    end
  end

  defp maybe_schedule_http_stream(
         %{
           config: %{transport: :http},
           initialized: true,
           http_session: session_id,
           http_stream_attempted: false
         } = state
       )
       when is_binary(session_id) do
    send(self(), :start_http_stream)
    %{state | http_stream_attempted: true}
  end

  defp maybe_schedule_http_stream(state), do: state

  defp start_http_stream(%{config: %{endpoint: endpoint}} = state) do
    case Req.get(endpoint,
           headers: http_headers(state),
           receive_timeout: state.config.timeout_ms,
           raw: true,
           retry: false,
           into: :self
         ) do
      {:ok, %Req.Response{status: 200} = response} ->
        new_state = update_http_session(state, response)

        if response_content_type(response) == "text/event-stream" do
          {:ok, response, new_state}
        else
          cancel_http_stream(response)
          {:error, :unsupported_content_type, new_state}
        end

      {:ok, response} ->
        cancel_http_stream(response)
        {:error, {:http_error, response.status}, state}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}, state}
    end
  end

  defp handle_http_stream_chunks(chunks, state) do
    Enum.reduce_while(chunks, {:ok, state}, fn chunk, {:ok, current_state} ->
      case handle_http_stream_chunk(chunk, current_state) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, next_state} -> {:halt, {:error, next_state}}
      end
    end)
    |> case do
      {:ok, next_state} -> {:noreply, next_state}
      {:error, next_state} -> {:noreply, clear_http_stream(next_state)}
    end
  end

  defp handle_http_stream_message(message, %{http_stream: %Req.Response{} = response} = state) do
    case Req.parse_message(response, message) do
      {:ok, chunks} -> handle_http_stream_chunks(chunks, state)
      {:error, _reason} -> {:noreply, clear_http_stream(state)}
      :unknown -> {:noreply, state}
    end
  end

  defp handle_http_stream_message(_message, state), do: {:noreply, state}

  defp handle_http_stream_chunk({:data, data}, state) do
    buffer = state.http_stream_buffer <> data

    case parse_stream_sse(buffer, state.config.max_message_size) do
      {:ok, messages, remaining} ->
        new_state = Enum.reduce(messages, state, &process_incoming/2)
        {:ok, %{new_state | http_stream_buffer: remaining}}

      {:error, _reason} ->
        {:error, state}
    end
  end

  defp handle_http_stream_chunk(:done, state) do
    case parse_complete_sse(state.http_stream_buffer, state.config.max_message_size) do
      {:ok, messages} ->
        new_state = Enum.reduce(messages, state, &process_incoming/2)
        {:ok, clear_http_stream(new_state)}

      {:error, _reason} ->
        {:error, state}
    end
  end

  defp handle_http_stream_chunk({:trailers, _trailers}, state), do: {:ok, state}

  defp parse_stream_sse(buffer, max_message_size) do
    normalized = String.replace(buffer, "\r\n", "\n")
    parts = String.split(normalized, "\n\n")

    {events, remaining} =
      if String.ends_with?(normalized, "\n\n") do
        {parts, ""}
      else
        {Enum.drop(parts, -1), List.last(parts) || ""}
      end

    with {:ok, messages} <- parse_sse_events(events, max_message_size),
         :ok <- validate_sse_buffer(remaining, max_message_size) do
      {:ok, messages, remaining}
    end
  end

  defp validate_sse_buffer(buffer, max_message_size) do
    if byte_size(buffer) <= max_message_size * 2,
      do: :ok,
      else: {:error, {:message_too_large, byte_size(buffer)}}
  end

  defp http_headers(state) do
    protocol_revision =
      state.protocol_revision || Application.fetch_env!(:nyanform, :protocol_revision)

    headers = [
      {"accept", "application/json, text/event-stream"},
      {"mcp-protocol-version", protocol_revision}
    ]

    if state.http_session == nil,
      do: headers,
      else: headers ++ [{"mcp-session-id", state.http_session}]
  end

  defp update_http_session(state, response) do
    case Req.Response.get_header(response, "mcp-session-id") do
      [session_id | _] -> %{state | http_session: session_id}
      [] -> state
    end
  end

  defp clear_http_stream(state) do
    %{state | http_stream: nil, http_stream_buffer: ""}
  end

  defp cancel_http_stream(%Req.Response{body: %Req.Response.Async{}} = response) do
    Req.cancel_async_response(response)
  catch
    :exit, _reason -> :ok
  end

  defp cancel_http_stream(_response), do: :ok

  defp delete_http_session(%{
         config: %{transport: :http, endpoint: endpoint, timeout_ms: timeout_ms},
         http_session: session_id,
         protocol_revision: protocol_revision
       })
       when is_binary(session_id) do
    protocol_revision =
      protocol_revision || Application.fetch_env!(:nyanform, :protocol_revision)

    Req.delete(endpoint,
      headers: [
        {"mcp-session-id", session_id},
        {"mcp-protocol-version", protocol_revision}
      ],
      receive_timeout: min(timeout_ms, 5_000),
      raw: true,
      retry: false
    )

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp delete_http_session(_state), do: :ok

  defp close_port(port) when is_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
  end

  defp close_port(_port), do: :ok

  defp handle_stdio_data(data, state) do
    buffer = state.buffer <> data

    case parse_lines(buffer, state.config.max_message_size) do
      {:ok, messages, remaining} ->
        new_state = Enum.reduce(messages, state, &process_incoming/2)
        {:noreply, %{new_state | buffer: remaining}}

      {:incomplete, buffer} ->
        handle_incomplete_buffer(buffer, state)

      {:error, reason} ->
        fail_all_requests(state, reason)
        {:stop, reason, %{state | buffer: ""}}
    end
  end

  defp handle_http_data(data, state) do
    buffer = state.buffer <> data

    case parse_lines(buffer, state.config.max_message_size) do
      {:ok, messages, remaining} ->
        new_state = Enum.reduce(messages, state, &process_incoming/2)
        {:noreply, %{new_state | buffer: remaining}}

      {:incomplete, buffer} ->
        handle_incomplete_buffer(buffer, state)

      {:error, reason} ->
        fail_all_requests(state, reason)
        {:stop, reason, %{state | buffer: ""}}
    end
  end

  defp parse_lines(buffer, max_message_size) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        parse_line(line, rest, max_message_size)

      [_incomplete] ->
        {:incomplete, buffer}
    end
  end

  defp parse_line(line, rest, max_message_size) do
    trimmed = String.trim(line)

    if trimmed == "" do
      parse_lines(rest, max_message_size)
    else
      parse_non_empty_line(trimmed, rest, max_message_size)
    end
  end

  defp parse_non_empty_line(trimmed, rest, max_message_size) do
    case Message.parse(trimmed, max_message_size) do
      {:ok, msg} ->
        prepend_message(msg, parse_lines(rest, max_message_size))

      {:error, {:message_too_large, _size} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        parse_lines(rest, max_message_size)
    end
  end

  defp prepend_message(msg, {:ok, msgs, remaining}), do: {:ok, [msg | msgs], remaining}
  defp prepend_message(msg, {:incomplete, remaining}), do: {:ok, [msg], remaining}
  defp prepend_message(_msg, {:error, reason}), do: {:error, reason}

  defp handle_incomplete_buffer(buffer, state) do
    if byte_size(buffer) <= state.config.max_message_size do
      {:noreply, %{state | buffer: buffer}}
    else
      reason = {:message_too_large, byte_size(buffer)}
      fail_all_requests(state, reason)
      {:stop, reason, %{state | buffer: ""}}
    end
  end

  defp process_incoming(%Message{kind: :response, id: id} = msg, state) do
    case Map.fetch(state.requests, id) do
      {:ok, {from, ref}} ->
        if ref, do: Process.demonitor(ref, [:flush])
        GenServer.reply(from, {:ok, msg})

        new_state = maybe_store_initialize_result(msg, state)
        %{new_state | requests: Map.delete(new_state.requests, id)}

      :error ->
        state
    end
  end

  defp process_incoming(%Message{kind: :error, id: id} = msg, state) do
    case Map.fetch(state.requests, id) do
      {:ok, {from, ref}} ->
        if ref, do: Process.demonitor(ref, [:flush])
        GenServer.reply(from, {:error, msg})
        %{state | requests: Map.delete(state.requests, id)}

      :error ->
        state
    end
  end

  defp process_incoming(%Message{kind: :notification} = msg, state) do
    forward_to_downstream(msg, state)
    state
  end

  defp process_incoming(%Message{kind: :request} = msg, state) do
    forward_to_downstream(msg, state)
    state
  end

  defp forward_to_downstream(%Message{}, %{downstream_sink: nil}) do
    :ok
  end

  defp forward_to_downstream(%Message{} = msg, %{downstream_sink: sink_pid})
       when is_pid(sink_pid) do
    send(sink_pid, {:upstream_message, msg})
    :ok
  end

  defp maybe_store_initialize_result(%Message{result: result}, state) when is_map(result) do
    server_info = Map.get(result, "serverInfo")
    capabilities = Map.get(result, "capabilities")
    protocol_revision = Map.get(result, "protocolVersion")

    %{
      state
      | server_info: server_info,
        capabilities: capabilities,
        protocol_revision: protocol_revision,
        initialized: true
    }
  end

  defp maybe_store_initialize_result(_, state), do: state

  defp fail_all_requests(state, reason) do
    Enum.each(state.requests, fn {_id, {from, ref}} ->
      if ref, do: Process.demonitor(ref, [:flush])
      GenServer.reply(from, {:error, reason})
    end)
  end

  @system_vars ~w(PATH PATHEXT SYSTEMROOT TEMP TMP HOME USERPROFILE APPDATA LOCALAPPDATA PROGRAMDATA COMSPEC WINDIR)

  defp build_isolated_env(configured, allowlist) do
    system_env = System.get_env()
    configured = configured || %{}

    cleared_vars =
      Enum.map(system_env, fn {key, _value} ->
        {String.to_charlist(key), false}
      end)

    system_minimum =
      inherited_vars(system_env, @system_vars)

    allowlisted_vars = inherited_vars(system_env, allowlist)

    configured_vars =
      Enum.map(configured, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    cleared_vars ++ system_minimum ++ allowlisted_vars ++ configured_vars
  end

  defp inherited_vars(system_env, names) do
    Enum.flat_map(names, fn allowed_key ->
      case Enum.find(system_env, fn {key, _value} ->
             String.upcase(key) == String.upcase(allowed_key)
           end) do
        {key, value} -> [{String.to_charlist(key), String.to_charlist(value)}]
        nil -> []
      end
    end)
  end

  defp find_executable(cmd) do
    case System.find_executable(cmd) do
      nil -> cmd
      path -> path
    end
  end

  defp configured_timeout(pid) do
    GenServer.call(pid, :configured_timeout, 5_000)
  catch
    :exit, _reason -> Application.fetch_env!(:nyanform, :request_timeout_ms)
  end

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_timeout(_timeout), do: Application.fetch_env!(:nyanform, :request_timeout_ms)

  defp normalize_max_message_size(size) when is_integer(size) and size > 0, do: size

  defp normalize_max_message_size(_size),
    do: Application.fetch_env!(:nyanform, :max_message_size)

  defp cancel_request(state, request_id) do
    case Map.pop(state.requests, request_id) do
      {nil, _requests} ->
        state

      {{_from, ref}, requests} ->
        if ref, do: Process.demonitor(ref, [:flush])
        %{state | requests: requests}
    end
  end
end
