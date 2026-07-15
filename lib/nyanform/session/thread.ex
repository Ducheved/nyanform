defmodule Nyanform.Session.Thread do
  use GenServer

  @downstream_call_grace_ms 100
  @upstream_lease_call_grace_ms 1_000

  alias Nyanform.ClientFamiliar
  alias Nyanform.Profile.{Builtins, Projector}
  alias Nyanform.Protocol.{ErrorCodes, Lifecycle, Message}
  alias Nyanform.RewriteTalisman
  alias Nyanform.Schema.Pipeline
  alias Nyanform.ToolGrimoire
  alias Nyanform.Transport.UpstreamShrine

  @type session_state :: %{
          session_id: String.t(),
          upstream_pid: pid(),
          profile: String.t(),
          policy: atom(),
          constellation: Nyanform.Profile.Constellation.t(),
          grimoire: Nyanform.ToolGrimoire.grimoire() | nil,
          tool_include: [String.t()] | nil,
          tool_exclude: [String.t()] | nil,
          downstream_initialized: boolean(),
          downstream_info: map() | nil,
          upstream_info: map() | nil,
          upstream_capabilities: map() | nil,
          protocol_revision: String.t() | nil,
          pending_upstream: :queue.queue(Message.t()),
          pending_upstream_count: non_neg_integer(),
          max_pending_upstream: pos_integer(),
          upstream_subscriber: {pid(), reference()} | nil,
          upstream_waiter: {pid(), reference(), GenServer.from(), reference(), reference()} | nil,
          upstream_delivery: {pid(), reference(), reference(), [Message.t()]} | nil,
          last_activity_ms: integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:session_id]))
  end

  defp via_tuple(session_id) do
    {:via, Registry, {Nyanform.Session.Registry, session_id}}
  end

  @spec initialize(
          String.t(),
          Nyanform.Transport.UpstreamShrine.transport_config(),
          String.t(),
          atom()
        ) ::
          {:ok, pid()} | {:error, term()}
  def initialize(
        session_id,
        upstream_config,
        profile,
        policy,
        tool_filters \\ %{include: nil, exclude: nil},
        session_opts \\ []
      ) do
    opts = [
      session_id: session_id,
      upstream_config: upstream_config,
      profile: profile,
      policy: policy,
      tool_include: Map.get(tool_filters, :include),
      tool_exclude: Map.get(tool_filters, :exclude),
      max_pending_upstream: Keyword.get(session_opts, :max_pending_upstream, 128)
    ]

    DynamicSupervisor.start_child(Nyanform.Session.Supervisor, %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    })
  end

  @spec handle_downstream(String.t(), Message.t(), pos_integer()) ::
          :ok | {:reply, Message.t()} | {:error, term()}
  def handle_downstream(session_id, %Message{} = message, request_timeout_ms \\ default_timeout()) do
    case Registry.lookup(Nyanform.Session.Registry, session_id) do
      [{pid, _}] ->
        GenServer.cast(pid, :touch)

        try do
          GenServer.call(
            pid,
            {:downstream, message},
            normalize_timeout(request_timeout_ms) + @downstream_call_grace_ms
          )
        catch
          :exit, {:timeout, _reason} -> {:error, :session_timeout}
          :exit, {:noproc, _reason} -> {:error, :session_not_found}
          :exit, reason -> {:error, {:session_exit, reason}}
        end

      [] ->
        {:error, :session_not_found}
    end
  end

  @spec lease_upstream_messages(String.t(), pid(), non_neg_integer()) ::
          {:ok, reference() | nil, [Message.t()]} | {:error, term()}
  def lease_upstream_messages(session_id, wait_ms) do
    lease_upstream_messages(session_id, self(), wait_ms)
  end

  def lease_upstream_messages(session_id, owner, wait_ms)
      when is_pid(owner) and is_integer(wait_ms) and wait_ms >= 0 do
    lease_ref = make_ref()

    case Registry.lookup(Nyanform.Session.Registry, session_id) do
      [{pid, _}] ->
        try do
          GenServer.call(
            pid,
            {:lease_upstream, owner, lease_ref, wait_ms},
            wait_ms + @upstream_lease_call_grace_ms
          )
        catch
          :exit, {:timeout, _reason} ->
            GenServer.cast(pid, {:cancel_upstream_lease, owner, lease_ref})
            {:error, :delivery_timeout}

          :exit, {:noproc, _reason} ->
            {:error, :session_not_found}

          :exit, reason ->
            {:error, {:session_exit, reason}}
        end

      [] ->
        {:error, :session_not_found}
    end
  end

  @spec ack_upstream_messages(String.t(), pid(), reference()) :: :ok | {:error, term()}
  def ack_upstream_messages(session_id, lease_ref) do
    ack_upstream_messages(session_id, self(), lease_ref)
  end

  def ack_upstream_messages(session_id, owner, lease_ref)
      when is_pid(owner) and is_reference(lease_ref) do
    case Registry.lookup(Nyanform.Session.Registry, session_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:ack_upstream, owner, lease_ref}, 5_000)
        catch
          :exit, {:noproc, _reason} -> {:error, :session_not_found}
          :exit, reason -> {:error, {:session_exit, reason}}
        end

      [] ->
        {:error, :session_not_found}
    end
  end

  @spec subscribe_upstream(String.t(), pid()) :: :ok | {:error, :session_not_found}
  def subscribe_upstream(session_id, subscriber \\ self()) when is_pid(subscriber) do
    case Registry.lookup(Nyanform.Session.Registry, session_id) do
      [{pid, _}] -> GenServer.call(pid, {:subscribe_upstream, subscriber}, 5_000)
      [] -> {:error, :session_not_found}
    end
  end

  @spec unsubscribe_upstream(String.t(), pid()) :: :ok | {:error, :session_not_found}
  def unsubscribe_upstream(session_id, subscriber \\ self()) when is_pid(subscriber) do
    case Registry.lookup(Nyanform.Session.Registry, session_id) do
      [{pid, _}] -> GenServer.call(pid, {:unsubscribe_upstream, subscriber}, 5_000)
      [] -> {:error, :session_not_found}
    end
  end

  @spec touch(String.t()) :: :ok | {:error, :session_not_found}
  def touch(session_id) do
    case Registry.lookup(Nyanform.Session.Registry, session_id) do
      [{pid, _}] -> GenServer.cast(pid, :touch)
      [] -> {:error, :session_not_found}
    end
  end

  @spec last_activity(String.t()) :: {:ok, integer()} | {:error, :session_not_found}
  def last_activity(session_id) do
    case Registry.lookup(Nyanform.Session.Registry, session_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :last_activity, 5_000)}
      [] -> {:error, :session_not_found}
    end
  end

  @spec valid_initialize_params?(term()) :: boolean()
  def valid_initialize_params?(%{
        "protocolVersion" => protocol_version,
        "capabilities" => capabilities,
        "clientInfo" => client_info
      })
      when is_binary(protocol_version) and is_map(capabilities) and is_map(client_info) do
    non_empty_string?(protocol_version) and valid_client_info?(client_info)
  end

  def valid_initialize_params?(_params), do: false

  @spec valid_tools_call_params?(term()) :: boolean()
  def valid_tools_call_params?(%{"name" => name} = params) when is_binary(name) do
    non_empty_string?(name) and valid_arguments?(Map.fetch(params, "arguments"))
  end

  def valid_tools_call_params?(_params), do: false

  @spec drain_upstream_messages(String.t()) :: [Message.t()]
  def drain_upstream_messages(session_id) do
    case Registry.lookup(Nyanform.Session.Registry, session_id) do
      [{pid, _}] ->
        GenServer.call(pid, :drain_upstream, 5_000)

      [] ->
        []
    end
  end

  @spec stop(String.t()) :: :ok
  def stop(session_id) do
    case Registry.lookup(Nyanform.Session.Registry, session_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal, 5_000)
      [] -> :ok
    end
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    upstream_config = Keyword.fetch!(opts, :upstream_config)
    profile_name = Keyword.fetch!(opts, :profile)
    policy = Keyword.get(opts, :policy, :strict)
    max_pending_upstream = normalize_queue_limit(Keyword.get(opts, :max_pending_upstream, 128))

    case UpstreamShrine.start_link(upstream_config) do
      {:ok, upstream_pid} ->
        UpstreamShrine.set_downstream_sink(upstream_pid, self())

        case UpstreamShrine.initialize(upstream_pid) do
          {:ok, init_msg} ->
            init_result = init_msg.result || %{}
            constellation = resolve_constellation(profile_name, nil)

            {:ok,
             %{
               session_id: session_id,
               upstream_pid: upstream_pid,
               profile: profile_name,
               policy: policy,
               constellation: constellation,
               grimoire: nil,
               tool_include: Keyword.get(opts, :tool_include),
               tool_exclude: Keyword.get(opts, :tool_exclude),
               downstream_initialized: false,
               downstream_info: nil,
               upstream_info: Map.get(init_result, "serverInfo"),
               upstream_capabilities: Map.get(init_result, "capabilities"),
               protocol_revision: Map.get(init_result, "protocolVersion"),
               pending_upstream: :queue.new(),
               pending_upstream_count: 0,
               max_pending_upstream: max_pending_upstream,
               upstream_subscriber: nil,
               upstream_waiter: nil,
               upstream_delivery: nil,
               last_activity_ms: now_ms()
             }}

          {:error, reason} ->
            {:stop, {:upstream_init_failed, reason}}
        end

      {:error, reason} ->
        {:stop, {:upstream_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(
        {:downstream, %Message{kind: :request, method: "initialize"} = msg},
        _from,
        state
      ) do
    if valid_initialize_params?(msg.params) do
      handle_initialize(msg, state)
    else
      response =
        Message.error_response(
          msg.id,
          ErrorCodes.invalid_params(),
          "initialize params must include protocolVersion, capabilities, and clientInfo"
        )

      {:reply, {:reply, response}, state}
    end
  end

  def handle_call(
        {:downstream, %Message{kind: :notification, method: "notifications/initialized"} = msg},
        _from,
        state
      ) do
    UpstreamShrine.send_notification(state.upstream_pid, msg)
    {:reply, :ok, %{state | downstream_initialized: true}}
  end

  def handle_call(
        {:downstream, %Message{kind: :request, method: "tools/list"} = msg},
        _from,
        state
      ) do
    case UpstreamShrine.list_tools(state.upstream_pid) do
      {:ok, tools_msg} ->
        result = tools_msg.result || %{}
        upstream_tools = Map.get(result, "tools", [])
        next_cursor = Map.get(result, "nextCursor")

        filtered_tools = apply_tool_filters(upstream_tools, state)

        grimoire = ToolGrimoire.build(filtered_tools, state.constellation, state.policy)

        projected_tools =
          grimoire.entries
          |> Enum.filter(&(&1.accepted || state.policy == :permissive))
          |> Enum.map(fn entry ->
            upstream_tool = Enum.find(filtered_tools, &(&1["name"] == entry.name)) || %{}
            project_tool(entry, upstream_tool, state)
          end)

        response_result = %{"tools" => projected_tools}

        response_result =
          if next_cursor,
            do: Map.put(response_result, "nextCursor", next_cursor),
            else: response_result

        response = Message.response(msg.id, response_result)
        {:reply, {:reply, response}, %{state | grimoire: grimoire}}

      {:error, reason} ->
        error =
          Message.error_response(
            msg.id,
            ErrorCodes.internal_error(),
            "upstream tools/list failed: #{inspect(reason)}"
          )

        {:reply, {:reply, error}, state}
    end
  end

  def handle_call(
        {:downstream, %Message{kind: :request, method: "tools/call"} = msg},
        _from,
        state
      ) do
    handle_tool_call(msg, state)
  end

  def handle_call({:downstream, %Message{kind: :request} = msg}, _from, state) do
    case UpstreamShrine.request(state.upstream_pid, msg) do
      {:ok, response} ->
        {:reply, {:reply, response}, state}

      {:error, reason} ->
        error =
          Message.error_response(
            msg.id,
            ErrorCodes.internal_error(),
            "upstream error: #{inspect(reason)}"
          )

        {:reply, {:reply, error}, state}
    end
  end

  def handle_call({:downstream, %Message{kind: :notification} = msg}, _from, state) do
    UpstreamShrine.send_notification(state.upstream_pid, msg)
    {:reply, :ok, state}
  end

  def handle_call({:downstream, %Message{kind: :response} = msg}, _from, state) do
    UpstreamShrine.send_notification(state.upstream_pid, msg)
    {:reply, :ok, state}
  end

  def handle_call({:downstream, %Message{kind: :error} = msg}, _from, state) do
    UpstreamShrine.send_notification(state.upstream_pid, msg)
    {:reply, :ok, state}
  end

  def handle_call(:drain_upstream, _from, state) do
    pending = :queue.to_list(state.pending_upstream)

    {:reply, pending,
     %{
       state
       | pending_upstream: :queue.new(),
         pending_upstream_count: 0,
         last_activity_ms: now_ms()
     }}
  end

  def handle_call({:lease_upstream, owner, lease_ref, wait_ms}, from, state) do
    cond do
      state.upstream_waiter != nil or state.upstream_delivery != nil ->
        {:reply, {:error, :upstream_delivery_busy}, state}

      state.upstream_subscriber != nil ->
        {:reply, {:error, :upstream_subscriber_busy}, state}

      state.pending_upstream_count > 0 ->
        {messages, state} = take_pending_upstream(state)
        monitor = Process.monitor(owner)

        {:reply, {:ok, lease_ref, messages},
         %{
           state
           | upstream_delivery: {owner, monitor, lease_ref, messages},
             last_activity_ms: now_ms()
         }}

      wait_ms == 0 ->
        {:reply, {:ok, nil, []}, %{state | last_activity_ms: now_ms()}}

      true ->
        monitor = Process.monitor(owner)
        timer = Process.send_after(self(), {:upstream_lease_timeout, lease_ref}, wait_ms)

        {:noreply,
         %{
           state
           | upstream_waiter: {owner, monitor, from, lease_ref, timer},
             last_activity_ms: now_ms()
         }}
    end
  end

  def handle_call({:ack_upstream, owner, lease_ref}, _from, state) do
    case state.upstream_delivery do
      {^owner, monitor, ^lease_ref, _messages} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | upstream_delivery: nil, last_activity_ms: now_ms()}}

      _other ->
        {:reply, {:error, :unknown_upstream_delivery}, state}
    end
  end

  def handle_call({:subscribe_upstream, subscriber}, _from, state) do
    state = clear_subscriber(state)
    Enum.each(:queue.to_list(state.pending_upstream), &send(subscriber, {:nyanform_upstream, &1}))
    monitor = Process.monitor(subscriber)

    {:reply, :ok,
     %{
       state
       | pending_upstream: :queue.new(),
         pending_upstream_count: 0,
         upstream_subscriber: {subscriber, monitor},
         last_activity_ms: now_ms()
     }}
  end

  def handle_call({:unsubscribe_upstream, subscriber}, _from, state) do
    state =
      case state.upstream_subscriber do
        {^subscriber, _monitor} -> clear_subscriber(state)
        _other -> state
      end

    {:reply, :ok, %{state | last_activity_ms: now_ms()}}
  end

  def handle_call(:last_activity, _from, state) do
    {:reply, state.last_activity_ms, state}
  end

  def handle_call(_msg, _from, state) do
    {:reply, {:error, :unknown_message}, state}
  end

  @impl true
  def handle_info({:upstream_message, %Message{} = msg}, state) do
    state = %{state | last_activity_ms: now_ms()}

    case state.upstream_subscriber do
      {subscriber, _monitor} when is_pid(subscriber) ->
        if Process.alive?(subscriber) do
          send(subscriber, {:nyanform_upstream, msg})
          {:noreply, state}
        else
          {:noreply,
           state |> clear_subscriber() |> enqueue_upstream(msg) |> fulfill_upstream_waiter()}
        end

      nil ->
        {:noreply, state |> enqueue_upstream(msg) |> fulfill_upstream_waiter()}
    end
  end

  def handle_info({:upstream_lease_timeout, lease_ref}, state) do
    case state.upstream_waiter do
      {_owner, monitor, from, ^lease_ref, _timer} ->
        Process.demonitor(monitor, [:flush])
        GenServer.reply(from, {:ok, nil, []})
        {:noreply, %{state | upstream_waiter: nil, last_activity_ms: now_ms()}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    state = clear_down_subscriber(state, monitor)
    state = clear_down_waiter(state, pid, monitor)
    state = restore_down_delivery(state, pid, monitor)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast(:touch, state) do
    {:noreply, %{state | last_activity_ms: now_ms()}}
  end

  def handle_cast({:cancel_upstream_lease, owner, lease_ref}, state) do
    state = cancel_matching_waiter(state, owner, lease_ref)
    {:noreply, cancel_matching_delivery(state, owner, lease_ref)}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{upstream_pid: upstream_pid}) when is_pid(upstream_pid) do
    UpstreamShrine.stop(upstream_pid)
  end

  def terminate(_reason, _state), do: :ok

  defp handle_tool_call(msg, state) do
    if valid_tools_call_params?(msg.params) do
      alias_name = Map.fetch!(msg.params, "name")
      arguments = Map.get(msg.params, "arguments", %{})
      do_handle_tool_call(msg, alias_name, arguments, state)
    else
      error =
        Message.error_response(
          msg.id,
          ErrorCodes.invalid_params(),
          "tools/call params must contain a non-empty name and object arguments"
        )

      {:reply, {:reply, error}, state}
    end
  end

  defp do_handle_tool_call(msg, alias_name, arguments, state) do
    case state.grimoire do
      nil ->
        error =
          Message.error_response(
            msg.id,
            ErrorCodes.invalid_params(),
            "tool catalog not initialized; call tools/list first"
          )

        {:reply, {:reply, error}, state}

      grimoire ->
        case ToolGrimoire.resolve_origin(grimoire, alias_name) do
          {:ok, origin_name} ->
            entry = find_tool(grimoire, origin_name)
            schema = compile_tool_schema(entry)
            repair_result = RewriteTalisman.repair(arguments, schema)

            call_msg =
              Message.request(Lifecycle.generate_id(), "tools/call", %{
                "name" => origin_name,
                "arguments" => repair_result.arguments
              })

            case UpstreamShrine.request(state.upstream_pid, call_msg) do
              {:ok, response} ->
                correlated = correlate_response(response, msg.id)
                {:reply, {:reply, correlated}, state}

              {:error, reason} ->
                error =
                  Message.error_response(
                    msg.id,
                    ErrorCodes.internal_error(),
                    "upstream tools/call failed: #{inspect(reason)}"
                  )

                {:reply, {:reply, error}, state}
            end

          {:error, :not_found} ->
            error =
              Message.error_response(
                msg.id,
                ErrorCodes.method_not_found(),
                "unknown tool: #{alias_name}"
              )

            {:reply, {:reply, error}, state}
        end
    end
  end

  defp handle_initialize(msg, state) do
    client_info = Map.fetch!(msg.params, "clientInfo")

    resolved_profile =
      if state.profile == "auto" do
        {:ok, detected} = ClientFamiliar.resolve("auto", client_info)
        detected
      else
        state.profile
      end

    constellation = resolve_constellation(resolved_profile, client_info)
    init_result = Lifecycle.build_initialize_result(state.protocol_revision, client_info)
    response = Message.response(msg.id, init_result)

    {:reply, {:reply, response},
     %{
       state
       | downstream_initialized: true,
         downstream_info: client_info,
         profile: resolved_profile,
         constellation: constellation,
         last_activity_ms: now_ms()
     }}
  end

  defp valid_client_info?(%{"name" => name, "version" => version}) do
    non_empty_string?(name) and non_empty_string?(version)
  end

  defp valid_client_info?(_client_info), do: false

  defp valid_arguments?(:error), do: true
  defp valid_arguments?({:ok, arguments}), do: is_map(arguments)

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp normalize_queue_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_queue_limit(_limit), do: 128

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_timeout(_timeout), do: default_timeout()

  defp default_timeout do
    Application.get_env(:nyanform, :request_timeout_ms, 30_000)
  end

  defp enqueue_upstream(state, msg)
       when state.pending_upstream_count < state.max_pending_upstream do
    %{
      state
      | pending_upstream: :queue.in(msg, state.pending_upstream),
        pending_upstream_count: state.pending_upstream_count + 1
    }
  end

  defp enqueue_upstream(state, msg) do
    {{:value, _dropped}, pending_upstream} = :queue.out(state.pending_upstream)
    %{state | pending_upstream: :queue.in(msg, pending_upstream)}
  end

  defp take_pending_upstream(state) do
    messages = :queue.to_list(state.pending_upstream)

    {messages,
     %{
       state
       | pending_upstream: :queue.new(),
         pending_upstream_count: 0
     }}
  end

  defp fulfill_upstream_waiter(%{upstream_waiter: nil} = state), do: state

  defp fulfill_upstream_waiter(state) do
    {owner, monitor, from, lease_ref, timer} = state.upstream_waiter
    Process.cancel_timer(timer)
    {messages, state} = take_pending_upstream(state)
    GenServer.reply(from, {:ok, lease_ref, messages})

    %{
      state
      | upstream_waiter: nil,
        upstream_delivery: {owner, monitor, lease_ref, messages}
    }
  end

  defp clear_down_subscriber(state, monitor) do
    case state.upstream_subscriber do
      {_subscriber, ^monitor} -> %{state | upstream_subscriber: nil}
      _other -> state
    end
  end

  defp clear_down_waiter(state, owner, monitor) do
    case state.upstream_waiter do
      {^owner, ^monitor, _from, _lease_ref, timer} ->
        Process.cancel_timer(timer)
        %{state | upstream_waiter: nil}

      _other ->
        state
    end
  end

  defp restore_down_delivery(state, owner, monitor) do
    case state.upstream_delivery do
      {^owner, ^monitor, _lease_ref, messages} ->
        state |> Map.put(:upstream_delivery, nil) |> restore_delivery_messages(messages)

      _other ->
        state
    end
  end

  defp cancel_matching_waiter(state, owner, lease_ref) do
    case state.upstream_waiter do
      {^owner, monitor, _from, ^lease_ref, timer} ->
        Process.cancel_timer(timer)
        Process.demonitor(monitor, [:flush])
        %{state | upstream_waiter: nil}

      _other ->
        state
    end
  end

  defp cancel_matching_delivery(state, owner, lease_ref) do
    case state.upstream_delivery do
      {^owner, monitor, ^lease_ref, messages} ->
        Process.demonitor(monitor, [:flush])
        state |> Map.put(:upstream_delivery, nil) |> restore_delivery_messages(messages)

      _other ->
        state
    end
  end

  defp restore_delivery_messages(state, messages) do
    pending = messages ++ :queue.to_list(state.pending_upstream)
    pending = Enum.take(pending, -state.max_pending_upstream)

    %{
      state
      | pending_upstream: :queue.from_list(pending),
        pending_upstream_count: length(pending)
    }
  end

  defp clear_subscriber(%{upstream_subscriber: {_subscriber, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    %{state | upstream_subscriber: nil}
  end

  defp clear_subscriber(state), do: state

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp find_tool(grimoire, origin_name) do
    Enum.find(grimoire.entries, &(&1.name == origin_name))
  end

  defp compile_tool_schema(nil), do: nil

  defp compile_tool_schema(entry) do
    case Pipeline.compile(entry.input_schema) do
      {:ok, %{scroll: scroll}} -> scroll
      {:error, _} -> nil
    end
  end

  defp correlate_response(%Message{kind: :response} = response, client_id) do
    %{response | id: client_id}
  end

  defp correlate_response(%Message{kind: :error} = response, client_id) do
    %{response | id: client_id}
  end

  defp correlate_response(response, _client_id), do: response

  defp project_tool(entry, upstream_tool, state) do
    input_schema = entry.input_schema

    projected_schema =
      case Pipeline.compile(input_schema) do
        {:ok, %{scroll: scroll}} ->
          projection = Projector.project(scroll, state.constellation, state.policy)
          projection.schema

        {:error, _} ->
          input_schema
      end

    base = %{
      "name" => entry.alias,
      "description" => entry.description,
      "inputSchema" => projected_schema
    }

    base =
      if Map.has_key?(upstream_tool, "outputSchema") do
        Map.put(base, "outputSchema", Map.get(upstream_tool, "outputSchema"))
      else
        base
      end

    base =
      if Map.has_key?(upstream_tool, "annotations") do
        Map.put(base, "annotations", Map.get(upstream_tool, "annotations"))
      else
        base
      end

    base =
      if Map.has_key?(upstream_tool, "_meta") do
        Map.put(base, "_meta", Map.get(upstream_tool, "_meta"))
      else
        base
      end

    base
  end

  defp resolve_constellation(profile_name, _client_info) do
    case Builtins.fetch(profile_name) do
      {:ok, constellation} ->
        constellation

      :error ->
        {:ok, canonical} = Builtins.fetch("canonical")
        canonical
    end
  end

  defp apply_tool_filters(tools, state) do
    tools
    |> filter_included(state.tool_include)
    |> filter_excluded(state.tool_exclude)
  end

  defp filter_included(tools, nil), do: tools

  defp filter_included(tools, patterns) when is_list(patterns) do
    Enum.filter(tools, fn tool ->
      name = Map.get(tool, "name", "")
      Enum.any?(patterns, &tool_matches?(name, &1))
    end)
  end

  defp filter_excluded(tools, nil), do: tools

  defp filter_excluded(tools, patterns) when is_list(patterns) do
    Enum.reject(tools, fn tool ->
      name = Map.get(tool, "name", "")
      Enum.any?(patterns, &tool_matches?(name, &1))
    end)
  end

  defp tool_matches?(name, pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, name)
      {:error, _} -> name == pattern
    end
  end
end
