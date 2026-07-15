defmodule Nyanform.Config.Loader do
  @type config :: %{
          downstream: %{
            transport: :stdio | :http,
            port: pos_integer() | nil,
            host: String.t() | nil,
            allowed_origins: [String.t()]
          },
          upstream: %{
            transport: :stdio | :http,
            command: [String.t()] | nil,
            endpoint: String.t() | nil,
            env: %{String.t() => String.t()} | nil
          },
          profile: String.t(),
          policy: :strict | :compatible | :permissive,
          env_allowlist: [String.t()],
          timeout_ms: pos_integer(),
          max_message_size: pos_integer(),
          max_http_body_size: pos_integer(),
          logging: :quiet | :normal | :verbose,
          tool_include: [String.t()] | nil,
          tool_exclude: [String.t()] | nil
        }

  @spec load_file(Path.t()) :: {:ok, config()} | {:error, term()}
  def load_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, decoded} -> validate(decoded)
          {:error, reason} -> {:error, {:invalid_json, Exception.message(reason)}}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  @spec load_map(map()) :: {:ok, config()} | {:error, term()}
  def load_map(map) when is_map(map) do
    validate(map)
  end

  def load_map(value), do: {:error, {:invalid_config, value}}

  defp validate(decoded) when is_map(decoded) do
    with {:ok, downstream} <- validate_downstream(Map.get(decoded, "downstream")),
         {:ok, upstream} <- validate_upstream(Map.get(decoded, "upstream")),
         {:ok, profile} <- validate_profile(Map.get(decoded, "profile", "canonical")),
         {:ok, policy} <- validate_policy(Map.get(decoded, "policy", "strict")),
         {:ok, env_allowlist} <-
           validate_string_list(Map.get(decoded, "envAllowlist", []), :env_allowlist),
         {:ok, timeout_ms} <-
           validate_positive_integer(Map.get(decoded, "timeoutMs", 30_000), :timeout_ms),
         {:ok, max_message_size} <-
           validate_positive_integer(
             Map.get(decoded, "maxMessageSize", 1_048_576),
             :max_message_size
           ),
         {:ok, max_http_body_size} <-
           validate_positive_integer(
             Map.get(decoded, "maxHttpBodySize", 4_194_304),
             :max_http_body_size
           ),
         {:ok, logging} <- validate_logging(Map.get(decoded, "logging", "normal")),
         {:ok, tool_include} <-
           validate_optional_string_list(Map.get(decoded, "toolInclude"), :tool_include),
         {:ok, tool_exclude} <-
           validate_optional_string_list(Map.get(decoded, "toolExclude"), :tool_exclude) do
      {:ok,
       %{
         downstream: downstream,
         upstream: upstream,
         profile: profile,
         policy: policy,
         env_allowlist: env_allowlist,
         timeout_ms: timeout_ms,
         max_message_size: max_message_size,
         max_http_body_size: max_http_body_size,
         logging: logging,
         tool_include: tool_include,
         tool_exclude: tool_exclude
       }}
    end
  end

  defp validate(decoded), do: {:error, {:invalid_config, decoded}}

  defp validate_downstream(nil),
    do: {:ok, %{transport: :stdio, port: nil, host: nil, allowed_origins: []}}

  defp validate_downstream(%{"transport" => "stdio"} = map) do
    with {:ok, allowed_origins} <-
           validate_string_list(Map.get(map, "allowedOrigins", []), :allowed_origins) do
      {:ok, %{transport: :stdio, port: nil, host: nil, allowed_origins: allowed_origins}}
    end
  end

  defp validate_downstream(%{"transport" => "http"} = map) do
    port = Map.get(map, "port", 8080)
    host = Map.get(map, "host", "127.0.0.1")

    with :ok <- validate_port(port),
         :ok <- validate_host(host),
         {:ok, allowed_origins} <-
           validate_string_list(Map.get(map, "allowedOrigins", []), :allowed_origins) do
      {:ok, %{transport: :http, port: port, host: host, allowed_origins: allowed_origins}}
    end
  end

  defp validate_downstream(%{"transport" => transport}) do
    {:error, {:invalid_downstream_transport, transport}}
  end

  defp validate_downstream(value), do: {:error, {:invalid_downstream, value}}

  defp validate_upstream(%{"transport" => "stdio", "endpoint" => _endpoint}) do
    {:error, {:conflicting_upstream_source, :endpoint}}
  end

  defp validate_upstream(%{"transport" => "stdio", "command" => command} = map)
       when is_list(command) do
    with :ok <- validate_command(command),
         {:ok, env} <- validate_env(Map.get(map, "env")) do
      {:ok, %{transport: :stdio, command: command, endpoint: nil, env: env}}
    end
  end

  defp validate_upstream(%{"transport" => "stdio"} = map) do
    {:error, {:invalid_upstream_command, Map.get(map, "command")}}
  end

  defp validate_upstream(%{"transport" => "http", "command" => _command}) do
    {:error, {:conflicting_upstream_source, :command}}
  end

  defp validate_upstream(%{"transport" => "http", "endpoint" => endpoint})
       when is_binary(endpoint) and byte_size(endpoint) > 0 do
    {:ok, %{transport: :http, command: nil, endpoint: endpoint, env: nil}}
  end

  defp validate_upstream(%{"transport" => "http"} = map) do
    {:error, {:missing_endpoint, Map.get(map, "endpoint")}}
  end

  defp validate_upstream(%{"transport" => transport}) do
    {:error, {:invalid_upstream_transport, transport}}
  end

  defp validate_upstream(nil) do
    {:error, :missing_upstream}
  end

  defp validate_upstream(value), do: {:error, {:invalid_upstream, value}}

  defp validate_profile(profile)
       when profile in [
              "canonical",
              "claude",
              "gemini",
              "openai_strict",
              "vscode",
              "passthrough",
              "auto"
            ] do
    {:ok, profile}
  end

  defp validate_profile(profile) do
    {:error, {:unknown_profile, profile}}
  end

  defp validate_policy(policy) when policy in ["strict", "compatible", "permissive"] do
    {:ok, String.to_atom(policy)}
  end

  defp validate_policy(policy) when policy in [:strict, :compatible, :permissive] do
    {:ok, policy}
  end

  defp validate_policy(policy) do
    {:error, {:unknown_policy, policy}}
  end

  defp validate_env(nil), do: {:ok, nil}

  defp validate_env(env) when is_map(env) do
    if Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      {:ok, env}
    else
      {:error, {:invalid_upstream_env, :redacted}}
    end
  end

  defp validate_env(_env), do: {:error, {:invalid_upstream_env, :redacted}}

  defp validate_logging("quiet"), do: {:ok, :quiet}
  defp validate_logging("normal"), do: {:ok, :normal}
  defp validate_logging("verbose"), do: {:ok, :verbose}
  defp validate_logging(value), do: {:error, {:invalid_logging, value}}

  defp validate_port(port) when is_integer(port) and port in 1..65_535, do: :ok
  defp validate_port(port), do: {:error, {:invalid_downstream_port, port}}

  defp validate_host(host) when is_binary(host) and byte_size(host) > 0, do: :ok
  defp validate_host(host), do: {:error, {:invalid_downstream_host, host}}

  defp validate_command([command | args]) when is_binary(command) and byte_size(command) > 0 do
    if Enum.all?(args, &is_binary/1) do
      :ok
    else
      {:error, {:invalid_upstream_command, [command | args]}}
    end
  end

  defp validate_command(command), do: {:error, {:invalid_upstream_command, command}}

  defp validate_positive_integer(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp validate_positive_integer(value, field),
    do: {:error, {:invalid_positive_integer, field, value}}

  defp validate_string_list(value, field)
       when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: {:ok, value},
      else: {:error, {:invalid_string_list, field, value}}
  end

  defp validate_string_list(value, field),
    do: {:error, {:invalid_string_list, field, value}}

  defp validate_optional_string_list(nil, _field), do: {:ok, nil}
  defp validate_optional_string_list(value, field), do: validate_string_list(value, field)

  @spec to_upstream_config(config()) :: Nyanform.Transport.UpstreamShrine.transport_config()
  def to_upstream_config(config) do
    %{
      transport: config.upstream.transport,
      command: config.upstream.command,
      endpoint: config.upstream.endpoint,
      env: config.upstream.env,
      env_allowlist: config.env_allowlist,
      timeout_ms: config.timeout_ms,
      max_message_size: config.max_message_size
    }
  end
end
