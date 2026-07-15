defmodule Nyanform.Profile.Builtins do
  alias Nyanform.Profile.Constellation

  @spec all() :: %{String.t() => Constellation.t()}
  def all do
    %{
      "canonical" => canonical(),
      "claude" => claude(),
      "gemini" => gemini(),
      "openai_strict" => openai_strict(),
      "vscode" => vscode(),
      "passthrough" => passthrough()
    }
  end

  @spec names() :: [String.t()]
  def names do
    Map.keys(all())
  end

  @spec fetch(String.t()) :: {:ok, Constellation.t()} | :error
  def fetch(name) do
    Map.fetch(all(), name)
  end

  defp canonical do
    %Constellation{
      name: "canonical",
      label: "Nyanform normalized",
      description: "Nyanform's modeled JSON Schema projection for MCP tools",
      accepted_keywords:
        MapSet.new(~w(type properties required additionalProperties patternProperties
          items additionalItems minItems maxItems uniqueItems description title
          default examples format pattern minLength maxLength enum const
          minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
          minProperties maxProperties oneOf anyOf allOf $ref $defs definitions)),
      supported_combinators: MapSet.new([:oneOf, :anyOf, :allOf]),
      reference_support: :full,
      nullable_representation: :type_array,
      requires_all_properties_required: false,
      accepts_additional_properties: true,
      supports_additional_properties_false: true,
      supported_array_forms: MapSet.new([:homogeneous, :tuple, :no_items]),
      supported_enum_forms: MapSet.new([:homogeneous, :mixed, :empty]),
      max_schema_depth: :unlimited,
      tool_name_pattern: "^[a-zA-Z0-9_.-]{1,128}$",
      max_tool_name_length: 128,
      supports_const: true,
      supports_pattern_properties: true
    }
  end

  defp claude do
    %Constellation{
      name: "claude",
      label: "Claude Code",
      description:
        "Nyanform compatibility profile for Claude Code. Not an official Anthropic specification.",
      accepted_keywords: MapSet.new(~w(type properties required additionalProperties
          items description title enum const
          minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
          minItems maxItems uniqueItems minLength maxLength pattern format
          oneOf anyOf allOf $ref $defs)),
      supported_combinators: MapSet.new([:oneOf, :anyOf, :allOf]),
      reference_support: :local_only,
      nullable_representation: :type_array,
      requires_all_properties_required: false,
      accepts_additional_properties: true,
      supports_additional_properties_false: true,
      supported_array_forms: MapSet.new([:homogeneous, :tuple]),
      supported_enum_forms: MapSet.new([:homogeneous, :mixed]),
      max_schema_depth: :unlimited,
      tool_name_pattern: "^[a-zA-Z0-9_-]{1,64}$",
      max_tool_name_length: 64,
      supports_const: true,
      supports_pattern_properties: false
    }
  end

  defp gemini do
    %Constellation{
      name: "gemini",
      label: "Gemini CLI",
      description:
        "Nyanform compatibility hypothesis informed by documented Gemini CLI MCP sanitization.",
      accepted_keywords: MapSet.new(~w(type properties required additionalProperties
          items description enum format
          minimum maximum minLength maxLength
          oneOf anyOf $ref $defs)),
      supported_combinators: MapSet.new([:oneOf, :anyOf]),
      reference_support: :local_only,
      nullable_representation: :type_array,
      requires_all_properties_required: false,
      accepts_additional_properties: true,
      supports_additional_properties_false: true,
      supported_array_forms: MapSet.new([:homogeneous]),
      supported_enum_forms: MapSet.new([:homogeneous]),
      max_schema_depth: :unlimited,
      tool_name_pattern: "^[a-zA-Z0-9_.:-]{1,63}$",
      max_tool_name_length: 63,
      integer_vs_number_distinguished: true,
      supports_const: false,
      supports_pattern_properties: false
    }
  end

  defp openai_strict do
    %Constellation{
      name: "openai_strict",
      label: "OpenAI strict function tools",
      description:
        "Nyanform compatibility profile for OpenAI strict function-calling tools. Not an official OpenAI specification.",
      accepted_keywords: MapSet.new(~w(type properties required additionalProperties
          items description enum
          minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
          minItems maxItems pattern format anyOf $ref $defs)),
      supported_combinators: MapSet.new([:anyOf]),
      reference_support: :local_only,
      nullable_representation: :type_array,
      requires_all_properties_required: true,
      requires_additional_properties_false: true,
      requires_root_object: true,
      accepts_additional_properties: true,
      supports_additional_properties_false: true,
      supported_array_forms: MapSet.new([:homogeneous]),
      supported_enum_forms: MapSet.new([:homogeneous]),
      max_schema_depth: :unlimited,
      max_object_depth: 10,
      supported_formats:
        MapSet.new(~w(date-time time date duration email hostname ipv4 ipv6 uuid)),
      tool_name_pattern: "^[a-zA-Z0-9_-]{1,64}$",
      max_tool_name_length: 64,
      integer_vs_number_distinguished: true,
      supports_const: false,
      supports_pattern_properties: false
    }
  end

  defp vscode do
    %Constellation{
      name: "vscode",
      label: "VS Code MCP",
      description:
        "Nyanform compatibility profile for VS Code MCP integration. Not an official Microsoft specification.",
      accepted_keywords: MapSet.new(~w(type properties required additionalProperties
          items description title enum const format pattern
          minLength maxLength minimum maximum multipleOf
          oneOf anyOf allOf $ref $defs)),
      supported_combinators: MapSet.new([:oneOf, :anyOf, :allOf]),
      reference_support: :local_only,
      nullable_representation: :type_array,
      requires_all_properties_required: false,
      accepts_additional_properties: true,
      supports_additional_properties_false: true,
      supported_array_forms: MapSet.new([:homogeneous, :tuple]),
      supported_enum_forms: MapSet.new([:homogeneous, :mixed]),
      max_schema_depth: :unlimited,
      tool_name_pattern: "^[a-zA-Z0-9_.-]{1,128}$",
      max_tool_name_length: 128,
      supports_const: true,
      supports_pattern_properties: false
    }
  end

  defp passthrough do
    %Constellation{
      name: "passthrough",
      label: "Passthrough",
      description: "Raw schema projection after structural compilation",
      accepted_keywords:
        MapSet.new(~w(type properties required additionalProperties patternProperties
          items additionalItems minItems maxItems uniqueItems description title
          default examples format pattern minLength maxLength enum const
          minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
          minProperties maxProperties oneOf anyOf allOf $ref $defs definitions)),
      supported_combinators: MapSet.new([:oneOf, :anyOf, :allOf]),
      reference_support: :full,
      nullable_representation: :type_array,
      requires_all_properties_required: false,
      accepts_additional_properties: true,
      supports_additional_properties_false: true,
      supported_array_forms: MapSet.new([:homogeneous, :tuple, :no_items]),
      supported_enum_forms: MapSet.new([:homogeneous, :mixed, :empty]),
      max_schema_depth: :unlimited,
      tool_name_pattern: "^[a-zA-Z0-9_.-]{1,128}$",
      max_tool_name_length: 128,
      supports_const: true,
      supports_pattern_properties: true
    }
  end
end
