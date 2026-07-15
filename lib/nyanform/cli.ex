defmodule Nyanform.CLI do
  alias Nyanform.Config.Loader
  alias Nyanform.Diagnostic.Omen
  alias Nyanform.Limits
  alias Nyanform.Profile.{Builtins, Projector}
  alias Nyanform.Protocol.Lifecycle
  alias Nyanform.Report.{CompatibilityResult, Renderer}
  alias Nyanform.Schema.Pipeline
  alias Nyanform.ToolGrimoire
  alias Nyanform.Transport.{DownstreamHttp, DownstreamStdio, UpstreamShrine}

  @commands ~w(serve inspect matrix snapshot check doctor)

  @spec main([String.t()]) :: integer()
  def main(args) do
    dispatch(args)
  end

  defp dispatch([command, help_flag])
       when command in @commands and help_flag in ["--help", "-h"],
       do: command_help(command)

  defp dispatch(["serve" | rest]), do: serve(rest)
  defp dispatch(["inspect" | rest]), do: inspect_cmd(rest)
  defp dispatch(["matrix" | rest]), do: matrix_cmd(rest)
  defp dispatch(["snapshot" | rest]), do: snapshot_cmd(rest)
  defp dispatch(["check" | rest]), do: check_cmd(rest)
  defp dispatch(["doctor" | rest]), do: doctor_cmd(rest)
  defp dispatch(["--help"]), do: help()
  defp dispatch(["-h"]), do: help()
  defp dispatch([]), do: help()
  defp dispatch([cmd | _]), do: usage_error("unknown command", cmd)

  defp serve(args) do
    switches = [
      config: :string,
      profile: :string,
      policy: :string,
      stdio_command: [:string, :keep],
      stdio_arg: [:string, :keep],
      http_endpoint: :string,
      upstream_transport: :string,
      downstream_transport: :string,
      port: :integer,
      host: :string,
      env: [:string, :keep],
      allowed_origin: [:string, :keep],
      timeout: :integer
    ]

    with {:ok, opts} <- parse_command_options(args, switches, [c: :config, p: :profile], "serve"),
         {:ok, config} <- resolve_serve_config(opts) do
      run_proxy(config)
    else
      {:error, code} when is_integer(code) ->
        code

      {:error, reason} ->
        error_exit("NYA-CONFIG-001", "configuration error: #{format_error(reason)}")
    end
  end

  defp resolve_serve_config(opts) do
    case Keyword.get(opts, :config) do
      nil ->
        build_serve_config_from_opts(opts)

      path ->
        Loader.load_file(path)
    end
  end

  defp build_serve_config_from_opts(opts) do
    profile = Keyword.get(opts, :profile, "canonical")
    policy_name = Keyword.get(opts, :policy, "strict")

    with {:ok, policy} <- parse_policy(policy_name),
         :ok <- validate_profile(profile, true),
         {:ok, upstream_cfg} <- build_serve_upstream(opts),
         {:ok, downstream_cfg} <- build_serve_downstream(opts) do
      {:ok,
       %{
         downstream: downstream_cfg,
         upstream: upstream_cfg,
         profile: profile,
         policy: policy,
         env_allowlist: [],
         timeout_ms: Keyword.get(opts, :timeout, 30_000),
         max_message_size: 1_048_576,
         max_http_body_size: 4_194_304,
         logging: :normal,
         tool_include: nil,
         tool_exclude: nil
       }}
    end
  end

  defp build_serve_upstream(opts) do
    commands = Keyword.get_values(opts, :stdio_command)
    args = Keyword.get_values(opts, :stdio_arg)
    endpoint = Keyword.get(opts, :http_endpoint)

    transport =
      Keyword.get(opts, :upstream_transport) || infer_upstream_transport(commands, endpoint)

    with :ok <- validate_upstream_sources(commands, args, endpoint) do
      build_serve_upstream_config(transport, commands, args, endpoint, opts)
    end
  end

  defp validate_upstream_sources(commands, args, endpoint) do
    cond do
      endpoint != nil and (commands != [] or args != []) -> {:error, :multiple_upstreams}
      commands == [] and args != [] -> {:error, :stdio_arg_without_command}
      true -> :ok
    end
  end

  defp build_serve_upstream_config("stdio", [], _args, _endpoint, _opts) do
    {:error, :no_upstream_command}
  end

  defp build_serve_upstream_config("stdio", commands, args, nil, opts) do
    {:ok,
     %{
       transport: :stdio,
       command: commands ++ args,
       endpoint: nil,
       env: build_env(Keyword.get_values(opts, :env))
     }}
  end

  defp build_serve_upstream_config("http", [], [], nil, _opts) do
    {:error, :no_upstream_endpoint}
  end

  defp build_serve_upstream_config("http", [], [], endpoint, _opts) do
    {:ok, %{transport: :http, command: nil, endpoint: endpoint, env: nil}}
  end

  defp build_serve_upstream_config(transport, _commands, _args, _endpoint, _opts) do
    {:error, {:invalid_upstream_transport, transport}}
  end

  defp build_serve_downstream(opts) do
    case Keyword.get(opts, :downstream_transport, "stdio") do
      "stdio" -> {:ok, serve_downstream_config(opts, :stdio)}
      "http" -> {:ok, serve_downstream_config(opts, :http)}
      other -> {:error, {:invalid_downstream_transport, other}}
    end
  end

  defp serve_downstream_config(opts, transport) do
    %{
      transport: transport,
      port: Keyword.get(opts, :port, 8080),
      host: Keyword.get(opts, :host, "127.0.0.1"),
      allowed_origins: Keyword.get_values(opts, :allowed_origin)
    }
  end

  defp infer_upstream_transport(commands, _endpoint) when commands != [], do: "stdio"
  defp infer_upstream_transport(_commands, _endpoint), do: "http"

  defp build_env(env_pairs) do
    env_pairs
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
    |> Map.new()
  end

  defp run_proxy(config) do
    configure_logging(config.logging)
    upstream_config = Loader.to_upstream_config(config)
    tool_filters = %{include: config.tool_include, exclude: config.tool_exclude}

    case config.downstream.transport do
      :stdio ->
        DownstreamStdio.run(upstream_config, config.profile, config.policy,
          tool_filters: tool_filters,
          max_message_size: config.max_message_size
        )

      :http ->
        case DownstreamHttp.run(upstream_config, config.profile, config.policy,
               port: config.downstream.port,
               host: config.downstream.host,
               allowed_origins: Map.get(config.downstream, :allowed_origins, []),
               max_message_size: config.max_message_size,
               max_http_body_size: config.max_http_body_size,
               tool_filters: tool_filters
             ) do
          {:ok, pid} ->
            IO.write(
              :stderr,
              "nyanform: HTTP proxy listening on #{config.downstream.host}:#{config.downstream.port}\n"
            )

            Process.monitor(pid)

            receive do
              {:DOWN, _ref, :process, ^pid, reason} ->
                IO.write(:stderr, "nyanform: server stopped: #{inspect(reason)}\n")
                0
            end

          {:error, reason} ->
            error_exit("NYA-TRANSPORT-006", "failed to start HTTP server: #{inspect(reason)}")
        end
    end
  end

  defp configure_logging(:quiet), do: Logger.configure(level: :error)
  defp configure_logging(:verbose), do: Logger.configure(level: :debug)
  defp configure_logging(_normal), do: Logger.configure(level: :warning)

  defp inspect_cmd(args) do
    switches = [
      stdio_command: [:string, :keep],
      stdio_arg: [:string, :keep],
      http_endpoint: :string,
      profile: :string,
      policy: :string,
      format: :string,
      output: :string
    ]

    with {:ok, opts} <-
           parse_command_options(args, switches, [f: :format, o: :output, p: :profile], "inspect"),
         {:ok, constellation} <- fetch_profile(Keyword.get(opts, :profile, "canonical")),
         {:ok, policy} <- parse_policy(Keyword.get(opts, :policy, "strict")),
         {:ok, fmt} <- Renderer.parse_inspect_format(Keyword.get(opts, :format, "terminal")),
         {:ok, upstream_config} <- build_cli_upstream(opts) do
      execute_inspect(opts, upstream_config, constellation, policy, fmt)
    else
      {:error, code} when is_integer(code) ->
        code

      {:error, {:unknown_profile, profile}} ->
        usage_error("invalid inspect profile", profile)

      {:error, {:unknown_policy, policy}} ->
        usage_error("invalid inspect policy", policy)

      {:error, :missing_upstream} ->
        error_exit("NYA-CONFIG-001", "inspect requires --stdio-command or --http-endpoint")

      {:error, reason} ->
        usage_error("invalid inspect option", format_error(reason))
    end
  end

  defp execute_inspect(opts, upstream_config, constellation, policy, format) do
    case run_inspect(upstream_config, constellation, policy) do
      {:ok, report} ->
        output = Renderer.inspect_report(report, format)

        case Keyword.get(opts, :output) do
          nil -> IO.puts(output)
          path -> File.write!(path, output)
        end

        0

      {:error, reason} ->
        error_exit("NYA-TRANSPORT-004", "inspect failed: #{format_error(reason)}")
    end
  end

  defp run_inspect(upstream_config, constellation, policy) do
    started = System.monotonic_time(:microsecond)

    with_initialized_upstream(upstream_config, fn upstream_pid, init_msg ->
      init_result = init_msg.result || %{}

      with {:ok, tools} <- list_all_tools(upstream_pid) do
        grimoire = ToolGrimoire.build(tools, constellation, policy)

        {omens, unsupported, rejected, normalization, lossy} =
          analyze_tools(grimoire, policy)

        aliases = build_alias_map(grimoire, policy)
        finished = System.monotonic_time(:microsecond)

        {:ok,
         %{
           server_info: Map.get(init_result, "serverInfo"),
           protocol_revision: Map.get(init_result, "protocolVersion"),
           capabilities: Map.get(init_result, "capabilities", %{}),
           tool_count: length(tools),
           schema_valid: not Enum.any?(omens, &(&1.severity == :rejected)),
           unsupported_constructs: unsupported,
           normalization_operations: normalization,
           lossy_operations: lossy,
           rejected_tools: rejected,
           aliases: aliases,
           omens: omens,
           duration_us: finished - started
         }}
      end
    end)
  end

  defp analyze_tools(%ToolGrimoire{entries: entries}, policy) do
    {omens, unsupported, rejected, normalization, lossy} =
      Enum.reduce(entries, {[], [], [], [], []}, fn entry, {o_acc, u_acc, r_acc, n_acc, l_acc} ->
        unsupported_constructs =
          case Pipeline.compile(entry.input_schema) do
            {:ok, result} -> find_unsupported(result.scroll)
            {:error, _error} -> []
          end

        tool_omens = entry.omens
        n_ops = Enum.filter(tool_omens, &(&1.severity == :normalized))
        l_ops = Enum.filter(tool_omens, &(&1.severity == :lossy))

        rejected_names =
          if published_entry?(entry, policy), do: r_acc, else: r_acc ++ [entry.name]

        {o_acc ++ tool_omens, u_acc ++ unsupported_constructs, rejected_names, n_acc ++ n_ops,
         l_acc ++ l_ops}
      end)

    {omens, Enum.uniq(unsupported), Enum.uniq(rejected), normalization, lossy}
  end

  defp find_unsupported(scroll) do
    case scroll.kind do
      :union -> ["oneOf/anyOf"]
      :intersection -> ["allOf"]
      :ref -> ["$ref"]
      _ -> []
    end
  end

  defp build_alias_map(%ToolGrimoire{} = grimoire, policy) do
    grimoire.entries
    |> Enum.filter(&published_entry?(&1, policy))
    |> Enum.map(fn entry -> {entry.name, entry.alias} end)
    |> Map.new()
  end

  defp published_entry?(entry, policy) do
    entry.publishable and (entry.accepted or policy == :permissive)
  end

  defp matrix_cmd(args) do
    switches = [
      stdio_command: [:string, :keep],
      stdio_arg: [:string, :keep],
      http_endpoint: :string,
      format: :string,
      output: :string,
      profile: [:string, :keep],
      policy: :string,
      fail_on_rejected: :boolean,
      fail_on_lossy: :boolean
    ]

    with {:ok, opts} <-
           parse_command_options(args, switches, [f: :format, o: :output, p: :profile], "matrix"),
         {:ok, policy} <- parse_policy(Keyword.get(opts, :policy, "strict")),
         profiles = selected_profiles(opts),
         :ok <- validate_profiles(profiles),
         {:ok, fmt} <- Renderer.parse_format(Keyword.get(opts, :format, "terminal")),
         {:ok, upstream_config} <- build_cli_upstream(opts) do
      execute_matrix(opts, upstream_config, profiles, policy, fmt)
    else
      {:error, code} when is_integer(code) ->
        code

      {:error, {:unknown_profile, profile}} ->
        usage_error("invalid matrix profile", profile)

      {:error, {:unknown_policy, policy}} ->
        usage_error("invalid matrix policy", policy)

      {:error, :missing_upstream} ->
        error_exit("NYA-CONFIG-001", "matrix requires --stdio-command or --http-endpoint")

      {:error, reason} ->
        usage_error("invalid matrix option", format_error(reason))
    end
  end

  defp execute_matrix(opts, upstream_config, profiles, policy, format) do
    case run_matrix(upstream_config, profiles, policy) do
      {:ok, results} ->
        output = Renderer.matrix_report(results, format)

        case Keyword.get(opts, :output) do
          nil -> IO.puts(output)
          path -> File.write!(path, output)
        end

        exit_code =
          determine_exit_code(
            results,
            Keyword.get(opts, :fail_on_rejected, true),
            Keyword.get(opts, :fail_on_lossy, false)
          )

        exit_code

      {:error, reason} ->
        error_exit("NYA-TRANSPORT-004", "matrix failed: #{format_error(reason)}")
    end
  end

  defp run_matrix(upstream_config, profiles, policy) do
    with_initialized_upstream(upstream_config, fn upstream_pid, _init ->
      with {:ok, tools} <- list_all_tools(upstream_pid) do
        results =
          Task.Supervisor.async_stream(
            Nyanform.Compile.TaskSupervisor,
            profiles,
            fn profile -> compile_profile(tools, profile, policy) end,
            max_concurrency: Limits.default().max_concurrent_compilation,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        {:ok, results}
      end
    end)
  end

  defp compile_profile(tools, profile_name, policy) do
    started = System.monotonic_time(:microsecond)
    {:ok, constellation} = Builtins.fetch(profile_name)

    grimoire = ToolGrimoire.build(tools, constellation, policy)

    tool_results =
      Enum.map(grimoire.entries, fn entry ->
        {omens, digest, accepted} =
          case Pipeline.compile(entry.input_schema) do
            {:ok, result} ->
              projection = Projector.project(result.scroll, constellation, policy)

              omens =
                Enum.map(projection.omens ++ result.omens, fn omen ->
                  %{omen | tool: omen.tool || entry.name, profile: omen.profile || profile_name}
                end)

              {omens, result.digest, projection.accepted}

            {:error, _} ->
              {[
                 %Omen{
                   code: "NYA-SCHEMA-001",
                   severity: :rejected,
                   schema_path: [],
                   rule: "validation_failed",
                   source: nil,
                   target: nil,
                   semantics_preserved: false,
                   explanation: "schema failed validation",
                   action: nil,
                   tool: entry.name,
                   profile: profile_name
                 }
               ], nil, false}
          end

        %{
          tool: entry.name,
          alias: entry.alias,
          accepted: accepted,
          worst_severity: Omen.worst(omens),
          omens: omens,
          digest: digest
        }
      end)

    {accepted, worst} = CompatibilityResult.aggregate(tool_results, nil)

    finished = System.monotonic_time(:microsecond)

    %CompatibilityResult{
      profile: profile_name,
      policy: policy,
      tool_results: tool_results,
      accepted: accepted,
      worst_severity: worst,
      omens: [],
      duration_us: finished - started
    }
  end

  defp determine_exit_code(results, fail_on_rejected, fail_on_lossy) do
    has_rejected =
      Enum.any?(results, fn r ->
        not r.accepted or
          Enum.any?(r.tool_results, &(&1.worst_severity == :rejected and not &1.accepted))
      end)

    has_lossy = Enum.any?(results, &result_has_severity?(&1, :lossy))

    cond do
      fail_on_rejected and has_rejected -> 1
      fail_on_lossy and has_lossy -> 1
      true -> 0
    end
  end

  defp result_has_severity?(result, severity) do
    Enum.any?(result.omens, &(&1.severity == severity)) or
      Enum.any?(result.tool_results, fn tool_result ->
        Enum.any?(tool_result.omens, &(&1.severity == severity))
      end)
  end

  defp snapshot_cmd(args) do
    switches = [
      stdio_command: [:string, :keep],
      stdio_arg: [:string, :keep],
      http_endpoint: :string,
      output: :string
    ]

    with {:ok, opts} <- parse_command_options(args, switches, [o: :output], "snapshot"),
         {:ok, upstream_config} <- build_cli_upstream(opts) do
      execute_snapshot(opts, upstream_config)
    else
      {:error, code} when is_integer(code) ->
        code

      {:error, :missing_upstream} ->
        error_exit("NYA-CONFIG-001", "snapshot requires --stdio-command or --http-endpoint")

      {:error, reason} ->
        usage_error("invalid snapshot option", format_error(reason))
    end
  end

  defp execute_snapshot(opts, upstream_config) do
    case run_snapshot(upstream_config) do
      {:ok, snapshot} ->
        serialized = Jason.encode!(snapshot, pretty: true)

        case Keyword.get(opts, :output) do
          nil -> IO.puts(serialized)
          path -> File.write!(path, serialized)
        end

        0

      {:error, reason} ->
        error_exit("NYA-TRANSPORT-004", "snapshot failed: #{format_error(reason)}")
    end
  end

  defp run_snapshot(upstream_config) do
    with_initialized_upstream(upstream_config, fn upstream_pid, init_msg ->
      init_result = init_msg.result || %{}

      with {:ok, tools} <- list_all_tools(upstream_pid) do
        {:ok, build_snapshot(init_result, tools)}
      end
    end)
  end

  defp build_snapshot(init_result, tools) do
    tool_snapshots =
      tools
      |> Enum.map(fn tool ->
        schema = tool_input_schema(tool)

        {digest, scroll_kind} =
          case Pipeline.compile(schema) do
            {:ok, result} -> {result.digest, result.scroll.kind}
            {:error, _} -> {nil, :unknown}
          end

        %{
          name: cli_tool_name(tool),
          description: tool_field(tool, "description"),
          input_schema: schema,
          output_schema: tool_field(tool, "outputSchema"),
          digest: digest,
          schema_kind: scroll_kind
        }
      end)
      |> Enum.sort_by(& &1.name)

    %{
      server_info: Map.get(init_result, "serverInfo"),
      capabilities: Map.get(init_result, "capabilities", %{}),
      protocol_revision: Map.get(init_result, "protocolVersion"),
      tools: tool_snapshots
    }
  end

  defp check_cmd(args) do
    switches = [
      stdio_command: [:string, :keep],
      stdio_arg: [:string, :keep],
      http_endpoint: :string,
      snapshot: :string,
      format: :string
    ]

    with {:ok, opts} <-
           parse_command_options(args, switches, [s: :snapshot, f: :format], "check"),
         {:ok, snapshot_path} <- required_option(opts, :snapshot),
         {:ok, format} <- Renderer.parse_inspect_format(Keyword.get(opts, :format, "terminal")),
         {:ok, upstream_config} <- build_cli_upstream(opts),
         {:ok, snapshot_content} <- File.read(snapshot_path),
         {:ok, snapshot} <- Jason.decode(snapshot_content),
         {:ok, comparison} <- run_check(upstream_config, snapshot) do
      output = format_check_report(comparison, format)
      IO.puts(output)

      if comparison.has_breaking do
        1
      else
        0
      end
    else
      {:error, code} when is_integer(code) ->
        code

      {:error, {:missing_option, :snapshot}} ->
        error_exit("NYA-CONFIG-001", "check requires --snapshot path")

      {:error, :missing_upstream} ->
        error_exit("NYA-CONFIG-001", "check requires --stdio-command or --http-endpoint")

      {:error, reason} when is_binary(reason) ->
        usage_error("invalid check option", reason)

      {:error, reason} ->
        error_exit("NYA-CONFIG-001", "check failed: #{format_error(reason)}")
    end
  end

  defp run_check(upstream_config, stored_snapshot) do
    with_initialized_upstream(upstream_config, fn upstream_pid, _init ->
      with {:ok, live_tools} <- list_all_tools(upstream_pid) do
        stored_tools = Map.get(stored_snapshot, "tools", [])
        changes = compare_tools(stored_tools, live_tools)

        {:ok,
         %{
           changes: changes,
           has_breaking: Enum.any?(changes, &(&1.classification == :breaking)),
           has_potentially_breaking:
             Enum.any?(changes, &(&1.classification == :potentially_breaking))
         }}
      end
    end)
  end

  defp with_initialized_upstream(upstream_config, operation) do
    case UpstreamShrine.start_link(upstream_config) do
      {:ok, upstream_pid} ->
        try do
          with {:ok, init_msg} <- UpstreamShrine.initialize(upstream_pid) do
            operation.(upstream_pid, init_msg)
          end
        after
          if Process.alive?(upstream_pid), do: UpstreamShrine.stop(upstream_pid)
        end

      error ->
        error
    end
  end

  defp list_all_tools(upstream_pid) do
    list_tools_page(upstream_pid, %{}, [], 0, %{}, Limits.default().max_tool_count)
  end

  defp list_tools_page(upstream_pid, params, pages, count, seen_cursors, limit) do
    with {:ok, tools_msg} <- UpstreamShrine.list_tools(upstream_pid, params) do
      case tools_msg.result do
        result when is_map(result) ->
          case Map.get(result, "tools", []) do
            tools when is_list(tools) ->
              continue_tools_page(
                upstream_pid,
                result,
                tools,
                pages,
                count,
                seen_cursors,
                limit
              )

            _invalid_tools ->
              {:error, :invalid_tools_catalog}
          end

        _invalid_result ->
          {:error, :invalid_tools_result}
      end
    end
  end

  defp continue_tools_page(upstream_pid, result, tools, pages, count, seen_cursors, limit) do
    next_count = count + length(tools)

    cond do
      next_count > limit ->
        {:error, {:max_tool_count_exceeded, limit}}

      is_nil(Map.get(result, "nextCursor")) ->
        {:ok, pages |> Enum.reverse([tools]) |> List.flatten()}

      not is_binary(Map.get(result, "nextCursor")) ->
        {:error, :invalid_next_cursor}

      Map.has_key?(seen_cursors, Map.get(result, "nextCursor")) ->
        {:error, :pagination_cycle}

      true ->
        cursor = Map.fetch!(result, "nextCursor")

        list_tools_page(
          upstream_pid,
          %{"cursor" => cursor},
          [tools | pages],
          next_count,
          Map.put(seen_cursors, cursor, true),
          limit
        )
    end
  end

  defp compare_tools(stored, live) do
    stored_by_name = Map.new(stored, &{cli_tool_name(&1), normalize_tool_map(&1, :stored)})
    live_by_name = Map.new(live, &{cli_tool_name(&1), normalize_tool_map(&1, :live)})

    all_names =
      MapSet.union(MapSet.new(Map.keys(stored_by_name)), MapSet.new(Map.keys(live_by_name)))
      |> Enum.sort()

    Enum.flat_map(all_names, fn name ->
      stored_tool = Map.get(stored_by_name, name)
      live_tool = Map.get(live_by_name, name)

      classify_change(name, stored_tool, live_tool)
    end)
  end

  defp classify_change(name, nil, _live_tool) do
    [
      %{
        tool: name,
        classification: :compatible,
        change: "tool_added",
        detail: "new tool available"
      }
    ]
  end

  defp classify_change(name, _stored, nil) do
    [
      %{
        tool: name,
        classification: :breaking,
        change: "tool_removed",
        detail: "tool no longer available"
      }
    ]
  end

  defp classify_change(name, stored_tool, live_tool) do
    stored_input_schema =
      Map.get(stored_tool, "input_schema", Map.get(stored_tool, "inputSchema", %{}))

    live_input_schema =
      Map.get(live_tool, "input_schema", Map.get(live_tool, "inputSchema", %{}))

    stored_output_schema =
      Map.get(stored_tool, "output_schema") || Map.get(stored_tool, "outputSchema") || %{}

    live_output_schema =
      Map.get(live_tool, "output_schema") || Map.get(live_tool, "outputSchema") || %{}

    digests = %{
      stored_input: digest_of(stored_input_schema),
      live_input: digest_of(live_input_schema),
      stored_output: digest_of(stored_output_schema),
      live_output: digest_of(live_output_schema),
      stored_input_schema: stored_input_schema,
      live_input_schema: live_input_schema,
      stored_output_schema: stored_output_schema,
      live_output_schema: live_output_schema
    }

    classify_by_digest(name, digests, stored_tool, live_tool)
  end

  defp digest_of(schema) do
    case Pipeline.compile(schema) do
      {:ok, result} -> result.digest
      {:error, _} -> nil
    end
  end

  defp classify_by_digest(name, digests, stored_tool, live_tool) do
    stored_desc = Map.get(stored_tool, "description")
    live_desc = Map.get(live_tool, "description")

    inputs_match =
      schemas_match?(
        digests.stored_input,
        digests.live_input,
        digests.stored_input_schema,
        digests.live_input_schema
      )

    outputs_match =
      schemas_match?(
        digests.stored_output,
        digests.live_output,
        digests.stored_output_schema,
        digests.live_output_schema
      )

    cond do
      stored_desc != live_desc and same_schema_ignoring_desc?(stored_tool, live_tool) and
          outputs_match ->
        [
          change_entry(
            name,
            :metadata_only,
            "description_changed",
            "only description changed; schema semantics unchanged"
          )
        ]

      inputs_match and outputs_match ->
        []

      digests.stored_input != nil and digests.live_input != nil ->
        [
          change_entry(
            name,
            :breaking,
            "schema_changed",
            "schema digest changed; potentially breaking"
          )
        ]

      true ->
        [
          change_entry(
            name,
            :potentially_breaking,
            "schema_changed",
            "schema changed but digest comparison inconclusive"
          )
        ]
    end
  end

  defp schemas_match?(left_digest, right_digest, _left_schema, _right_schema)
       when is_binary(left_digest) and is_binary(right_digest) do
    left_digest == right_digest
  end

  defp schemas_match?(_left_digest, _right_digest, left_schema, right_schema) do
    left_schema == right_schema
  end

  defp change_entry(name, classification, change, detail) do
    %{tool: name, classification: classification, change: change, detail: detail}
  end

  defp same_schema_ignoring_desc?(stored, live) do
    stored_schema = Map.get(stored, "input_schema", Map.get(stored, "inputSchema", %{}))
    live_schema = Map.get(live, "input_schema", Map.get(live, "inputSchema", %{}))

    stored_without_desc = drop_schema_description(stored_schema)
    live_without_desc = drop_schema_description(live_schema)

    canonical_equal?(stored_without_desc, live_without_desc)
  end

  defp tool_input_schema(tool) when is_map(tool) do
    case Map.fetch(tool, "inputSchema") do
      {:ok, schema} -> schema
      :error -> nil
    end
  end

  defp tool_input_schema(tool), do: tool

  defp tool_field(tool, key) when is_map(tool), do: Map.get(tool, key)
  defp tool_field(_tool, _key), do: nil

  defp cli_tool_name(%{"name" => name}) when is_binary(name), do: name

  defp cli_tool_name(tool) do
    suffix = tool |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1))
    suffix = Base.encode16(suffix, case: :lower)

    "invalid_tool_" <> String.slice(suffix, 0, 8)
  end

  defp normalize_tool_map(tool, _source) when is_map(tool), do: tool

  defp normalize_tool_map(tool, :stored) do
    %{"name" => cli_tool_name(tool), "input_schema" => tool}
  end

  defp normalize_tool_map(tool, :live) do
    %{"name" => cli_tool_name(tool), "inputSchema" => tool}
  end

  defp drop_schema_description(schema) when is_map(schema), do: Map.delete(schema, "description")
  defp drop_schema_description(schema), do: schema

  defp canonical_equal?(left, right) do
    with {:ok, l} <- Pipeline.compile(left),
         {:ok, r} <- Pipeline.compile(right) do
      l.digest == r.digest
    else
      _ -> left == right
    end
  end

  defp format_check_report(comparison, :terminal) do
    header = ["Nyanform Check Report", String.duplicate("=", 40), ""]

    body =
      if comparison.changes == [] do
        ["No changes detected.", ""]
      else
        grouped = Enum.group_by(comparison.changes, & &1.classification)
        render_change_groups(grouped)
      end

    Enum.join(header ++ body, "\n")
  end

  defp format_check_report(comparison, :json) do
    Jason.encode!(comparison, pretty: true)
  end

  defp render_change_groups(grouped) do
    [:breaking, :potentially_breaking, :compatible, :metadata_only]
    |> Enum.flat_map(fn class ->
      case Map.get(grouped, class) do
        nil -> []
        changes -> render_change_class(class, changes)
      end
    end)
  end

  defp render_change_class(class, changes) do
    [
      Atom.to_string(class) <> ":"
      | Enum.map(changes, fn c -> "  #{c.tool}: #{c.change} — #{c.detail}" end)
    ] ++ [""]
  end

  defp doctor_cmd(args) do
    case parse_command_options(args, [], [], "doctor") do
      {:ok, _opts} -> run_doctor()
      {:error, code} -> code
    end
  end

  defp run_doctor do
    checks = run_doctor_checks()

    IO.puts("Nyanform Doctor")
    IO.puts(String.duplicate("=", 40))

    Enum.each(checks, fn check ->
      status = if check.ok, do: "OK", else: "FAIL"
      IO.puts("  [#{status}] #{check.name}: #{check.message}")
    end)

    if Enum.all?(checks, & &1.ok), do: 0, else: 1
  end

  defp run_doctor_checks do
    [
      check_elixir_version(),
      check_configuration(),
      check_profiles(),
      check_protocols()
    ]
  end

  defp check_elixir_version do
    version = System.version()
    %{ok: true, name: "Elixir version", message: version}
  end

  defp check_configuration do
    case Application.fetch_env(:nyanform, :protocol_revision) do
      {:ok, revision} ->
        %{ok: true, name: "Configuration", message: "protocol revision #{revision}"}

      :error ->
        %{ok: false, name: "Configuration", message: "protocol revision not configured"}
    end
  end

  defp check_profiles do
    names = Builtins.names()
    expected = ~w(canonical claude gemini openai_strict vscode passthrough)

    if Enum.all?(expected, &(&1 in names)) do
      %{ok: true, name: "Compatibility profiles", message: "#{length(names)} profiles available"}
    else
      %{ok: false, name: "Compatibility profiles", message: "missing expected profiles"}
    end
  end

  defp check_protocols do
    revisions = Lifecycle.supported_revisions()

    if "2025-11-25" in revisions do
      %{ok: true, name: "Protocol support", message: "revisions: #{Enum.join(revisions, ", ")}"}
    else
      %{ok: false, name: "Protocol support", message: "2025-11-25 not supported"}
    end
  end

  defp help do
    IO.puts("""
    Nyanform — Inspect and adapt MCP tool schemas across client boundaries.

    Usage: nyanform <command> [options]

    Commands:
      serve      Run as a proxy between a client and an upstream MCP server
      inspect    Connect to a server, validate schemas, print a report
      matrix     Compile a server against every compatibility profile
      snapshot   Save selected catalog fields with canonical input digests
      check      Compare a live server with a stored snapshot
      doctor     Check configuration and environment

    Use --help with any command for details.
    """)

    0
  end

  defp command_help("serve") do
    print_command_help("""
    Usage: nyanform serve [options]

    Run a downstream stdio or HTTP proxy for an upstream MCP server.

      --config PATH                 Load JSON configuration
      --profile NAME               Compatibility profile (default: canonical)
      --policy POLICY              strict, compatible, or permissive
      --stdio-command COMMAND      Upstream executable
      --stdio-arg ARG              Repeat for each upstream argument
      --http-endpoint URL          Upstream HTTP endpoint
      --downstream-transport TYPE  stdio or http (default: stdio)
      --host HOST                  HTTP listen host (default: 127.0.0.1)
      --port PORT                  HTTP listen port (default: 8080)
      --allowed-origin ORIGIN      Repeat for each accepted HTTP Origin
      --env KEY=VALUE              Repeat for each upstream environment value
      --timeout MILLISECONDS       Upstream request timeout
    """)
  end

  defp command_help("inspect") do
    print_command_help("""
    Usage: nyanform inspect [upstream options] [options]

      --stdio-command COMMAND  Upstream executable
      --stdio-arg ARG          Repeat for each upstream argument
      --http-endpoint URL      Upstream HTTP endpoint
      --profile NAME           Compatibility profile (default: canonical)
      --policy POLICY          strict, compatible, or permissive
      --format FORMAT          terminal or json
      --output PATH            Write the report to a file
    """)
  end

  defp command_help("matrix") do
    print_command_help("""
    Usage: nyanform matrix [upstream options] [options]

      --stdio-command COMMAND  Upstream executable
      --stdio-arg ARG          Repeat for each upstream argument
      --http-endpoint URL      Upstream HTTP endpoint
      --profile NAME           Repeat to select profiles; default is all
      --policy POLICY          strict, compatible, or permissive
      --format FORMAT          terminal, json, junit, or sarif
      --output PATH            Write the report to a file
      --[no-]fail-on-rejected  Fail when any projection is rejected
      --[no-]fail-on-lossy     Fail when any lossy omen is present
    """)
  end

  defp command_help("snapshot") do
    print_command_help("""
    Usage: nyanform snapshot [upstream options] [options]

      --stdio-command COMMAND  Upstream executable
      --stdio-arg ARG          Repeat for each upstream argument
      --http-endpoint URL      Upstream HTTP endpoint
      --output PATH            Write the snapshot to a file
    """)
  end

  defp command_help("check") do
    print_command_help("""
    Usage: nyanform check --snapshot PATH [upstream options] [options]

      --snapshot PATH          Stored snapshot to compare
      --stdio-command COMMAND  Upstream executable
      --stdio-arg ARG          Repeat for each upstream argument
      --http-endpoint URL      Upstream HTTP endpoint
      --format FORMAT          terminal or json
    """)
  end

  defp command_help("doctor") do
    print_command_help("""
    Usage: nyanform doctor

    Check the local runtime, configuration, profiles, and protocol support.
    """)
  end

  defp print_command_help(text) do
    IO.puts(text)
    0
  end

  defp parse_command_options(args, switches, aliases, command) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: switches, aliases: aliases)

    cond do
      invalid != [] ->
        {:error, usage_error("invalid #{command} option", inspect(invalid))}

      positional != [] ->
        {:error, usage_error("unexpected #{command} argument", Enum.join(positional, " "))}

      true ->
        {:ok, opts}
    end
  end

  defp build_cli_upstream(opts) do
    commands = Keyword.get_values(opts, :stdio_command)
    args = Keyword.get_values(opts, :stdio_arg)
    endpoint = Keyword.get(opts, :http_endpoint)

    cond do
      commands != [] and endpoint != nil ->
        {:error, :multiple_upstreams}

      commands != [] ->
        {:ok,
         %{
           transport: :stdio,
           command: commands ++ args,
           endpoint: nil,
           env: nil,
           timeout_ms: 15_000
         }}

      args != [] ->
        {:error, :stdio_arg_without_command}

      endpoint != nil ->
        {:ok, %{transport: :http, command: nil, endpoint: endpoint, env: nil, timeout_ms: 15_000}}

      true ->
        {:error, :missing_upstream}
    end
  end

  defp parse_policy(policy) when policy in ["strict", :strict], do: {:ok, :strict}
  defp parse_policy(policy) when policy in ["compatible", :compatible], do: {:ok, :compatible}
  defp parse_policy(policy) when policy in ["permissive", :permissive], do: {:ok, :permissive}
  defp parse_policy(policy), do: {:error, {:unknown_policy, policy}}

  defp fetch_profile(profile) do
    case Builtins.fetch(profile) do
      {:ok, constellation} -> {:ok, constellation}
      :error -> {:error, {:unknown_profile, profile}}
    end
  end

  defp validate_profile("auto", true), do: :ok

  defp validate_profile(profile, _allow_auto) do
    case fetch_profile(profile) do
      {:ok, _constellation} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp selected_profiles(opts) do
    case Keyword.get_values(opts, :profile) do
      [] -> Builtins.names()
      profiles -> profiles
    end
  end

  defp validate_profiles(profiles) do
    case Enum.find(profiles, &(Builtins.fetch(&1) == :error)) do
      nil -> :ok
      profile -> {:error, {:unknown_profile, profile}}
    end
  end

  defp required_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp usage_error(message, detail) do
    IO.write(:stderr, "nyanform: #{message}: #{detail}\n")
    IO.write(:stderr, "Run 'nyanform --help' for usage.\n")
    2
  end

  defp error_exit(code, message) do
    IO.write(:stderr, "nyanform [#{code}]: #{message}\n")
    exit({:shutdown, 1})
  end

  defp format_error(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
