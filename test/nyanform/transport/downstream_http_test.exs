defmodule Nyanform.Transport.DownstreamHttpFakeSession do
  use GenServer

  alias Nyanform.Protocol.Message

  def start(session_id, opts \\ []) do
    GenServer.start(
      __MODULE__,
      %{
        session_id: session_id,
        pending: [],
        subscriber: nil,
        delivery: nil,
        waiter: nil,
        request_delay_ms: Keyword.get(opts, :request_delay_ms, 0)
      },
      name: {:via, Registry, {Nyanform.Session.Registry, session_id}}
    )
  end

  def enqueue(pid, message), do: GenServer.call(pid, {:enqueue, message})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(
        {:downstream, %Message{kind: :request, method: "initialize"} = message},
        _from,
        state
      ) do
    {:reply, {:reply, Message.response(message.id, %{"initialized" => true})}, state}
  end

  def handle_call({:downstream, %Message{kind: :request} = message}, _from, state) do
    Process.sleep(state.request_delay_ms)
    {:reply, {:reply, Message.response(message.id, %{"ok" => true})}, state}
  end

  def handle_call({:downstream, %Message{kind: :notification}}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:subscribe_upstream, subscriber}, _from, state) do
    Enum.each(state.pending, &send(subscriber, {:nyanform_upstream, &1}))
    {:reply, :ok, %{state | pending: [], subscriber: subscriber}}
  end

  def handle_call({:unsubscribe_upstream, subscriber}, _from, state) do
    state = if state.subscriber == subscriber, do: %{state | subscriber: nil}, else: state
    {:reply, :ok, state}
  end

  def handle_call({:lease_upstream, owner, lease_ref, wait_ms}, from, state) do
    case state.pending do
      [] when wait_ms > 0 ->
        timer = Process.send_after(self(), {:lease_timeout, lease_ref}, wait_ms)
        {:noreply, %{state | waiter: {from, lease_ref, timer}}}

      [] ->
        {:reply, {:ok, nil, []}, state}

      messages ->
        {:reply, {:ok, lease_ref, messages},
         %{state | pending: [], delivery: {owner, lease_ref, messages}}}
    end
  end

  def handle_call({:ack_upstream, owner, lease_ref}, _from, state) do
    state =
      case state.delivery do
        {^owner, ^lease_ref, _messages} -> %{state | delivery: nil}
        _other -> state
      end

    {:reply, :ok, state}
  end

  def handle_call({:enqueue, message}, _from, %{subscriber: nil} = state) do
    {:reply, :ok, %{state | pending: state.pending ++ [message]}}
  end

  def handle_call({:enqueue, message}, _from, state) do
    send(state.subscriber, {:nyanform_upstream, message})
    {:reply, :ok, state}
  end

  def handle_call(:drain_upstream, _from, state) do
    {:reply, state.pending, %{state | pending: []}}
  end

  @impl true
  def handle_info({:lease_timeout, lease_ref}, state) do
    case state.waiter do
      {from, ^lease_ref, _timer} ->
        GenServer.reply(from, {:ok, nil, []})
        {:noreply, %{state | waiter: nil}}

      _other ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:touch, state), do: {:noreply, state}
end

