defmodule Nyanform.Profile.Projector do
  alias Nyanform.Diagnostic.Omen
  alias Nyanform.Profile.Constellation
  alias Nyanform.Schema.{Reference, Scroll}

  @type policy :: :strict | :compatible | :permissive

  @type projection :: %{
          schema: map(),
          omens: [Omen.t()],
          accepted: boolean(),
          worst_severity: Omen.severity() | nil
        }

  @spec project(Scroll.t(), Constellation.t(), policy()) :: projection()
  def project(%Scroll{} = scroll, %Constellation{} = profile, policy) do
    {schema, omens} = project_scroll(scroll, profile, policy, [])
    {schema, def_omens} = project_definitions(schema, scroll.definitions, profile, policy)
    truncation_omens = collect_truncation_omens(scroll, profile, [])

    omens = (omens ++ def_omens ++ truncation_omens) |> Enum.reverse()
    accepted = policy_accepts?(policy, omens)
    worst = Omen.worst(omens)

    %{
      schema: schema,
      omens: omens,
      accepted: accepted,
      worst_severity: worst
    }
  end

  defp project_definitions(schema, nil, _profile, _policy), do: {schema, []}

  defp project_definitions(schema, defs, _profile, _policy) when map_size(defs) == 0,
    do: {schema, []}

  defp project_definitions(schema, defs, profile, policy) do
    if profile.reference_support == :none do
      omen =
        Omen.lossy("NYA-SCHEMA-012",
          schema_path: ["$defs"],
          rule: "definitions_dropped",
          source: "$defs",
          target: "$defs omitted",
          explanation: "profile does not support references; $defs definitions dropped",
          action: "inline references or select a profile that supports references"
        )

      {schema, [omen]}
    else
      {projected_defs, omens} =
        Enum.reduce(defs, {%{}, []}, fn {name, child_scroll}, {acc, acc_omens} ->
          {projected, child_omens} =
            project_scroll(child_scroll, profile, policy, ["$defs", name])

          {Map.put(acc, name, projected), acc_omens ++ child_omens}
        end)

      {Map.put(schema, "$defs", projected_defs), omens}
    end
  end

  defp policy_accepts?(:strict, omens) do
    not Enum.any?(omens, fn o -> o.severity in [:lossy, :rejected] end)
  end

  defp policy_accepts?(:compatible, omens) do
    not Enum.any?(omens, fn o -> o.severity == :rejected end)
  end

  defp policy_accepts?(:permissive, _omens), do: true

  defp project_scroll(%Scroll{kind: :object} = scroll, profile, policy, path) do
    {properties, prop_omens} = project_properties(scroll.properties, profile, policy, path)
    {required, req_omens} = project_required(scroll.required, properties, profile, path)

    {additional, addl_omens} =
      project_additional(scroll.additional_properties, profile, policy, path)

    {pattern_props, pat_omens} =
      project_pattern_properties(scroll.pattern_properties, profile, policy, path)

    schema = build_object_schema(scroll, properties, required, additional, pattern_props)
    {schema, enum_const_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_description(schema, scroll.description, profile)
    omens = prop_omens ++ req_omens ++ addl_omens ++ pat_omens ++ enum_const_omens
    {schema, omens}
  end

  defp project_scroll(%Scroll{kind: :array} = scroll, profile, policy, path) do
    {schema, omens} =
      cond do
        scroll.tuple_items != nil ->
          project_tuple_array(scroll, profile, policy, path)

        scroll.items != nil ->
          {items_schema, items_omens} =
            project_scroll(scroll.items, profile, policy, path ++ ["items"])

          schema = %{"type" => "array", "items" => items_schema}
          schema = maybe_put_int(schema, "minItems", scroll.min_items)
          schema = maybe_put_int(schema, "maxItems", scroll.max_items)
          schema = maybe_put_bool(schema, "uniqueItems", scroll.unique_items)
          {schema, items_omens}

        true ->
          omen = array_without_items_omen(path, profile, policy)
          schema = %{"type" => "array"}
          schema = maybe_put_int(schema, "minItems", scroll.min_items)
          schema = maybe_put_int(schema, "maxItems", scroll.max_items)
          schema = maybe_put_bool(schema, "uniqueItems", scroll.unique_items)
          {schema, [omen]}
      end

    {schema, enum_const_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_description(schema, scroll.description, profile)
    {schema, omens ++ enum_const_omens}
  end

  defp project_scroll(%Scroll{kind: :string} = scroll, profile, policy, path) do
    schema = %{"type" => "string"}

    schema =
      Enum.reduce(
        [
          {"minLength", scroll.min_length},
          {"maxLength", scroll.max_length},
          {"pattern", scroll.pattern},
          {"format", scroll.format}
        ],
        schema,
        fn {key, value}, acc ->
          if value != nil, do: Map.put(acc, key, value), else: acc
        end
      )

    {schema, ec_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_description(schema, scroll.description, profile)
    omens = format_omens(scroll.format, path, profile) ++ ec_omens
    {schema, omens}
  end

  defp project_scroll(%Scroll{kind: :integer} = scroll, profile, policy, path) do
    schema = numeric_schema("integer", scroll)
    {schema, ec_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_description(schema, scroll.description, profile)
    {schema, ec_omens}
  end

  defp project_scroll(%Scroll{kind: :number} = scroll, profile, policy, path) do
    {type, omens} =
      if profile.integer_vs_number_distinguished do
        {"number", []}
      else
        {"number",
         [
           Omen.normalized("NYA-PROFILE-002",
             schema_path: path,
             rule: "number_type_preserved",
             source: "number",
             target: "number",
             explanation: "number type preserved; client does not distinguish integer from number"
           )
         ]}
      end

    schema = numeric_schema(type, scroll)
    {schema, ec_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_description(schema, scroll.description, profile)
    {schema, omens ++ ec_omens}
  end

  defp project_scroll(%Scroll{kind: :boolean} = scroll, profile, policy, path) do
    schema = %{"type" => "boolean"}
    {schema, ec_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_description(schema, scroll.description, profile)
    {schema, ec_omens}
  end

  defp project_scroll(%Scroll{kind: :null} = scroll, profile, policy, path) do
    {schema, omens} = attach_enum_const(%{"type" => "null"}, scroll, profile, policy, path)
    schema = maybe_put_description(schema, scroll.description, profile)
    {schema, omens}
  end

  defp project_scroll(%Scroll{kind: :enum} = scroll, profile, policy, path) do
    {schema, omens} = project_enum(scroll, profile, policy, path)
    schema = maybe_put_description(schema, scroll.description, profile)
    {schema, omens}
  end

  defp project_scroll(%Scroll{kind: :const} = scroll, profile, policy, path) do
    {schema, omens} = attach_enum_const(%{}, scroll, profile, policy, path)
    schema = maybe_put_description(schema, scroll.description, profile)
    {schema, omens}
  end

  defp project_scroll(%Scroll{kind: :union} = scroll, profile, policy, path) do
    combinator = determine_union_combinator(scroll, profile)

    if combinator == :unsupported do
      project_unsupported_union(scroll, profile, policy, path)
    else
      project_union_supported(scroll, profile, policy, path, combinator)
    end
  end

  defp project_scroll(%Scroll{kind: :intersection} = scroll, profile, policy, path) do
    if MapSet.member?(profile.supported_combinators, :allOf) do
      {branches, branch_omens} =
        Enum.reduce(scroll.branches, {[], []}, fn branch, {schemas, omens} ->
          {schema, branch_omens} = project_scroll(branch, profile, policy, path ++ ["branch"])
          {schemas ++ [schema], omens ++ branch_omens}
        end)

      schema = %{"allOf" => branches}
      schema = maybe_put_description(schema, scroll.description, profile)
      {schema, branch_omens}
    else
      merged = try_merge_intersection(scroll.branches, profile, policy, path)

      case merged do
        {:ok, schema, omens} ->
          schema = maybe_put_description(schema, scroll.description, profile)
          {schema, omens}

        {:error, omen} ->
          {project_rejected(omen, scroll, profile), [omen]}
      end
    end
  end

  defp project_scroll(%Scroll{kind: :ref} = scroll, profile, policy, path) do
    ref_string = Reference.to_string(scroll.ref_target)

    cond do
      profile.reference_support == :full ->
        project_ref_with_siblings(scroll, ref_string, profile, policy, path)

      profile.reference_support == :local_only and Reference.local?(scroll.ref_target) ->
        project_ref_with_siblings(scroll, ref_string, profile, policy, path)

      true ->
        omen =
          Omen.rejected("NYA-PROFILE-004",
            schema_path: path,
            rule: "reference_unsupported",
            source: "$ref",
            target: nil,
            explanation: "references are not supported by this profile",
            action: "inline the reference or select a profile that supports references"
          )

        {project_rejected(omen, scroll, profile), [omen]}
    end
  end

  defp project_scroll(%Scroll{kind: :any} = _scroll, _profile, _policy, _path) do
    {%{}, []}
  end

  defp project_scroll(%Scroll{kind: :never} = _scroll, _profile, _policy, _path) do
    {%{"not" => %{}}, []}
  end

  defp project_scroll(%Scroll{kind: :unknown} = scroll, profile, _policy, _path) do
    schema = scroll.raw || %{}
    schema = maybe_put_description(schema, scroll.description, profile)
    {schema, []}
  end

  defp project_union_supported(scroll, profile, policy, path, combinator) do
    {branches, branch_omens} =
      Enum.reduce(scroll.branches, {[], []}, fn branch, {schemas, omens} ->
        {schema, branch_omens} = project_scroll(branch, profile, policy, path ++ ["branch"])
        {schemas ++ [schema], omens ++ branch_omens}
      end)

    nullable? = union_is_nullable?(scroll.branches)

    {schema, nullable_omens} =
      if nullable? and profile.nullable_representation == :type_array do
        {project_nullable_union(branches), []}
      else
        {%{combinator_key(combinator) => branches}, []}
      end

    schema = put_numeric_constraints(schema, scroll)
    {schema, enum_const_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_description(schema, scroll.description, profile)
    {schema, branch_omens ++ nullable_omens ++ enum_const_omens}
  end

  defp project_nullable_union(branches) do
    non_null = Enum.reject(branches, fn b -> Map.get(b, "type") == "null" end)

    types =
      non_null
      |> Enum.map(fn b -> Map.get(b, "type") end)
      |> Enum.filter(&(&1 != nil))

    if length(types) == 1, do: hd(non_null), else: %{"type" => types}
  end

  defp project_properties(nil, _profile, _policy, _path) do
    {%{}, []}
  end

  defp project_properties(properties, profile, policy, path) do
    Enum.reduce(properties, {%{}, []}, fn {name, child}, {schemas, omens} ->
      {schema, child_omens} = project_scroll(child, profile, policy, path ++ ["properties", name])
      {Map.put(schemas, name, schema), omens ++ child_omens}
    end)
  end

  defp project_pattern_properties(nil, _profile, _policy, _path), do: {%{}, []}

  defp project_pattern_properties(patterns, profile, policy, path) do
    if profile.supports_pattern_properties do
      Enum.reduce(patterns, {%{}, []}, fn {name, child}, {schemas, omens} ->
        {schema, child_omens} =
          project_scroll(child, profile, policy, path ++ ["patternProperties", name])

        {Map.put(schemas, name, schema), omens ++ child_omens}
      end)
    else
      omen =
        Omen.lossy("NYA-PROFILE-005",
          schema_path: path,
          rule: "pattern_properties_dropped",
          source: "patternProperties",
          target: "patternProperties omitted",
          explanation: "patternProperties is not supported by this profile"
        )

      {%{}, [omen]}
    end
  end

  defp maybe_put_int(schema, _key, nil), do: schema
  defp maybe_put_int(schema, key, value), do: Map.put(schema, key, value)

  defp maybe_put_bool(schema, _key, nil), do: schema
  defp maybe_put_bool(schema, key, value), do: Map.put(schema, key, value)

  defp build_object_schema(scroll, properties, required, additional, pattern_props) do
    %{"type" => "object"}
    |> put_if_non_empty("properties", properties)
    |> put_required(required)
    |> put_additional(additional)
    |> put_if_non_empty("patternProperties", pattern_props)
    |> maybe_put_int("minProperties", scroll.min_properties)
    |> maybe_put_int("maxProperties", scroll.max_properties)
  end

  defp put_if_non_empty(schema, _key, nil), do: schema
  defp put_if_non_empty(schema, _key, map) when map_size(map) == 0, do: schema
  defp put_if_non_empty(schema, key, map), do: Map.put(schema, key, map)

  defp put_required(schema, []), do: schema
  defp put_required(schema, required), do: Map.put(schema, "required", required)

  defp put_additional(schema, nil), do: schema
  defp put_additional(schema, false), do: Map.put(schema, "additionalProperties", false)

  defp put_additional(schema, additional_schema) when is_map(additional_schema),
    do: Map.put(schema, "additionalProperties", additional_schema)

  defp put_additional(schema, true), do: schema

  defp attach_enum_const(schema, scroll, profile, policy, path) do
    cond do
      scroll.const == :unset ->
        attach_enum(schema, scroll.enum, scroll, profile, policy, path)

      scroll.enum == nil ->
        attach_const(schema, scroll.const, profile, policy, path)

      profile.supports_const ->
        {schema, enum_omens} = attach_enum(schema, scroll.enum, scroll, profile, policy, path)
        {Map.put(schema, "const", scroll.const), enum_omens}

      Enum.member?(scroll.enum, scroll.const) ->
        {schema, enum_omens} = attach_enum(schema, [scroll.const], scroll, profile, policy, path)
        {schema, [const_unsupported_omen(policy, path) | enum_omens]}

      true ->
        omen =
          Omen.rejected("NYA-SCHEMA-004",
            schema_path: path,
            rule: "enum_const_empty_intersection",
            source: "enum and const",
            target: "enum: []",
            explanation: "enum and const have no value in common",
            action: "make const a member of enum or remove one constraint"
          )

        {Map.put(schema, "enum", []), [const_unsupported_omen(policy, path), omen]}
    end
  end

  defp attach_enum(schema, nil, _scroll, _profile, _policy, _path), do: {schema, []}

  defp attach_enum(schema, enum, scroll, profile, policy, path) do
    cond do
      enum == [] and MapSet.member?(profile.supported_enum_forms, :empty) ->
        {Map.put(schema, "enum", enum), []}

      enum == [] ->
        omen = empty_enum_omen(policy, path)

        if policy == :strict do
          {Map.put(schema, "enum", enum), [omen]}
        else
          {schema, [omen]}
        end

      mixed_enum?(enum) and not MapSet.member?(profile.supported_enum_forms, :mixed) ->
        omen =
          Omen.rejected("NYA-SCHEMA-005",
            schema_path: path,
            rule: "mixed_enum_unsupported",
            source: "mixed-type enum",
            target: nil,
            explanation: "mixed-type enums are not supported by this profile",
            action: "split into separate tools or use a homogeneous enum"
          )

        {project_rejected(omen, scroll, profile), [omen]}

      true ->
        {Map.put(schema, "enum", enum), []}
    end
  end

  defp attach_const(schema, const, profile, policy, path) do
    if profile.supports_const do
      {Map.put(schema, "const", const), []}
    else
      {Map.put(schema, "enum", [const]), [const_unsupported_omen(policy, path)]}
    end
  end

  defp const_unsupported_omen(:strict, path) do
    Omen.rejected("NYA-PROFILE-006",
      schema_path: path,
      rule: "const_unsupported",
      source: "const",
      target: "enum",
      explanation: "const is not supported by this profile",
      action: "remove const or select a profile that supports const"
    )
  end

  defp const_unsupported_omen(_policy, path) do
    Omen.lossy("NYA-PROFILE-006",
      schema_path: path,
      rule: "const_to_enum",
      source: "const",
      target: "enum",
      explanation: "const converted to single-value enum; const-specific semantics dropped"
    )
  end

  defp empty_enum_omen(:strict, path) do
    Omen.rejected("NYA-SCHEMA-004",
      schema_path: path,
      rule: "empty_enum_unsupported",
      source: "enum: []",
      target: nil,
      explanation: "empty enums are not supported by this profile"
    )
  end

  defp empty_enum_omen(_policy, path) do
    Omen.lossy("NYA-SCHEMA-004",
      schema_path: path,
      rule: "empty_enum_dropped",
      source: "enum: []",
      target: "enum omitted",
      explanation: "empty enums are not supported by this profile"
    )
  end

  defp project_ref_with_siblings(scroll, ref_string, profile, policy, path) do
    schema = %{"$ref" => ref_string}
    schema = put_numeric_constraints(schema, scroll)
    {schema, omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_description(schema, scroll.description, profile)
    {schema, omens}
  end

  defp project_required(nil, _properties, _profile, _path) do
    {[], []}
  end

  defp project_required(required, _properties, profile, path) do
    if profile.requires_all_properties_required do
      {required,
       [
         Omen.normalized("NYA-PROFILE-001",
           schema_path: path,
           rule: "all_properties_required",
           source: "partial required",
           target: "all properties required",
           explanation: "profile requires all object properties to be listed in required"
         )
       ]}
    else
      {required, []}
    end
  end

  defp project_additional(nil, _profile, _policy, _path) do
    {nil, []}
  end

  defp project_additional(false, profile, _policy, path) do
    if profile.supports_additional_properties_false do
      {false, []}
    else
      {true,
       [
         Omen.lossy("NYA-SCHEMA-003",
           schema_path: path,
           rule: "additional_properties_false_dropped",
           source: "additionalProperties: false",
           target: "additionalProperties omitted",
           explanation:
             "additionalProperties: false is not supported; closed-object semantics lost",
           action: "select a profile that supports additionalProperties: false"
         )
       ]}
    end
  end

  defp project_additional(true, _profile, _policy, _path) do
    {nil, []}
  end

  defp project_additional(%Scroll{} = additional, profile, policy, path) do
    project_scroll(additional, profile, policy, path ++ ["additionalProperties"])
  end

  defp project_enum(%Scroll{} = scroll, profile, policy, path) do
    attach_enum(%{}, scroll.enum || [], scroll, profile, policy, path)
  end

  defp project_tuple_array(%Scroll{} = scroll, profile, policy, path) do
    if MapSet.member?(profile.supported_array_forms, :tuple) do
      {items, item_omens} =
        Enum.reduce(scroll.tuple_items, {[], []}, fn item, {schemas, acc_omens} ->
          {schema, item_omens} = project_scroll(item, profile, policy, path ++ ["items"])
          {schemas ++ [schema], acc_omens ++ item_omens}
        end)

      {additional_items, additional_omens} =
        project_additional_items(scroll.additional_items, profile, policy, path)

      schema = %{"type" => "array", "items" => items}
      schema = put_additional_items(schema, additional_items)
      schema = maybe_put_int(schema, "minItems", scroll.min_items)
      schema = maybe_put_int(schema, "maxItems", scroll.max_items)
      schema = maybe_put_bool(schema, "uniqueItems", scroll.unique_items)
      {schema, item_omens ++ additional_omens}
    else
      omen =
        Omen.rejected("NYA-SCHEMA-006",
          schema_path: path,
          rule: "tuple_array_unsupported",
          source: "tuple array (items as array)",
          target: nil,
          explanation: "tuple-style arrays are not supported by this profile",
          action: "use a homogeneous array or select a profile that supports tuples"
        )

      {project_rejected(omen, scroll, profile), [omen]}
    end
  end

  defp project_additional_items(nil, _profile, _policy, _path), do: {nil, []}

  defp project_additional_items(additional_items, profile, policy, path) do
    if MapSet.member?(profile.accepted_keywords, "additionalItems") do
      case additional_items do
        false ->
          {false, []}

        %Scroll{} ->
          project_scroll(additional_items, profile, policy, path ++ ["additionalItems"])
      end
    else
      omen = additional_items_omen(additional_items, policy, path)
      {nil, [omen]}
    end
  end

  defp additional_items_omen(additional_items, :strict, path) do
    Omen.rejected("NYA-SCHEMA-006",
      schema_path: path ++ ["additionalItems"],
      rule: "additional_items_unsupported",
      source: additional_items_source(additional_items),
      target: nil,
      explanation: "additionalItems is not supported by this profile",
      action: "remove additionalItems or select a profile that supports it"
    )
  end

  defp additional_items_omen(additional_items, _policy, path) do
    Omen.lossy("NYA-SCHEMA-006",
      schema_path: path ++ ["additionalItems"],
      rule: "additional_items_dropped",
      source: additional_items_source(additional_items),
      target: "additionalItems omitted",
      explanation: "additionalItems is not supported by this profile"
    )
  end

  defp additional_items_source(false), do: "additionalItems: false"
  defp additional_items_source(%Scroll{}), do: "additionalItems schema"

  defp put_additional_items(schema, nil), do: schema

  defp put_additional_items(schema, additional_items),
    do: Map.put(schema, "additionalItems", additional_items)

  defp project_unsupported_union(%Scroll{} = scroll, profile, policy, path) do
    omen =
      Omen.rejected("NYA-SCHEMA-007",
        schema_path: path,
        rule: "union_unsupported",
        source: "oneOf/anyOf",
        target: nil,
        explanation: "unions are not supported by this profile",
        action: "select a profile that supports oneOf/anyOf or restructure the schema"
      )

    if policy == :strict do
      {project_rejected(omen, scroll, profile), [omen]}
    else
      case scroll.branches do
        [first_branch | _] ->
          {projected, branch_omens} =
            project_scroll(first_branch, profile, policy, path ++ ["fallback"])

          {projected, [omen | branch_omens]}

        [] ->
          {%{}, [omen]}
      end
    end
  end

  defp try_merge_intersection(branches, profile, policy, path) do
    case branches do
      [] ->
        {:ok, %{}, []}

      [single] ->
        {schema, omens} = project_scroll(single, profile, policy, path)
        {:ok, schema, omens}

      _ ->
        {projected_branches, omens} =
          Enum.reduce(branches, {[], []}, fn branch, {schemas, acc_omens} ->
            {schema, branch_omens} = project_scroll(branch, profile, policy, path ++ ["allOf"])
            {schemas ++ [schema], acc_omens ++ branch_omens}
          end)

        case merge_projected_properties(projected_branches) do
          {:ok, merged_schema} ->
            {:ok, merged_schema, omens}

          {:conflict, _name, _left, _right} ->
            {:error,
             Omen.rejected("NYA-SCHEMA-008",
               schema_path: path,
               rule: "contradictory_intersection",
               source: "allOf with contradictions",
               target: nil,
               explanation:
                 "allOf branches contain contradictory constraints and cannot be merged",
               action: "resolve contradictions or keep allOf if profile supports it"
             )}
        end
    end
  end

  defp merge_projected_properties(schemas) when is_list(schemas) do
    Enum.reduce_while(schemas, {:ok, %{}}, fn schema, {:ok, acc} ->
      case merge_one(acc, schema) do
        {:ok, merged} -> {:cont, {:ok, merged}}
        {:conflict, _, _, _} = conflict -> {:halt, conflict}
      end
    end)
  end

  defp merge_one(left, right) when is_map(left) and is_map(right) do
    left_props = Map.get(left, "properties", %{})
    right_props = Map.get(right, "properties", %{})

    conflicts =
      Map.intersect(left_props, right_props, fn name, l_prop, r_prop ->
        if schemas_compatible?(l_prop, r_prop) do
          nil
        else
          name
        end
      end)
      |> Map.values()
      |> Enum.filter(&(&1 != nil))

    case conflicts do
      [] ->
        merged = deep_merge(left, right)
        {:ok, merged}

      [name | _] ->
        {:conflict, name, Map.get(left_props, name), Map.get(right_props, name)}
    end
  end

  defp schemas_compatible?(left, right) when is_map(left) and is_map(right) do
    left_type = Map.get(left, "type")
    right_type = Map.get(right, "type")

    cond do
      left_type == nil or right_type == nil ->
        true

      left_type == right_type ->
        true

      is_list(left_type) and is_list(right_type) ->
        MapSet.new(left_type) == MapSet.new(right_type)

      true ->
        false
    end
  end

  defp schemas_compatible?(_left, _right), do: true

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, l, r when is_map(l) and is_map(r) -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  defp deep_merge(_left, right), do: right

  defp determine_union_combinator(%Scroll{branches: branches} = scroll, profile) do
    requested = requested_union_combinator(scroll)

    cond do
      requested != nil and MapSet.member?(profile.supported_combinators, requested) -> requested
      requested != nil -> :unsupported
      MapSet.member?(profile.supported_combinators, :oneOf) -> :oneOf
      MapSet.member?(profile.supported_combinators, :anyOf) -> :anyOf
      union_is_nullable?(branches) -> :nullable
      true -> :unsupported
    end
  end

  defp requested_union_combinator(%Scroll{annotations: %{"nya:combinator" => "oneOf"}}),
    do: :oneOf

  defp requested_union_combinator(%Scroll{annotations: %{"nya:combinator" => "anyOf"}}),
    do: :anyOf

  defp requested_union_combinator(_scroll), do: nil

  defp union_is_nullable?(branches) do
    Enum.any?(branches, fn
      %Scroll{kind: :null} -> true
      _ -> false
    end)
  end

  defp combinator_key(:oneOf), do: "oneOf"
  defp combinator_key(:anyOf), do: "anyOf"

  defp mixed_enum?(enum) when is_list(enum) do
    types = Enum.map(enum, &enum_value_type/1) |> Enum.uniq()
    length(types) > 1
  end

  defp enum_value_type(value) when is_binary(value), do: :string
  defp enum_value_type(value) when is_integer(value), do: :integer
  defp enum_value_type(value) when is_float(value), do: :number
  defp enum_value_type(value) when is_boolean(value), do: :boolean
  defp enum_value_type(nil), do: :null
  defp enum_value_type(value) when is_list(value), do: :array
  defp enum_value_type(value) when is_map(value), do: :object
  defp enum_value_type(_), do: :unknown

  defp numeric_schema(type, scroll) do
    put_numeric_constraints(%{"type" => type}, scroll)
  end

  defp put_numeric_constraints(schema, scroll) do
    Enum.reduce(
      [
        {"minimum", scroll.minimum},
        {"maximum", scroll.maximum},
        {"exclusiveMinimum", scroll.exclusive_minimum},
        {"exclusiveMaximum", scroll.exclusive_maximum},
        {"multipleOf", scroll.multiple_of}
      ],
      schema,
      fn {key, value}, acc ->
        if value != nil, do: Map.put(acc, key, value), else: acc
      end
    )
  end

  defp format_omens(nil, _path, _profile), do: []

  defp format_omens(format, path, profile) do
    if MapSet.member?(profile.accepted_keywords, "format") do
      []
    else
      [
        Omen.lossy("NYA-PROFILE-003",
          schema_path: path,
          rule: "format_dropped",
          source: "format: #{format}",
          target: "format omitted",
          explanation: "format keyword is not accepted by this profile"
        )
      ]
    end
  end

  defp array_without_items_omen(path, profile, policy) do
    if MapSet.member?(profile.supported_array_forms, :no_items) do
      Omen.exact("NYA-SCHEMA-009",
        schema_path: path,
        rule: "array_without_items_preserved",
        source: "array without items",
        target: "array without items",
        explanation: "array without items preserved as-is"
      )
    else
      if policy == :strict do
        Omen.rejected("NYA-SCHEMA-009",
          schema_path: path,
          rule: "array_without_items_unsupported",
          source: "array without items",
          target: nil,
          explanation: "array without items is not supported in strict mode for this profile",
          action: "define items or select a profile that accepts untyped arrays"
        )
      else
        Omen.lossy("NYA-SCHEMA-009",
          schema_path: path,
          rule: "array_without_items_relaxed",
          source: "array without items",
          target: "array accepting any items",
          explanation: "array without items relaxed to accept any items"
        )
      end
    end
  end

  defp maybe_put_description(schema, nil, _profile), do: schema

  defp maybe_put_description(schema, description, profile) do
    case profile.max_description_length do
      :unlimited ->
        Map.put(schema, "description", description)

      max when is_integer(max) ->
        if String.length(description) > max do
          Map.put(schema, "description", String.slice(description, 0, max))
        else
          Map.put(schema, "description", description)
        end
    end
  end

  defp collect_truncation_omens(%Scroll{description: desc} = scroll, profile, path) do
    omens =
      case profile.max_description_length do
        max when is_integer(max) and is_binary(desc) ->
          if String.length(desc) > max do
            [
              Omen.normalized("NYA-PROFILE-007",
                schema_path: path,
                rule: "description_truncated",
                source: "description (#{String.length(desc)} chars)",
                target: "description (#{max} chars)",
                explanation: "description truncated to fit profile maximum length"
              )
            ]
          else
            []
          end

        _ ->
          []
      end

    omens ++ collect_child_truncation_omens(scroll, profile, path)
  end

  defp collect_child_truncation_omens(%Scroll{} = scroll, profile, path) do
    property_omens(scroll.properties, profile, path, "properties") ++
      pattern_omens(scroll.pattern_properties, profile, path, "patternProperties") ++
      additional_omens(scroll.additional_properties, profile, path, "additionalProperties") ++
      item_omens(scroll.items, profile, path, "items") ++
      list_omens(scroll.tuple_items, profile, path, "items") ++
      additional_omens(scroll.additional_items, profile, path, "additionalItems") ++
      list_omens(scroll.branches, profile, path, "branches")
  end

  defp property_omens(nil, _profile, _path, _key), do: []

  defp property_omens(map, profile, path, key) when is_map(map) do
    Enum.flat_map(map, fn {name, child} ->
      collect_truncation_omens(child, profile, path ++ [key, name])
    end)
  end

  defp pattern_omens(nil, _profile, _path, _key), do: []

  defp pattern_omens(map, profile, path, key) when is_map(map) do
    Enum.flat_map(map, fn {name, child} ->
      collect_truncation_omens(child, profile, path ++ [key, name])
    end)
  end

  defp item_omens(nil, _profile, _path, _key), do: []

  defp item_omens(%Scroll{} = scroll, profile, path, key) do
    collect_truncation_omens(scroll, profile, path ++ [key])
  end

  defp list_omens(nil, _profile, _path, _key), do: []

  defp list_omens(list, profile, path, key) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} ->
      collect_truncation_omens(child, profile, path ++ [key, Integer.to_string(index)])
    end)
  end

  defp additional_omens(nil, _profile, _path, _key), do: []
  defp additional_omens(false, _profile, _path, _key), do: []

  defp additional_omens(%Scroll{} = scroll, profile, path, key) do
    collect_truncation_omens(scroll, profile, path ++ [key])
  end

  defp project_rejected(_omen, %Scroll{} = scroll, _profile) do
    scroll.raw || fallback_rejected_schema(scroll)
  end

  defp fallback_rejected_schema(%Scroll{kind: kind}) do
    case kind do
      :object -> %{"type" => "object"}
      :array -> %{"type" => "array"}
      :string -> %{"type" => "string"}
      :integer -> %{"type" => "integer"}
      :number -> %{"type" => "number"}
      :boolean -> %{"type" => "boolean"}
      _ -> %{}
    end
  end
end
