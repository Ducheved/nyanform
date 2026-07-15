defmodule Nyanform.Session.ThreadTest do
  use ExUnit.Case, async: true

  alias Nyanform.Protocol.{ErrorCodes, Message}
  alias Nyanform.Session.Thread

  test "keeps only the newest messages within the configured queue bound" do
    first = Message.notification("first")
    second = Message.notification("second")
    third = Message.notification("third")

    state =
      Enum.reduce([first, second, third], queue_state(2), fn message, state ->
        assert {:noreply, next_state} = Thread.handle_info({:upstream_message, message}, state)
        next_state
      end)

    assert state.pending_upstream_count == 2

    assert {:reply, [^second, ^third], drained} =
             Thread.handle_call(:drain_upstream, self(), state)

    assert drained.pending_upstream_count == 0
    assert :queue.is_empty(drained.pending_upstream)
  end

  test "flushes backlog and pushes new upstream messages to a subscriber" do
    queued = Message.notification("queued")
    pushed = Message.notification("pushed")
    {:noreply, state} = Thread.handle_info({:upstream_message, queued}, queue_state(2))

    assert {:reply, :ok, subscribed} =
             Thread.handle_call({:subscribe_upstream, self()}, self(), state)

    assert_receive {:nyanform_upstream, ^queued}
    assert subscribed.pending_upstream_count == 0
    assert :queue.is_empty(subscribed.pending_upstream)

    assert {:noreply, subscribed} =
             Thread.handle_info({:upstream_message, pushed}, subscribed)

    assert_receive {:nyanform_upstream, ^pushed}
    assert :queue.is_empty(subscribed.pending_upstream)

    assert {:reply, :ok, unsubscribed} =
             Thread.handle_call({:unsubscribe_upstream, self()}, self(), subscribed)

    assert unsubscribed.upstream_subscriber == nil
  end

  test "returns to bounded queueing when the subscriber exits" do
    subscriber = spawn(fn -> Process.sleep(:infinity) end)

    assert {:reply, :ok, subscribed} =
             Thread.handle_call({:subscribe_upstream, subscriber}, self(), queue_state(1))

    {_subscriber, monitor} = subscribed.upstream_subscriber
    Process.exit(subscriber, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, :killed} = down
    assert {:noreply, unsubscribed} = Thread.handle_info(down, subscribed)
    assert unsubscribed.upstream_subscriber == nil

    message = Message.notification("after-down")
    assert {:noreply, queued} = Thread.handle_info({:upstream_message, message}, unsubscribed)
    assert queued.pending_upstream_count == 1
    assert :queue.to_list(queued.pending_upstream) == [message]
  end

  test "restores an unacknowledged SSE delivery when its owner exits" do
    first = Message.notification("first")
    second = Message.notification("second")
    owner = spawn(fn -> Process.sleep(:infinity) end)
    lease_ref = make_ref()

    state =
      Enum.reduce([first, second], queue_state(2), fn message, state ->
        {:noreply, state} = Thread.handle_info({:upstream_message, message}, state)
        state
      end)

    assert {:reply, {:ok, ^lease_ref, [^first, ^second]}, leased} =
             Thread.handle_call({:lease_upstream, owner, lease_ref, 100}, self(), state)

    {^owner, monitor, ^lease_ref, [^first, ^second]} = leased.upstream_delivery
    assert :queue.is_empty(leased.pending_upstream)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed} = down
    assert {:noreply, restored} = Thread.handle_info(down, leased)
    assert restored.upstream_delivery == nil
    assert restored.pending_upstream_count == 2
    assert :queue.to_list(restored.pending_upstream) == [first, second]
  end

  test "cancel restores a fulfilled delivery to the bounded queue" do
    first = Message.notification("first")
    second = Message.notification("second")
    third = Message.notification("third")
    lease_ref = make_ref()
    {:noreply, state} = Thread.handle_info({:upstream_message, first}, queue_state(2))

    assert {:reply, {:ok, ^lease_ref, [^first]}, leased} =
             Thread.handle_call({:lease_upstream, self(), lease_ref, 100}, self(), state)

    {:noreply, leased} = Thread.handle_info({:upstream_message, second}, leased)
    {:noreply, leased} = Thread.handle_info({:upstream_message, third}, leased)

    assert {:noreply, restored} =
             Thread.handle_cast({:cancel_upstream_lease, self(), lease_ref}, leased)

    assert restored.upstream_delivery == nil
    assert restored.pending_upstream_count == 2
    assert :queue.to_list(restored.pending_upstream) == [second, third]
  end

  test "validates initialize params exactly" do
    assert Thread.valid_initialize_params?(%{
             "protocolVersion" => "2025-11-25",
             "capabilities" => %{},
             "clientInfo" => %{"name" => "client", "version" => "1.0"}
           })

    refute Thread.valid_initialize_params?(%{})

    refute Thread.valid_initialize_params?(%{
             "protocolVersion" => "2025-11-25",
             "capabilities" => %{},
             "clientInfo" => %{"name" => "client", "version" => 1}
           })

    refute Thread.valid_initialize_params?(%{
             "protocolVersion" => "",
             "capabilities" => %{},
             "clientInfo" => %{"name" => "client", "version" => "1.0"}
           })

    refute Thread.valid_initialize_params?([])
  end

  test "validates tools call params exactly" do
    assert Thread.valid_tools_call_params?(%{"name" => "tool"})
    assert Thread.valid_tools_call_params?(%{"name" => "tool", "arguments" => %{}})
    refute Thread.valid_tools_call_params?(%{"name" => ""})
    refute Thread.valid_tools_call_params?(%{"name" => "  "})
    refute Thread.valid_tools_call_params?(%{"name" => "tool", "arguments" => []})
    refute Thread.valid_tools_call_params?(%{"name" => "tool", "arguments" => nil})
    refute Thread.valid_tools_call_params?([])
  end

  test "returns invalid params without mutating the session" do
    state = queue_state(2)
    initialize = Message.request(1, "initialize", [])
    tools_call = Message.request(2, "tools/call", %{"name" => "tool", "arguments" => []})

    assert {:reply, {:reply, initialize_error}, ^state} =
             Thread.handle_call({:downstream, initialize}, self(), state)

    assert initialize_error.error.code == ErrorCodes.invalid_params()

    assert {:reply, {:reply, tools_error}, ^state} =
             Thread.handle_call({:downstream, tools_call}, self(), state)

    assert tools_error.error.code == ErrorCodes.invalid_params()
  end

  test "touch updates activity without changing queue state" do
    state = %{queue_state(2) | last_activity_ms: System.monotonic_time(:millisecond) - 1_000}
    assert {:noreply, touched} = Thread.handle_cast(:touch, state)
    assert touched.last_activity_ms > state.last_activity_ms
    assert touched.pending_upstream == state.pending_upstream
    assert touched.pending_upstream_count == state.pending_upstream_count
  end

  defp queue_state(max_pending_upstream) do
    %{
      pending_upstream: :queue.new(),
      pending_upstream_count: 0,
      max_pending_upstream: max_pending_upstream,
      upstream_subscriber: nil,
      upstream_waiter: nil,
      upstream_delivery: nil,
      last_activity_ms: System.monotonic_time(:millisecond)
    }
  end
end