defmodule Nyanform.Transport.DownstreamHttpTest do
  use ExUnit.Case, async: false

  alias Nyanform.Protocol.Message
  alias Nyanform.Session.Manager

  alias Nyanform.Transport.{
    DownstreamHttp,
    DownstreamHttpFakeSession,
    HttpPlug
  }

  import Plug.Conn
  import Plug.Test

  @request Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}})

  test "allows requests without Origin on a non-loopback bind" do
    conn = call(@request, bind_host: "0.0.0.0")
    assert conn.status == 400
  end

  test "allows loopback Origin with an empty allowlist on a loopback bind" do
    conn = call(@request, bind_host: "127.0.0.1", origin: "http://localhost:3000")
    assert conn.status == 400
  end

  test "rejects Origin with an empty allowlist on a non-loopback bind" do
    conn = call(@request, bind_host: "0.0.0.0", origin: "http://localhost:3000")
    assert conn.status == 403
  end

  test "rejects non-loopback Origin with the loopback default" do
    conn = call(@request, bind_host: "127.0.0.1", origin: "https://client.example")
    assert conn.status == 403
  end

  test "uses an explicit Origin allowlist on any bind" do
    conn =
      call(@request,
        bind_host: "0.0.0.0",
        origin: "https://client.example",
        allowed_origins: ["https://client.example"]
      )

    assert conn.status == 400
  end

  test "rejects a body above the HTTP body limit" do
    conn = call(@request, max_http_body_size: 1)
    assert conn.status == 413
  end

  test "rejects a JSON-RPC message above the message limit" do
    conn = call(@request, max_http_body_size: 1024, max_message_size: 1)
    assert conn.status == 413
  end

  test "routes unsupported methods before reading the body" do
    conn = request(:put, String.duplicate("x", 128), max_http_body_size: 1)
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST, GET, DELETE"]
  end

  test "returns invalid host instead of silently binding loopback" do
    assert {:error, {:invalid_host, "not-a-host"}} =
             DownstreamHttp.run(nil, "canonical", :strict, host: "not-a-host")
  end

  test "only a valid headerless initialize creates a session" do
    baseline = Manager.count()
    invalid = request(:post, initialize_body(%{}))
    assert invalid.status == 400
    assert Manager.count() == baseline

    non_initialize = request(:post, @request)
    assert non_initialize.status == 400
    assert Manager.count() == baseline

    initialized = request(:post, initialize_body(valid_initialize_params()))
    assert initialized.status == 200
    [session_id] = get_resp_header(initialized, "mcp-session-id")
    assert {:ok, _pid} = Manager.fetch(session_id)
    assert Manager.count() == baseline + 1
    Manager.delete(session_id)

    unknown =
      request(:post, initialize_body(valid_initialize_params()), session_id: "unknown-session")

    assert unknown.status == 404
    assert Registry.lookup(Nyanform.Session.Registry, "unknown-session") == []
  end

  test "returns 404 for unknown sessions and 204 for a valid DELETE" do
    assert request(:post, @request, session_id: "missing").status == 404
    assert request(:get, "", session_id: "missing").status == 404
    assert request(:delete, "", session_id: "missing").status == 404

    initialized = request(:post, initialize_body(valid_initialize_params()))
    [session_id] = get_resp_header(initialized, "mcp-session-id")

    deleted = request(:delete, "", session_id: session_id)
    assert deleted.status == 204
    assert deleted.resp_body == ""
    assert {:error, :session_not_found} = Manager.fetch(session_id)
    assert request(:delete, "", session_id: session_id).status == 404
  end

  test "POST returns JSON replies or 202 without draining queued messages" do
    initialized = request(:post, initialize_body(valid_initialize_params()))
    [session_id] = get_resp_header(initialized, "mcp-session-id")

    response = request(:post, @request, session_id: session_id)
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["application/json"]
    assert Jason.decode!(response.resp_body)["result"] == %{"ok" => true}

    notification = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    accepted = request(:post, notification, session_id: session_id)
    assert accepted.status == 202
    assert accepted.resp_body == ""
    Manager.delete(session_id)
  end

  test "returns a controlled timeout without deleting a live session" do
    start = fn session_id ->
      DownstreamHttpFakeSession.start(session_id, request_delay_ms: 250)
    end

    initialized =
      request(:post, initialize_body(valid_initialize_params()),
        session_start: start,
        request_timeout_ms: 10
      )

    [session_id] = get_resp_header(initialized, "mcp-session-id")
    {:ok, pid} = Manager.fetch(session_id)

    started = System.monotonic_time(:millisecond)

    timed_out =
      request(:post, @request,
        session_id: session_id,
        request_timeout_ms: 10
      )

    elapsed = System.monotonic_time(:millisecond) - started

    assert timed_out.status == 504
    assert Jason.decode!(timed_out.resp_body)["error"]["code"] == -32_603
    assert elapsed < 500
    assert {:ok, ^pid} = Manager.fetch(session_id)
    assert Process.alive?(pid)
    Manager.delete(session_id)
  end

  test "GET drains queued messages as bounded SSE" do
    initialized = request(:post, initialize_body(valid_initialize_params()))
    [session_id] = get_resp_header(initialized, "mcp-session-id")
    {:ok, pid} = Manager.fetch(session_id)
    first = Message.notification("notifications/first", %{"value" => 1})
    second = Message.notification("notifications/second", %{"value" => 2})
    :ok = DownstreamHttpFakeSession.enqueue(pid, first)
    :ok = DownstreamHttpFakeSession.enqueue(pid, second)

    streamed = request(:get, "", session_id: session_id, sse_wait_ms: 5)
    assert streamed.status == 200
    assert get_resp_header(streamed, "content-type") == ["text/event-stream"]
    assert streamed.resp_body == sse_frame(first) <> sse_frame(second)

    started = System.monotonic_time(:millisecond)
    empty = request(:get, "", session_id: session_id, sse_wait_ms: 10)
    elapsed = System.monotonic_time(:millisecond) - started
    assert empty.status == 200
    assert empty.resp_body == ""
    assert elapsed < 250
    Manager.delete(session_id)
  end

  test "returns 429 when the race-safe manager cap is full" do
    baseline = Manager.count()
    occupied_id = "occupied-#{System.unique_integer([:positive, :monotonic])}"

    assert {:ok, _pid, :created} =
             Manager.create(occupied_id,
               max_sessions: baseline + 1,
               idle_ttl_ms: 5_000,
               start: fn -> DownstreamHttpFakeSession.start(occupied_id) end
             )

    limited =
      request(:post, initialize_body(valid_initialize_params()), max_sessions: baseline + 1)

    assert limited.status == 429
    assert get_resp_header(limited, "retry-after") == ["1"]
    Manager.delete(occupied_id)
  end

  test "expired HTTP sessions are cleaned up and become unknown" do
    initialized =
      request(:post, initialize_body(valid_initialize_params()), session_idle_ttl_ms: 10)

    [session_id] = get_resp_header(initialized, "mcp-session-id")
    {:ok, pid} = Manager.fetch(session_id)
    Process.sleep(20)
    assert :ok = Manager.sweep()
    assert request(:get, "", session_id: session_id).status == 404
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 500
  end

  defp call(body, options) do
    request(:post, body, options)
  end

  defp request(method, body, options \\ []) do
    {origin, options} = Keyword.pop(options, :origin)
    {session_id, options} = Keyword.pop(options, :session_id)

    conn =
      method
      |> conn("/", body)
      |> maybe_put_origin(origin)
      |> maybe_put_session_id(session_id)

    opts =
      HttpPlug.init(
        Keyword.merge(
          [
            upstream_config: nil,
            profile: "canonical",
            policy: :strict,
            bind_host: "127.0.0.1",
            allowed_origins: [],
            max_http_body_size: 1024,
            max_message_size: 1024,
            max_sessions: 64,
            session_idle_ttl_ms: 5_000,
            max_pending_upstream: 4,
            sse_wait_ms: 5,
            request_timeout_ms: 30_000,
            session_start: &DownstreamHttpFakeSession.start/1
          ],
          options
        )
      )

    HttpPlug.call(conn, opts)
  end

  defp maybe_put_origin(conn, nil), do: conn
  defp maybe_put_origin(conn, origin), do: put_req_header(conn, "origin", origin)

  defp maybe_put_session_id(conn, nil), do: conn

  defp maybe_put_session_id(conn, session_id),
    do: put_req_header(conn, "mcp-session-id", session_id)

  defp valid_initialize_params do
    %{
      "protocolVersion" => "2025-11-25",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "test", "version" => "1.0"}
    }
  end

  defp initialize_body(params) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => params})
  end

  defp sse_frame(message), do: "event: message\ndata: #{Message.encode!(message)}\n\n"
end
