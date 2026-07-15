defmodule Nyanform.Session.Manager do
  use GenServer

  @default_max_sessions 64
  @default_idle_ttl_ms 300_000
  @default_cleanup_interval_ms 1_000
  @default_stop_timeout_ms 5_000

  @type create_result :: {:ok, pid(), :created | :existing} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec create(String.t(), keyword()) :: create_result()
  def create(session_id, opts) when is_binary(session_id) and is_list(opts) do
    GenServer.call(__MODULE__, {:create, session_id, opts}, :infinity)
  end

  @spec fetch(String.t()) :: {:ok, pid()} | {:error, :session_not_found}
  def fetch(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:fetch, session_id})
  end

  @spec touch(String.t()) :: :ok | {:error, :session_not_found}
  def touch(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:touch, session_id})
  end

  @spec delete(String.t()) :: :ok | {:error, :session_not_found}
  def delete(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:delete, session_id}, :infinity)
  end

  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  end

  @spec sweep() :: :ok
  def sweep do
    GenServer.call(__MODULE__, :sweep)
  end

  @impl true
  def init(opts) do
    cleanup_interval_ms =
      positive_integer(Keyword.get(opts, :cleanup_interval_ms), @default_cleanup_interval_ms)

    schedule_cleanup(cleanup_interval_ms)
    {:ok, %{sessions: %{}, cleanup_interval_ms: cleanup_interval_ms}}
  end

  @impl true
  def handle_call({:create, session_id, opts}, from, state) do
    state = prune_sessions(state)

    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :active} = entry} ->
        entry = %{entry | last_activity_ms: now_ms()}
        {:reply, {:ok, entry.pid, :existing}, put_entry(state, session_id, entry)}

      {:ok, %{status: :starting} = entry} ->
        entry = %{entry | waiters: [{from, :existing} | entry.waiters]}
        {:noreply, put_entry(state, session_id, entry)}

      {:ok, %{status: :stopping}} ->
        {:reply, {:error, :session_stopping}, state}

      :error ->
        reserve_session(session_id, opts, from, state)
    end
  end

  def handle_call({:fetch, session_id}, _from, state) do
    state = prune_sessions(state)

    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :active} = entry} ->
        entry = %{entry | last_activity_ms: now_ms()}
        {:reply, {:ok, entry.pid}, put_entry(state, session_id, entry)}

      _other ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  def handle_call({:touch, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :active} = entry} ->
        entry = %{entry | last_activity_ms: now_ms()}
        {:reply, :ok, put_entry(state, session_id, entry)}

      _other ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  def handle_call({:delete, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :active} = entry} ->
        {:reply, :ok, put_entry(state, session_id, start_stopping(entry))}

      _other ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  def handle_call(:count, _from, state) do
    state = prune_sessions(state)
    {:reply, map_size(state.sessions), state}
  end

  def handle_call(:sweep, _from, state) do
    {:reply, :ok, prune_sessions(state)}
  end

  @impl true
  def handle_info(:cleanup, state) do
    schedule_cleanup(state.cleanup_interval_ms)
    {:noreply, prune_sessions(state)}
  end

  def handle_info({:start_result, session_id, start_ref, result}, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, %{status: :starting, start_ref: ^start_ref} = entry} ->
        Process.demonitor(entry.worker_monitor, [:flush])
        {:noreply, finish_start(session_id, entry, result, state)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case find_starting_by_monitor(state.sessions, monitor) do
      {session_id, entry} ->
        reply_waiters(entry.waiters, {:error, {:start_failed, reason}})
        {:noreply, delete_entry(state, session_id)}

      nil ->
        handle_stopping_or_session_down(state, monitor)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reserve_session(session_id, opts, from, state) do
    max_sessions = positive_integer(Keyword.get(opts, :max_sessions), @default_max_sessions)

    if map_size(state.sessions) >= max_sessions do
      {:reply, {:error, :too_many_sessions}, state}
    else
      case Keyword.fetch(opts, :start) do
        {:ok, start} when is_function(start, 0) ->
          start_ref = make_ref()
          manager = self()

          {_worker_pid, worker_monitor} =
            spawn_monitor(fn ->
              send(manager, {:start_result, session_id, start_ref, run_start(start)})
            end)

          entry = %{
            status: :starting,
            start_ref: start_ref,
            worker_monitor: worker_monitor,
            waiters: [{from, :created}],
            idle_ttl_ms: positive_integer(Keyword.get(opts, :idle_ttl_ms), @default_idle_ttl_ms),
            stop_timeout_ms:
              positive_integer(Keyword.get(opts, :stop_timeout_ms), @default_stop_timeout_ms)
          }

          {:noreply, put_entry(state, session_id, entry)}

        _other ->
          {:reply, {:error, :invalid_start_callback}, state}
      end
    end
  end

  defp run_start(start) do
    start.()
  catch
    kind, reason -> {:error, {:start_failed, kind, reason}}
  end

  defp finish_start(session_id, entry, result, state) do
    case normalize_start_result(result) do
      {:ok, pid, result_status} ->
        active_entry = %{
          status: :active,
          pid: pid,
          monitor: Process.monitor(pid),
          last_activity_ms: now_ms(),
          idle_ttl_ms: entry.idle_ttl_ms,
          stop_timeout_ms: entry.stop_timeout_ms
        }

        reply_start_success(entry.waiters, pid, result_status)
        put_entry(state, session_id, active_entry)

      {:error, reason} ->
        reply_waiters(entry.waiters, {:error, reason})
        delete_entry(state, session_id)
    end
  end

  defp normalize_start_result({:ok, pid}) when is_pid(pid), do: {:ok, pid, :created}

  defp normalize_start_result({:error, {:already_started, pid}}) when is_pid(pid),
    do: {:ok, pid, :existing}

  defp normalize_start_result({:error, reason}), do: {:error, reason}
  defp normalize_start_result(other), do: {:error, {:invalid_start_result, other}}

  defp reply_start_success(waiters, pid, result_status) do
    Enum.each(waiters, fn {from, waiter_status} ->
      status = if result_status == :existing, do: :existing, else: waiter_status
      GenServer.reply(from, {:ok, pid, status})
    end)
  end

  defp reply_waiters(waiters, reply) do
    Enum.each(waiters, fn {from, _status} -> GenServer.reply(from, reply) end)
  end

  defp find_starting_by_monitor(sessions, monitor) do
    Enum.find(sessions, fn {_session_id, entry} ->
      entry.status == :starting and entry.worker_monitor == monitor
    end)
  end

  defp handle_stopping_or_session_down(state, monitor) do
    case find_stopping_by_monitor(state.sessions, monitor) do
      {session_id, entry} ->
        if Process.alive?(entry.pid), do: Process.exit(entry.pid, :kill)
        entry = %{entry | stop_worker_monitor: nil}
        {:noreply, put_entry(state, session_id, entry)}

      nil ->
        sessions =
          Map.reject(state.sessions, fn {_session_id, entry} ->
            Map.get(entry, :monitor) == monitor
          end)

        {:noreply, %{state | sessions: sessions}}
    end
  end

  defp find_stopping_by_monitor(sessions, monitor) do
    Enum.find(sessions, fn {_session_id, entry} ->
      entry.status == :stopping and entry.stop_worker_monitor == monitor
    end)
  end

  defp prune_sessions(state) do
    now = now_ms()

    sessions = Enum.reduce(state.sessions, %{}, &prune_entry(&1, &2, now))

    %{state | sessions: sessions}
  end

  defp prune_entry({session_id, %{status: :starting} = entry}, kept, _now) do
    Map.put(kept, session_id, entry)
  end

  defp prune_entry({session_id, %{status: :active} = entry}, kept, now) do
    cond do
      not Process.alive?(entry.pid) ->
        Process.demonitor(entry.monitor, [:flush])
        kept

      now - entry.last_activity_ms >= entry.idle_ttl_ms ->
        Map.put(kept, session_id, start_stopping(entry))

      true ->
        Map.put(kept, session_id, entry)
    end
  end

  defp prune_entry({session_id, %{status: :stopping} = entry}, kept, _now) do
    if Process.alive?(entry.pid) do
      Map.put(kept, session_id, entry)
    else
      Process.demonitor(entry.monitor, [:flush])
      kept
    end
  end

  defp start_stopping(entry) do
    {_worker_pid, worker_monitor} =
      spawn_monitor(fn -> stop_process(entry.pid, entry.stop_timeout_ms) end)

    entry
    |> Map.put(:status, :stopping)
    |> Map.put(:stop_worker_monitor, worker_monitor)
  end

  defp stop_process(pid, timeout_ms) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, timeout_ms)

    :ok
  catch
    :exit, _reason ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :ok
  end

  defp put_entry(state, session_id, entry) do
    %{state | sessions: Map.put(state.sessions, session_id, entry)}
  end

  defp delete_entry(state, session_id) do
    %{state | sessions: Map.delete(state.sessions, session_id)}
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp schedule_cleanup(interval_ms), do: Process.send_after(self(), :cleanup, interval_ms)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
