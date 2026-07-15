defmodule Nyanform.ToolGrimoire do
  alias Nyanform.Diagnostic.Omen
  alias Nyanform.Profile.{Constellation, Projector}
  alias Nyanform.Schema.Pipeline

  @type tool_entry :: %{
          name: String.t(),
          alias: String.t(),
          description: String.t() | nil,
          input_schema: term(),
          projected_schema: term(),
          digest: String.t() | nil,
          accepted: boolean(),
          publishable: boolean(),
          omens: [Omen.t()]
        }

  @type grimoire :: %__MODULE__{
          entries: [tool_entry()],
          alias_map: %{String.t() => String.t()},
          omens: [Omen.t()]
        }

  defstruct entries: [], alias_map: %{}, omens: []

  @spec build([map()], Constellation.t(), atom()) :: grimoire()
  def build(tools, %Constellation{} = profile, policy) when is_list(tools) do
    {entries, alias_map, omens} = compile_page(tools, profile, policy, %{})
    %__MODULE__{entries: entries, alias_map: alias_map, omens: omens}
  end

  def build(_tools, %Constellation{} = profile, _policy) do
    %__MODULE__{omens: [invalid_catalog_omen(profile)]}
  end

  @spec append(grimoire(), [map()], Constellation.t(), atom()) :: grimoire()
  def append(%__MODULE__{} = grimoire, tools, %Constellation{} = profile, policy)
      when is_list(tools) do
    {page_entries, _alias_map, _omens} =
      compile_page(tools, profile, policy, grimoire.alias_map)

    entries = merge_entries(grimoire.entries, page_entries)

    alias_map =
      entries
      |> Enum.filter(&(&1.publishable and (&1.accepted or policy == :permissive)))
      |> Map.new(&{&1.alias, &1.name})

    %__MODULE__{
      entries: entries,
      alias_map: alias_map,
      omens: Enum.flat_map(entries, & &1.omens)
    }
  end

  def append(%__MODULE__{} = grimoire, _tools, %Constellation{} = profile, _policy) do
    %{grimoire | omens: grimoire.omens ++ [invalid_catalog_omen(profile)]}
  end

  defp merge_entries(existing, page_entries) do
    replacements = Map.new(page_entries, &{&1.name, &1})
    existing_names = MapSet.new(existing, & &1.name)

    replaced = Enum.map(existing, &Map.get(replacements, &1.name, &1))
    additions = Enum.reject(page_entries, &MapSet.member?(existing_names, &1.name))

    replaced ++ additions
  end

  defp compile_page(tools, profile, policy, alias_map) do
    prepared_tools =
      tools
      |> Enum.with_index()
      |> Enum.sort_by(fn {tool, index} -> alias_priority(tool, profile, index) end)

    {indexed_entries, alias_map, indexed_omens} =
      Enum.reduce(prepared_tools, {[], alias_map, []}, fn {tool, index},
                                                          {entries_acc, map_acc, omens_acc} ->
        {entry, map_acc, tool_omens} = process_tool(tool, profile, policy, map_acc)
        {[{index, entry} | entries_acc], map_acc, [{index, tool_omens} | omens_acc]}
      end)

    entries = indexed_entries |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    omens = indexed_omens |> Enum.sort_by(&elem(&1, 0)) |> Enum.flat_map(&elem(&1, 1))

    {entries, alias_map, omens}
  end

  defp alias_priority(%{"name" => original}, profile, index) when is_binary(original) do
    {sanitized, omen} = sanitize_name(original, profile)
    transformed = if is_nil(omen), do: 0, else: 1
    {sanitized, transformed, original, index}
  end

  defp alias_priority(tool, _profile, index), do: {"", 2, invalid_tool_label(tool), index}

  @spec resolve_origin(grimoire(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def resolve_origin(%__MODULE__{} = grimoire, alias_name) do
    case Map.fetch(grimoire.alias_map, alias_name) do
      {:ok, origin} -> {:ok, origin}
      :error -> {:error, :not_found}
    end
  end

  @spec list_aliases(grimoire()) :: [tool_entry()]
  def list_aliases(%__MODULE__{entries: entries}), do: entries

  defp process_tool(%{"name" => original_name} = tool, profile, policy, current_map)
       when is_binary(original_name) and is_map_key(tool, "inputSchema") do
    description = Map.get(tool, "description")
    input_schema = Map.get(tool, "inputSchema", %{})

    {sanitized, sanitize_omen} = sanitize_name(original_name, profile)

    {alias, alias_omen, updated_map} =
      ensure_unique(sanitized, original_name, current_map, profile)

    {digest, projected_schema, compile_omens, accepted} =
      case Pipeline.compile(input_schema) do
        {:ok, result} ->
          projection = Projector.project(result.scroll, profile, policy)

          {result.digest, projection.schema, result.omens ++ projection.omens,
           projection.accepted}

        {:error, _error} ->
          {nil, input_schema,
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
      (Enum.filter([sanitize_omen, alias_omen], &(&1 != nil)) ++ compile_omens)
      |> Enum.map(fn omen ->
        %{omen | tool: omen.tool || original_name, profile: omen.profile || profile.name}
      end)

    accepted = accepted and policy_accepts?(policy, omens)

    entry = %{
      name: original_name,
      alias: alias,
      description: description,
      input_schema: input_schema,
      projected_schema: projected_schema,
      digest: digest,
      accepted: accepted,
      publishable: true,
      omens: omens
    }

    updated_map =
      if accepted or policy == :permissive,
        do: Map.put(updated_map, alias, original_name),
        else: updated_map

    {entry, updated_map, omens}
  end

  defp process_tool(tool, profile, _policy, current_map) do
    name = invalid_tool_label(tool)

    omen =
      Omen.rejected("NYA-SCHEMA-001",
        schema_path: [],
        rule: "invalid_tool_definition",
        source: "tools/list entry",
        target: nil,
        explanation: "tool definition requires a string name and inputSchema",
        action: "fix the upstream tool definition",
        tool: name,
        profile: profile.name
      )

    entry = %{
      name: name,
      alias: name,
      description: nil,
      input_schema: if(is_map(tool), do: Map.get(tool, "inputSchema"), else: tool),
      projected_schema: nil,
      digest: nil,
      accepted: false,
      publishable: false,
      omens: [omen]
    }

    {entry, current_map, [omen]}
  end

  defp invalid_tool_label(%{"name" => name}) when is_binary(name), do: name

  defp invalid_tool_label(tool) do
    suffix = tool |> :erlang.term_to_binary() |> then(&:crypto.hash(:sha256, &1))
    suffix = Base.encode16(suffix, case: :lower)

    "invalid_tool_" <> String.slice(suffix, 0, 8)
  end

  defp invalid_catalog_omen(profile) do
    Omen.rejected("NYA-SCHEMA-001",
      schema_path: [],
      rule: "invalid_tools_catalog",
      source: "tools",
      target: nil,
      explanation: "tools/list result must contain a list of tool definitions",
      action: "fix the upstream tools/list response",
      profile: profile.name
    )
  end

  defp sanitize_name(
         name,
         %Constellation{tool_name_pattern: pattern, max_tool_name_length: max_length}
       )
       when is_binary(name) do
    regex = Regex.compile!(pattern)

    if Regex.match?(regex, name) and fits_length?(name, max_length) do
      {name, nil}
    else
      sanitized =
        name
        |> sanitize_chars(~r/[^a-zA-Z0-9_.-]/)
        |> fit_name(max_length)

      sanitized =
        if Regex.match?(regex, sanitized) do
          sanitized
        else
          name
          |> sanitize_chars(~r/[^a-zA-Z0-9_-]/)
          |> fit_name(max_length)
        end

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
        fallback = name |> derive_fallback_name() |> fit_name(max_length)

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

  defp sanitize_chars(name, pattern) do
    name
    |> String.replace(pattern, "_")
    |> String.trim("_")
  end

  defp fits_length?(_name, :unlimited), do: true
  defp fits_length?(name, max), do: String.length(name) <= max

  defp fit_name(name, :unlimited), do: name
  defp fit_name(name, max), do: String.slice(name, 0, max)

  defp derive_fallback_name(name) do
    digest = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower) |> String.slice(0, 8)
    "tool_" <> digest
  end

  defp ensure_unique(sanitized, original, current_map, profile) do
    case Map.get(current_map, sanitized) do
      ^original ->
        {sanitized, nil, current_map}

      nil ->
        {sanitized, nil, current_map}

      _other ->
        alias = unique_alias(sanitized, original, current_map, profile.max_tool_name_length, 0)

        omen =
          Omen.normalized("NYA-ALIAS-002",
            schema_path: [],
            rule: "collision_suffix_added",
            source: original,
            target: alias,
            explanation: "tool name collided after sanitization; deterministic suffix added"
          )

        {alias, omen, current_map}
    end
  end

  defp unique_alias(base, original, current_map, max_length, attempt) do
    digest =
      :crypto.hash(:sha256, "#{original}:#{attempt}")
      |> Base.encode16(case: :lower)
      |> String.slice(0, 8)

    suffix = "_" <> digest
    candidate = append_suffix(base, suffix, max_length)

    case Map.get(current_map, candidate) do
      ^original -> candidate
      nil -> candidate
      _other -> unique_alias(base, original, current_map, max_length, attempt + 1)
    end
  end

  defp append_suffix(base, suffix, :unlimited), do: base <> suffix

  defp append_suffix(base, suffix, max_length) do
    prefix_length = max(max_length - String.length(suffix), 0)
    String.slice(base, 0, prefix_length) <> String.slice(suffix, 0, max_length - prefix_length)
  end

  defp policy_accepts?(:strict, omens) do
    not Enum.any?(omens, &(&1.severity in [:lossy, :rejected]))
  end

  defp policy_accepts?(:compatible, omens) do
    not Enum.any?(omens, &(&1.severity == :rejected))
  end

  defp policy_accepts?(:permissive, _omens), do: true
end
