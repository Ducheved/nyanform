defmodule Nyanform.Transport.UpstreamHttpFixture do
  import Plug.Conn

  def init(test_pid), do: test_pid

  def call(conn, test_pid) do
    conn = put_private(conn, :test_pid, test_pid)
    {:ok, body, conn} = read_body(conn)
    message = if body == "", do: nil, else: Jason.decode!(body)

    send(test_pid, {
      :upstream_http_request,
      conn.method,
      message,
      conn.req_headers
    })

    respond(conn, message)
  end

  defp respond(%Plug.Conn{method: "GET"} = conn, nil) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => "server-request-1",
      "method" => "sampling/createMessage",
      "params" => %{"messages" => []}
    }

    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/resources/list_changed"
    }

    body =
      "event: message\n" <>
        "data: #{Jason.encode!(request)}\n\n" <>
        "data: #{Jason.encode!(notification)}\n\n"

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, body)
    send(conn.private.test_pid, {:upstream_get_handler, self()})
    stream(conn)
  end

  defp respond(%Plug.Conn{method: "DELETE"} = conn, nil), do: send_resp(conn, 204, "")

  defp respond(%Plug.Conn{method: "POST"} = conn, %{"method" => "initialize", "id" => id}) do
    notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/tools/list_changed"
    }

    response = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-11-25",
        "capabilities" => %{"tools" => %{"listChanged" => true}},
        "serverInfo" => %{"name" => "http-fixture", "version" => "1"}
      }
    }

    body =
      "event: message\n" <>
        "data: #{Jason.encode!(notification)}\n\n" <>
        ": keepalive\n" <>
        "event: message\n" <>
        "data: #{Jason.encode!(response)}\n\n"

    conn
    |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
    |> put_resp_header("mcp-session-id", "session-123")
    |> send_resp(200, body)
  end

  defp respond(%Plug.Conn{method: "POST"} = conn, %{"method" => "tools/list", "id" => id}) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => []}})

    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, body)
  end

  defp respond(%Plug.Conn{method: "POST"} = conn, %{"method" => "error/test", "id" => id}) do
    error = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_001, "message" => "fixture error"}
    }

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> send_resp(200, "data: #{Jason.encode!(error)}\n\n")
  end

  defp respond(%Plug.Conn{method: "POST"} = conn, %{"method" => "oversize", "id" => id}) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{"value" => String.duplicate("x", 2_048)}
      })

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, body)
  end

  defp respond(
         %Plug.Conn{method: "POST"} = conn,
         %{"method" => "notifications/initialized"}
       ) do
    send_resp(conn, 202, "")
  end

  defp respond(
         %Plug.Conn{method: "POST"} = conn,
         %{"method" => "notifications/cancelled"}
       ) do
    send_resp(conn, 204, "")
  end

  defp respond(%Plug.Conn{method: "POST"} = conn, %{"method" => "async/test"}) do
    send_resp(conn, 202, "")
  end

  defp respond(conn, _message), do: send_resp(conn, 404, "")

  defp stream(conn) do
    receive do
      {:send_sse, message} ->
        {:ok, conn} = chunk(conn, "data: #{Jason.encode!(message)}\n\n")
        stream(conn)

      :finish_upstream_get ->
        conn
    after
      500 -> conn
    end
  end
end

