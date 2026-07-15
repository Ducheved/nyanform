defmodule Nyanform.Session.ManagerSlowStopServer do
  use GenServer

  def start(test_pid), do: GenServer.start(__MODULE__, test_pid)

  @impl true
  def init(test_pid), do: {:ok, test_pid}

  @impl true
  def terminate(_reason, test_pid) do
    send(test_pid, {:slow_stop_entered, self()})

    receive do
      :finish_stop -> :ok
    end
  end
end

defmodule Nyanform.Session.ManagerTest do
  use ExUnit.Case, async: false

  alias Nyanform.Session.Manager
  alias Nyanform.Session.ManagerSlowStopServer

  test "serializes creation and enforces the configured session cap" do
    baseline = Manager.count()
    prefix = unique_id("cap")

    results =
      1..8
      |> Task.async_stream(
        fn index ->
          Manager.create("#{prefix}-#{index}",
            max_sessions: baseline + 1,
            idle_ttl_ms: 5_000,
            start: &start_agent/0
          )
        end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    created = Enum.filter(results, &match?({:ok, _pid, :created}, &1))
    rejected = Enum.filter(results, &(&1 == {:error, :too_many_sessions}))

    assert length(created) == 1
    assert length(rejected) == 7

    for index <- 1..8 do
      Manager.delete("#{prefix}-#{index}")
    end

    for {:ok, pid, :created} <- created do
      assert_eventually(fn -> not Process.alive?(pid) end)
    end

    assert_eventually(fn -> Manager.count() == baseline end)
  end

  test "expires idle sessions and stops their processes" do
    session_id = unique_id("ttl")

    assert {:ok, pid, :created} =
             Manager.create(session_id,
               max_sessions: Manager.count() + 1,
               idle_ttl_ms: 10,
               start: &start_agent/0
             )

    expire_session(session_id)
    assert :ok = Manager.sweep()
    assert {:error, :session_not_found} = Manager.fetch(session_id)
    assert_eventually(fn -> not Process.alive?(pid) end)
  end

  test "removes sessions when their monitored process exits" do
    session_id = unique_id("down")

    assert {:ok, pid, :created} =
             Manager.create(session_id,
               max_sessions: Manager.count() + 1,
               idle_ttl_ms: 5_000,
               start: &start_agent/0
             )

    Agent.stop(pid)
    assert_eventually(fn -> Manager.fetch(session_id) == {:error, :session_not_found} end)
  end

  test "slow starts reserve capacity without blocking other manager calls" do
    baseline = Manager.count()
    existing_id = unique_id("existing")
    slow_id = unique_id("slow-start")
    blocked_id = unique_id("blocked")
    test_pid = self()

    assert {:ok, existing_pid, :created} =
             Manager.create(existing_id,
               max_sessions: baseline + 2,
               idle_ttl_ms: 5_000,
               start: &start_agent/0
             )

    create_task =
      Task.async(fn ->
        Manager.create(slow_id,
          max_sessions: baseline + 2,
          idle_ttl_ms: 5_000,
          start: fn ->
            send(test_pid, {:slow_start_entered, self()})

            receive do
              :finish_start -> start_agent()
            end
          end
        )
      end)

    assert_receive {:slow_start_entered, starter}, 500

    operations_task =
      Task.async(fn ->
        {
          Manager.fetch(existing_id),
          Manager.touch(existing_id),
          Manager.count(),
          Manager.create(blocked_id,
            max_sessions: baseline + 2,
            idle_ttl_ms: 5_000,
            start: &start_agent/0
          ),
          Manager.delete(existing_id)
        }
      end)

    assert {
             {:ok, ^existing_pid},
             :ok,
             expected_count,
             {:error, :too_many_sessions},
             :ok
           } = Task.await(operations_task, 1_000)

    assert expected_count == baseline + 2

    send(starter, :finish_start)
    assert {:ok, slow_pid, :created} = Task.await(create_task, 1_000)
    assert :ok = Manager.delete(slow_id)
    assert_eventually(fn -> not Process.alive?(existing_pid) end)
    assert_eventually(fn -> not Process.alive?(slow_pid) end)
    assert_eventually(fn -> Manager.count() == baseline end)
  end

  test "concurrent creates for one id run the start callback once" do
    baseline = Manager.count()
    session_id = unique_id("same-id")
    test_pid = self()

    first =
      Task.async(fn ->
        Manager.create(session_id,
          max_sessions: baseline + 1,
          idle_ttl_ms: 5_000,
          start: fn ->
            send(test_pid, {:same_start_entered, self()})

            receive do
              :finish_start -> start_agent()
            end
          end
        )
      end)

    assert_receive {:same_start_entered, starter}, 500

    second =
      Task.async(fn ->
        Manager.create(session_id,
          max_sessions: baseline + 1,
          idle_ttl_ms: 5_000,
          start: fn -> send(test_pid, :unexpected_second_start) end
        )
      end)

    assert_eventually(fn -> starting_waiter_count(session_id) == 2 end)
    send(starter, :finish_start)

    assert {:ok, pid, :created} = Task.await(first, 1_000)
    assert {:ok, ^pid, :existing} = Task.await(second, 1_000)
    refute_receive :unexpected_second_start, 50

    assert :ok = Manager.delete(session_id)
    assert_eventually(fn -> not Process.alive?(pid) end)
    assert Manager.count() <= baseline
    refute Map.has_key?(:sys.get_state(Manager).sessions, session_id)
  end

  test "a crashing start callback frees its reservation without crashing manager" do
    baseline = Manager.count()
    manager_pid = Process.whereis(Manager)
    session_id = unique_id("start-crash")

    assert {:error, {:start_failed, :exit, :boom}} =
             Manager.create(session_id,
               max_sessions: baseline + 1,
               idle_ttl_ms: 5_000,
               start: fn -> exit(:boom) end
             )

    assert Process.whereis(Manager) == manager_pid
    assert Manager.count() == baseline

    assert {:ok, pid, :created} =
             Manager.create(session_id,
               max_sessions: baseline + 1,
               idle_ttl_ms: 5_000,
               start: &start_agent/0
             )

    assert :ok = Manager.delete(session_id)
    assert_eventually(fn -> not Process.alive?(pid) end)
    assert_eventually(fn -> Manager.count() == baseline end)
  end

  test "delete returns while a live session is still stopping" do
    baseline = Manager.count()
    session_id = unique_id("slow-delete")
    test_pid = self()

    assert {:ok, pid, :created} =
             Manager.create(session_id,
               max_sessions: baseline + 1,
               idle_ttl_ms: 5_000,
               start: fn -> ManagerSlowStopServer.start(test_pid) end
             )

    delete_task = Task.async(fn -> Manager.delete(session_id) end)

    assert :ok = Task.await(delete_task, 1_000)
    assert_receive {:slow_stop_entered, ^pid}, 500
    assert Process.alive?(pid)
    assert Manager.count() == baseline + 1
    assert {:error, :session_not_found} = Manager.fetch(session_id)

    send(pid, :finish_stop)
    assert_eventually(fn -> not Process.alive?(pid) end)
    assert_eventually(fn -> Manager.count() == baseline end)
  end

  test "cleanup retains an expired live session until it really stops" do
    baseline = Manager.count()
    session_id = unique_id("slow-cleanup")
    blocked_id = unique_id("cleanup-cap")
    test_pid = self()

    assert {:ok, pid, :created} =
             Manager.create(session_id,
               max_sessions: baseline + 1,
               idle_ttl_ms: 5,
               start: fn -> ManagerSlowStopServer.start(test_pid) end
             )

    expire_session(session_id)
    assert :ok = Manager.sweep()
    assert_receive {:slow_stop_entered, ^pid}, 500
    assert Process.alive?(pid)
    assert Manager.count() == baseline + 1

    assert {:error, :too_many_sessions} =
             Manager.create(blocked_id,
               max_sessions: baseline + 1,
               idle_ttl_ms: 5_000,
               start: &start_agent/0
             )

    send(pid, :finish_stop)
    assert_eventually(fn -> not Process.alive?(pid) end)
    assert_eventually(fn -> Manager.count() == baseline end)
  end

  test "a stop timeout forces termination without releasing capacity early" do
    baseline = Manager.count()
    session_id = unique_id("stop-timeout")
    test_pid = self()

    assert {:ok, pid, :created} =
             Manager.create(session_id,
               max_sessions: baseline + 1,
               idle_ttl_ms: 5_000,
               stop_timeout_ms: 20,
               start: fn -> ManagerSlowStopServer.start(test_pid) end
             )

    assert :ok = Manager.delete(session_id)
    assert_receive {:slow_stop_entered, ^pid}, 500
    assert Process.alive?(pid)
    assert Manager.count() == baseline + 1
    assert_eventually(fn -> not Process.alive?(pid) end)
    assert_eventually(fn -> Manager.count() == baseline end)
  end

  defp start_agent, do: Agent.start(fn -> %{} end)

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp starting_waiter_count(session_id) do
    case :sys.get_state(Manager).sessions[session_id] do
      %{status: :starting, waiters: waiters} -> length(waiters)
      _other -> 0
    end
  end

  defp expire_session(session_id) do
    :sys.replace_state(Manager, fn state ->
      entry = Map.fetch!(state.sessions, session_id)
      last_activity_ms = entry.last_activity_ms - entry.idle_ttl_ms - 1
      entry = %{entry | last_activity_ms: last_activity_ms}
      %{state | sessions: Map.put(state.sessions, session_id, entry)}
    end)

    :ok
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
