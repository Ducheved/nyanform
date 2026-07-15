defmodule Nyanform.Transport.DownstreamHttp do
  @spec run(Nyanform.Transport.UpstreamShrine.transport_config(), String.t(), atom(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def run(upstream_config, profile, policy, opts \\ []) do
    host = Keyword.get(opts, :host, "127.0.0.1")

    plug_opts = %{
      upstream_config: upstream_config,
      profile: profile,
      policy: policy,
      tool_filters: Keyword.get(opts, :tool_filters, %{}),
      bind_host: host,
      allowed_origins: Keyword.get(opts, :allowed_origins, []),
      max_http_body_size: option(opts, :max_http_body_size, 4_194_304),
      max_message_size: option(opts, :max_message_size, 1_048_576),
      max_sessions: option(opts, :max_sessions, 64),
      session_idle_ttl_ms:
        Keyword.get(opts, :session_idle_ttl_ms, Keyword.get(opts, :session_ttl_ms, 300_000)),
      max_pending_upstream: option(opts, :max_pending_upstream, 128),
      sse_wait_ms: option(opts, :sse_wait_ms, 250),
      request_timeout_ms:
        positive_integer(
          Keyword.get(opts, :request_timeout_ms, configured_timeout(upstream_config)),
          configured_timeout(upstream_config)
        )
    }

    with {:ok, ip} <- parse_ip(host) do
      Bandit.start_link(
        scheme: :http,
        plug: {Nyanform.Transport.HttpPlug, plug_opts},
        port: Keyword.get(opts, :port, 8080),
        ip: ip
      )
    end
  end

  defp option(opts, key, default) do
    case Keyword.get(opts, key, Application.get_env(:nyanform, key, default)) do
      value when is_integer(value) and value > 0 -> value
      _value -> default
    end
  end

  defp configured_timeout(%{timeout_ms: timeout_ms})
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: timeout_ms

  defp configured_timeout(_upstream_config) do
    positive_integer(Application.get_env(:nyanform, :request_timeout_ms), 30_000)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp parse_ip("localhost"), do: {:ok, {127, 0, 0, 1}}

  defp parse_ip(host) when is_binary(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> {:error, {:invalid_host, host}}
    end
  end

  defp parse_ip(ip) when is_tuple(ip), do: {:ok, ip}
end

defmodule Nyanform.Transport.HttpPlug do
  use Plug.Builder

  alias Nyanform.Protocol.{ErrorCodes, Message}
  alias Nyanform.Session.{Manager, Thread}

  import Plug.Conn

  @defaults %{
    upstream_config: nil,
    profile: "canonical",
    policy: :strict,
    tool_filters: %{},
    bind_host: "127.0.0.1",
    allowed_origins: [],
    max_http_body_size: 4_194_304,
    max_message_size: 1_048_576,
    max_sessions: 64,
    session_idle_ttl_ms: 300_000,
    max_pending_upstream: 128,
    sse_wait_ms: 250,
    request_timeout_ms: 30_000
  }

  @impl true
  def init(opts), do: Map.merge(@defaults, Map.new(opts))

  @impl true
  def call(conn, opts) do
    conn = put_private(conn, :nyanform_opts, opts)
    super(conn, opts)
  end

  plug(:handle_mcp)

  defp handle_mcp(%Plug.Conn{private: %{nyanform_opts: opts}} = conn, _opts) do
    if origin_allowed?(conn, opts) do
      route_request(conn, opts)
    else
      send_json_error(conn, 403, ErrorCodes.invalid_request(), "Origin not allowed")
    end
  end

  defp route_request(%Plug.Conn{method: "POST"} = conn, opts), do: handle_post(conn, opts)
  defp route_request(%Plug.Conn{method: "GET"} = conn, opts), do: handle_get(conn, opts)
  defp route_request(%Plug.Conn{method: "DELETE"} = conn, _opts), do: handle_delete(conn)

  defp route_request(conn, _opts) do
    conn
    |> put_resp_header("allow", "POST, GET, DELETE")
    |> send_json_error(405, ErrorCodes.invalid_request(), "Method not allowed")
  end

  defp handle_post(conn, opts) do
    if content_length_exceeds?(conn, opts.max_http_body_size) do
      send_json_error(conn, 413, ErrorCodes.parse_error(), "Request body too large")
    else
      read_post_body(conn, opts)
    end
  end

  defp read_post_body(conn, opts) do
    case Plug.Conn.read_body(conn,
           length: opts.max_http_body_size,
           read_length: min(opts.max_http_body_size, 1_048_576),
           read_timeout: 30_000
         ) do
      {:ok, body, conn} ->
        handle_body(conn, body, opts)

      {:more, _body, conn} ->
        send_body_too_large(conn)

      {:error, _reason} ->
        send_json_error(conn, 400, ErrorCodes.parse_error(), "Failed to read body")
    end
  end

  defp handle_body(conn, body, opts) do
    case Message.parse(body, opts.max_message_size) do
      {:ok, message} ->
        handle_parsed_message(conn, message, opts)

      {:error, {:parse_error, reason}} ->
        send_json_error(conn, 400, ErrorCodes.parse_error(), "Parse error: #{reason}")

      {:error, {:message_too_large, _size}} ->
        send_json_error(conn, 413, ErrorCodes.parse_error(), "Message too large")
    end
  end

  defp handle_parsed_message(conn, message, opts) do
    case session_header(conn) do
      :absent ->
        handle_headerless_message(conn, message, opts)

      {:ok, session_id} ->
        handle_existing_session(conn, session_id, message, opts.request_timeout_ms)

      :invalid ->
        send_json_error(conn, 400, ErrorCodes.invalid_request(), "Invalid session header")
    end
  end

  defp handle_headerless_message(conn, message, opts) do
    if initialize_request?(message) do
      if Thread.valid_initialize_params?(message.params) do
        create_session(conn, message, opts)
      else
        send_json_error(
          conn,
          400,
          ErrorCodes.invalid_params(),
          "Invalid initialize params",
          message.id
        )
      end
    else
      send_json_error(conn, 400, ErrorCodes.invalid_request(), "Mcp-Session-Id header required")
    end
  end

  defp create_session(conn, message, opts) do
    session_id = generate_session_id()

    start = fn ->
      case Map.get(opts, :session_start) do
        fun when is_function(fun, 1) ->
          fun.(session_id)

        _other ->
          Thread.initialize(
            session_id,
            opts.upstream_config,
            opts.profile,
            opts.policy,
            opts.tool_filters,
            max_pending_upstream: opts.max_pending_upstream
          )
      end
    end

    case Manager.create(session_id,
           max_sessions: opts.max_sessions,
           idle_ttl_ms: opts.session_idle_ttl_ms,
           start: start
         ) do
      {:ok, _pid, :created} ->
        handle_session_response(conn, session_id, message, opts.request_timeout_ms)

      {:ok, _pid, :existing} ->
        handle_session_response(conn, session_id, message, opts.request_timeout_ms)

      {:error, :too_many_sessions} ->
        send_session_limit(conn)

      {:error, reason} ->
        send_session_error(conn, reason)
    end
  end

  defp handle_existing_session(conn, session_id, message, request_timeout_ms) do
    case Manager.fetch(session_id) do
      {:ok, _pid} -> handle_session_response(conn, session_id, message, request_timeout_ms)
      {:error, :session_not_found} -> send_session_not_found(conn)
    end
  end

  defp handle_session_response(conn, session_id, message, request_timeout_ms) do
    case call_session(session_id, message, request_timeout_ms) do
      {:reply, response} ->
        Manager.touch(session_id)

        conn
        |> put_resp_header("content-type", "application/json")
        |> put_resp_header("mcp-session-id", session_id)
        |> send_resp(200, Message.encode!(response))

      :ok ->
        Manager.touch(session_id)
        conn |> put_resp_header("mcp-session-id", session_id) |> send_resp(202, "")

      {:error, :session_not_found} ->
        Manager.delete(session_id)
        send_session_not_found(conn)

      {:error, :session_timeout} ->
        send_json_error(
          conn,
          504,
          ErrorCodes.internal_error(),
          "Session request timed out",
          message.id
        )

      {:error, reason} ->
        send_json_error(
          conn,
          500,
          ErrorCodes.internal_error(),
          "Session error: #{inspect(reason)}",
          message.id
        )
    end
  end

  defp handle_get(conn, opts) do
    case session_header(conn) do
      {:ok, session_id} ->
        stream_session_messages(conn, session_id, opts.sse_wait_ms)

      :absent ->
        send_json_error(conn, 400, ErrorCodes.invalid_request(), "Mcp-Session-Id header required")

      :invalid ->
        send_json_error(conn, 400, ErrorCodes.invalid_request(), "Invalid session header")
    end
  end

  defp stream_session_messages(conn, session_id, wait_ms) do
    case Manager.fetch(session_id) do
      {:ok, _pid} ->
        case lease_session_messages(session_id, wait_ms) do
          {:ok, lease_ref, messages} ->
            conn = send_sse(conn, session_id, messages)
            acknowledge_session_messages(session_id, lease_ref)
            Manager.touch(session_id)
            conn

          {:error, :session_not_found} ->
            Manager.delete(session_id)
            send_session_not_found(conn)

          {:error, reason} ->
            send_session_error(conn, reason)
        end

      {:error, :session_not_found} ->
        send_session_not_found(conn)
    end
  end

  defp handle_delete(conn) do
    case session_header(conn) do
      {:ok, session_id} ->
        case Manager.delete(session_id) do
          :ok -> send_resp(conn, 204, "")
          {:error, :session_not_found} -> send_session_not_found(conn)
        end

      :absent ->
        send_json_error(conn, 400, ErrorCodes.invalid_request(), "Mcp-Session-Id header required")

      :invalid ->
        send_json_error(conn, 400, ErrorCodes.invalid_request(), "Invalid session header")
    end
  end

  defp origin_allowed?(conn, opts) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> allowed_origin?(origin, opts.allowed_origins, opts.bind_host)
      _multiple -> false
    end
  end

  defp allowed_origin?(origin, allowed_origins, _bind_host) when allowed_origins != [] do
    origin in allowed_origins
  end

  defp allowed_origin?(origin, [], bind_host) do
    loopback_bind?(bind_host) and loopback_origin?(origin)
  end

  defp loopback_origin?(origin) do
    case URI.parse(origin) do
      %URI{
        scheme: scheme,
        host: host,
        path: path,
        query: nil,
        fragment: nil,
        userinfo: nil
      }
      when scheme in ["http", "https"] and is_binary(host) and path in [nil, ""] ->
        loopback_host?(host)

      _uri ->
        false
    end
  end

  defp loopback_bind?(host) when is_binary(host), do: loopback_host?(host)
  defp loopback_bind?({127, _b, _c, _d}), do: true
  defp loopback_bind?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_bind?(_host), do: false

  defp loopback_host?(host) do
    normalized = String.downcase(host)

    normalized == "localhost" or normalized == "::1" or
      case :inet.parse_address(to_charlist(normalized)) do
        {:ok, {127, _b, _c, _d}} -> true
        {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
        _other -> false
      end
  end

  defp initialize_request?(%Message{kind: :request, method: "initialize"}), do: true
  defp initialize_request?(_message), do: false

  defp session_header(conn) do
    case get_req_header(conn, "mcp-session-id") do
      [] -> :absent
      [session_id] when is_binary(session_id) and byte_size(session_id) > 0 -> {:ok, session_id}
      _other -> :invalid
    end
  end

  defp content_length_exceeds?(conn, max_size) do
    case get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> length > max_size
          _invalid -> false
        end

      _other ->
        false
    end
  end

  defp send_sse(conn, session_id, messages) do
    body = Enum.map_join(messages, "", &sse_frame/1)

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("mcp-session-id", session_id)
    |> send_resp(200, body)
  end

  defp sse_frame(message), do: "event: message\ndata: #{Message.encode!(message)}\n\n"

  defp call_session(session_id, message, request_timeout_ms) do
    Thread.handle_downstream(session_id, message, request_timeout_ms)
  catch
    :exit, {:timeout, _reason} -> {:error, :session_timeout}
    :exit, {:noproc, _reason} -> {:error, :session_not_found}
    :exit, reason -> {:error, {:session_exit, reason}}
  end

  defp lease_session_messages(session_id, wait_ms) do
    Thread.lease_upstream_messages(session_id, self(), wait_ms)
  catch
    :exit, {:noproc, _reason} -> {:error, :session_not_found}
    :exit, reason -> {:error, {:session_exit, reason}}
  end

  defp acknowledge_session_messages(_session_id, nil), do: :ok

  defp acknowledge_session_messages(session_id, lease_ref) do
    Thread.ack_upstream_messages(session_id, self(), lease_ref)
  catch
    :exit, _reason -> :ok
  end

  defp send_body_too_large(conn) do
    send_json_error(conn, 413, ErrorCodes.parse_error(), "Request body too large")
  end

  defp send_session_limit(conn) do
    conn
    |> put_resp_header("retry-after", "1")
    |> send_json_error(429, ErrorCodes.internal_error(), "Too many concurrent sessions")
  end

  defp send_session_not_found(conn) do
    send_json_error(conn, 404, ErrorCodes.invalid_request(), "Session not found")
  end

  defp send_session_error(conn, reason) do
    send_json_error(
      conn,
      500,
      ErrorCodes.internal_error(),
      "Session error: #{inspect(reason)}"
    )
  end

  defp send_json_error(conn, status, code, message, id \\ nil) do
    response = Message.error_response(id, code, message)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, Message.encode!(response))
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
