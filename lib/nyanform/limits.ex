defmodule Nyanform.Limits do
  @type t :: %__MODULE__{
          max_message_size: pos_integer(),
          max_schema_depth: pos_integer(),
          max_reference_depth: pos_integer(),
          max_tool_count: pos_integer(),
          max_concurrent_compilation: pos_integer(),
          max_http_body_size: pos_integer(),
          max_diagnostic_count: pos_integer(),
          request_timeout_ms: pos_integer()
        }

  defstruct [
    :max_message_size,
    :max_schema_depth,
    :max_reference_depth,
    :max_tool_count,
    :max_concurrent_compilation,
    :max_http_body_size,
    :max_diagnostic_count,
    :request_timeout_ms
  ]

  @spec default() :: t()
  def default do
    %__MODULE__{
      max_message_size: Application.fetch_env!(:nyanform, :max_message_size),
      max_schema_depth: Application.fetch_env!(:nyanform, :max_schema_depth),
      max_reference_depth: Application.fetch_env!(:nyanform, :max_reference_depth),
      max_tool_count: Application.fetch_env!(:nyanform, :max_tool_count),
      max_concurrent_compilation: Application.fetch_env!(:nyanform, :max_concurrent_compilation),
      max_http_body_size: Application.fetch_env!(:nyanform, :max_http_body_size),
      max_diagnostic_count: Application.fetch_env!(:nyanform, :max_diagnostic_count),
      request_timeout_ms: Application.fetch_env!(:nyanform, :request_timeout_ms)
    }
  end

  @spec from_config(map()) :: t()
  def from_config(config) when is_map(config) do
    default()
    |> maybe_override(config, "max_message_size", :max_message_size)
    |> maybe_override(config, "max_schema_depth", :max_schema_depth)
    |> maybe_override(config, "max_reference_depth", :max_reference_depth)
    |> maybe_override(config, "max_tool_count", :max_tool_count)
    |> maybe_override(config, "max_concurrent_compilation", :max_concurrent_compilation)
    |> maybe_override(config, "max_http_body_size", :max_http_body_size)
    |> maybe_override(config, "max_diagnostic_count", :max_diagnostic_count)
    |> maybe_override(config, "request_timeout_ms", :request_timeout_ms)
  end

  defp maybe_override(limits, config, key, field) do
    case Map.fetch(config, key) do
      {:ok, value} when is_integer(value) and value > 0 -> %{limits | field => value}
      _ -> limits
    end
  end
end
