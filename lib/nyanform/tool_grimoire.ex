defmodule Nyanform.ToolGrimoire do
  alias Nyanform.Diagnostic.Omen
  alias Nyanform.Profile.Constellation
  alias Nyanform.Schema.Pipeline

  @type tool_entry :: %{
          name: String.t(),
          alias: String.t(),
          description: String.t() | nil,
          input_schema: map(),
          digest: String.t(),
          accepted: boolean()
        }

  @type grimoire :: %__MODULE__{
          entries: [tool_entry()],
          alias_map: %{String.t() => String.t()},
          omens: [Omen.t()]
        }

  defstruct entries: [], alias_map: %{}, omens: []

  @spec build([map()], Constellation.t(), atom()) :: grimoire()
  def build(tools, %Constellation{} = profile, policy) do
    {entries, alias_map, omens} =
      Enum.reduce(tools, {[], %{}, []}, fn tool, {entries_acc, map_acc, omens_acc} ->
        {entry, map_acc, tool_omens} = process_tool(tool, profile, policy, map_acc)
        {entries_acc ++ [entry], map_acc, omens_acc ++ tool_omens}
      end)

    %__MODULE__{entries: entries, alias_map: alias_map, omens: omens}
  end

  @spec resolve_origin(grimoire(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def resolve_origin(%__MODULE__{} = grimoire, alias_name) do
    case Map.fetch(grimoire.alias_map, alias_name) do
      {:ok, origin} -> {:ok, origin}
      :error -> {:error, :not_found}
    end
  end

  @spec list_aliases(grimoire()) :: [tool_entry()]
  def list_aliases(%__MODULE__{entries: entries}), do: entries

  defp process_tool(tool, profile, policy, current_map) do
    original_name = Map.get(tool, "name", "")
    description = Map.get(tool, "description")
    input_schema = Map.get(tool, "inputSchema", %{})

    {sanitized, sanitize_omen} = sanitize_name(original_name, profile)
    {alias, alias_omen, updated_map} = ensure_unique(sanitized, original_name, current_map)

    {digest, compile_omens, accepted} =
      case Pipeline.compile(input_schema) do
        {:ok, result} ->
          {result.digest, result.omens, true}

        {:error, _error} ->
          {nil,
           [
             Omen.rejected("NYA-SCHEMA-001",
               schema_path: [],
               rule: "schema_validation_failed",
               source: "inputSchema",
               target: nil,
               explanation: "tool schema failed structural validation",
               action: "fix the schema or exclude this tool",
               tool: original_name
             )
           ], false}
      end

    omens =
      Enum.filter([sanitize_omen, alias_omen], &(&1 != nil)) ++ compile_omens

    entry = %{
      name: original_name,
      alias: alias,
      description: description,
      input_schema: input_schema,
      digest: digest,
      accepted: accepted and policy_accepts?(policy, omens)
    }

    updated_map = Map.put(updated_map, alias, original_name)
    {entry, updated_map, omens}
  end

  defp sanitize_name(name, %Constellation{tool_name_pattern: pattern})
       when is_binary(name) do
    regex = Regex.compile!(pattern)

    if Regex.match?(regex, name) do
      {name, nil}
    else
      sanitized = sanitize_chars(name)

      if Regex.match?(regex, sanitized) do
        {sanitized,
         Omen.normalized("NYA-ALIAS-001",
           schema_path: [],
           rule: "name_sanitized",
           source: name,
           target: sanitized,
           explanation: "tool name sanitized to match profile pattern"
         )}
      else
        fallback = derive_fallback_name(name)

        {fallback,
         Omen.normalized("NYA-ALIAS-001",
           schema_path: [],
           rule: "name_sanitized",
           source: name,
           target: fallback,
           explanation: "tool name could not match profile pattern; derived fallback"
         )}
      end
    end
  end

  defp sanitize_name(name, _profile), do: {name, nil}

  defp sanitize_chars(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> String.trim("_")
  end

  defp derive_fallback_name(name) do
    digest = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower) |> String.slice(0, 8)
    "tool_" <> digest
  end

  defp ensure_unique(sanitized, original, current_map) do
    if Map.has_key?(current_map, sanitized) do
      digest =
        :crypto.hash(:sha256, original) |> Base.encode16(case: :lower) |> String.slice(0, 6)

      alias = "#{sanitized}_#{digest}"

      omen =
        Omen.normalized("NYA-ALIAS-002",
          schema_path: [],
          rule: "collision_suffix_added",
          source: original,
          target: alias,
          explanation: "tool name collided after sanitization; deterministic suffix added"
        )

      {alias, omen, current_map}
    else
      {sanitized, nil, current_map}
    end
  end

  defp policy_accepts?(:strict, omens) do
    not Enum.any?(omens, &(&1.severity in [:lossy, :rejected]))
  end

  defp policy_accepts?(:compatible, omens) do
    not Enum.any?(omens, &(&1.severity == :rejected))
  end

  defp policy_accepts?(:permissive, _omens), do: true
end