defmodule Nyanform.Transport.UpstreamHttpTest do
  use ExUnit.Case, async: false

  alias Nyanform.Protocol.Message
  alias Nyanform.Transport.UpstreamShrine

  setup do
    {:ok, server} =
      Bandit.start_link(
        plug: {Nyanform.Transport.UpstreamHttpFixture, self()},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        thousand_island_options: [silent_terminate_on_error: true]
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    Process.unlink(server)

    on_exit(fn ->
      if Process.alive?(server) do
        try do
          GenServer.stop(server)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    %{endpoint: "http://127.0.0.1:#{port}"}
  end

  test "routes multi-event SSE and preserves protocol and session headers", %{endpoint: endpoint} do
    pid = start_upstream(endpoint, 1_024)
    :ok = UpstreamShrine.set_downstream_sink(pid, self())

    assert {:ok, initialize} = UpstreamShrine.initialize(pid)
    assert initialize.result["serverInfo"]["name"] == "http-fixture"

    assert_receive {:upstream_message,
                    %Message{kind: :notification, method: "notifications/tools/list_changed"}}

    assert_receive {:upstream_http_request, "POST", %{"method" => "initialize"}, init_headers}
    assert header(init_headers, "accept") == "application/json, text/event-stream"
    assert header(init_headers, "mcp-protocol-version") == "2025-11-25"
    assert header(init_headers, "mcp-session-id") == nil

    assert {:ok, tools} = UpstreamShrine.list_tools(pid)
    assert tools.result == %{"tools" => []}

    assert_receive {:upstream_http_request, "POST", %{"method" => "tools/list"}, headers}
    assert header(headers, "mcp-session-id") == "session-123"
    assert header(headers, "mcp-protocol-version") == "2025-11-25"

    stop_upstream(pid)
  end

  test "routes SSE JSON-RPC errors to the pending caller", %{endpoint: endpoint} do
    pid = start_upstream(endpoint, 1_024)
    assert {:ok, _initialize} = UpstreamShrine.initialize(pid)

    message = Message.request("error-1", "error/test", %{})

    assert {:error, %Message{kind: :error, id: "error-1"} = error} =
             UpstreamShrine.request(pid, message)

    assert error.error.code == -32_001
    stop_upstream(pid)
  end

  test "accepts empty 202 notification responses without creating a reply", %{endpoint: endpoint} do
    pid = start_upstream(endpoint, 1_024)
    assert {:ok, _initialize} = UpstreamShrine.initialize(pid)

    notification = Message.notification("notifications/initialized", %{})
    assert :ok = UpstreamShrine.send_notification(pid, notification)

    assert_receive {:upstream_http_request, "POST", %{"method" => "notifications/initialized"},
                    _headers}

    cancelled = Message.notification("notifications/cancelled", %{"requestId" => "request-1"})
    assert :ok = UpstreamShrine.send_notification(pid, cancelled)

    assert_receive {:upstream_http_request, "POST", %{"method" => "notifications/cancelled"},
                    _headers}

    Process.sleep(25)
    assert Process.alive?(pid)
    assert :sys.get_state(pid).requests == %{}
    stop_upstream(pid)
  end

  test "enforces configured max message size for HTTP frames", %{endpoint: endpoint} do
    pid = start_upstream(endpoint, 512)
    assert {:ok, _initialize} = UpstreamShrine.initialize(pid)

    message = Message.request("large-1", "oversize", %{})
    assert {:error, {:message_too_large, size}} = UpstreamShrine.request(pid, message)
    assert size > 512
    stop_upstream(pid)
  end

  test "opens GET SSE after session establishment and cleans it up on stop", %{
    endpoint: endpoint
  } do
    pid = start_upstream(endpoint, 1_024)
    :ok = UpstreamShrine.set_downstream_sink(pid, self())
    assert {:ok, _initialize} = UpstreamShrine.initialize(pid)

    assert_receive {:upstream_http_request, "GET", nil, headers}
    assert header(headers, "mcp-session-id") == "session-123"
    assert header(headers, "mcp-protocol-version") == "2025-11-25"
    assert_receive {:upstream_get_handler, handler}

    assert_receive {:upstream_message,
                    %Message{
                      kind: :request,
                      id: "server-request-1",
                      method: "sampling/createMessage"
                    }}

    assert_receive {:upstream_message,
                    %Message{
                      kind: :notification,
                      method: "notifications/resources/list_changed"
                    }}

    assert %Req.Response{} = :sys.get_state(pid).http_stream
    monitor = Process.monitor(pid)

    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok = UpstreamShrine.stop(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
      send(handler, :finish_upstream_get)
      Process.sleep(25)
    end)

    assert_receive {:upstream_http_request, "DELETE", nil, delete_headers}
    assert header(delete_headers, "mcp-session-id") == "session-123"
    assert header(delete_headers, "mcp-protocol-version") == "2025-11-25"
  end

  test "routes a pending POST response from the GET SSE stream", %{endpoint: endpoint} do
    pid = start_upstream(endpoint, 1_024)
    assert {:ok, _initialize} = UpstreamShrine.initialize(pid)
    assert_receive {:upstream_get_handler, handler}

    request = Message.request("async-1", "async/test", %{})
    task = Task.async(fn -> UpstreamShrine.request(pid, request) end)

    assert_receive {:upstream_http_request, "POST", %{"method" => "async/test"}, _headers}

    send(handler, {
      :send_sse,
      %{"jsonrpc" => "2.0", "id" => "async-1", "result" => %{"accepted" => true}}
    })

    assert {:ok, %Message{kind: :response, result: %{"accepted" => true}}} =
             Task.await(task, 1_000)

    send(handler, :finish_upstream_get)
    Process.sleep(10)
    assert :ok = UpstreamShrine.stop(pid)
  end

  defp start_upstream(endpoint, max_message_size) do
    config = %{
      transport: :http,
      command: nil,
      endpoint: endpoint,
      env: nil,
      env_allowlist: [],
      timeout_ms: 1_000,
      max_message_size: max_message_size
    }

    {:ok, pid} = UpstreamShrine.start_link(config)
    pid
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn
      {^name, value} -> value
      _header -> nil
    end)
  end

  defp stop_upstream(pid) do
    receive do
      {:upstream_get_handler, handler} -> send(handler, :finish_upstream_get)
    after
      100 -> :ok
    end

    Process.sleep(10)
    assert :ok = UpstreamShrine.stop(pid)
  end
end
