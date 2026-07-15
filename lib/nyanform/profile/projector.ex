defmodule Nyanform.Profile.Projector do
  alias Nyanform.Diagnostic.Omen
  alias Nyanform.Profile.Constellation
  alias Nyanform.Schema.{Reference, Scroll}

  @type policy :: :strict | :compatible | :permissive

  @type projection :: %{
          schema: term(),
          omens: [Omen.t()],
          accepted: boolean(),
          worst_severity: Omen.severity() | nil
        }

  @spec project(Scroll.t(), Constellation.t(), policy()) :: projection()
  def project(%Scroll{} = scroll, %Constellation{name: "passthrough"}, _policy) do
    schema = if(is_nil(scroll.raw), do: %{}, else: scroll.raw)
    integrity_omens = integrity_omens(scroll, schema, false)

    %{
      schema: schema,
      omens: integrity_omens,
      accepted: integrity_omens == [],
      worst_severity: Omen.worst(integrity_omens)
    }
  end

  def project(%Scroll{} = scroll, %Constellation{} = profile, policy) do
    {schema, omens} = project_scroll(scroll, profile, policy, [])
    schema = Reference.normalize_definition_refs(schema)
    truncation_omens = collect_truncation_omens(scroll, profile, [])
    constraint_omens = profile_constraint_omens(scroll, schema, profile)
    keyword_omens = collect_unsupported_keyword_omens(scroll, profile)
    annotation_omens = collect_unsupported_annotation_omens(scroll, profile)

    integrity_omens =
      integrity_omens(scroll, schema, profile.requires_all_properties_required)

    omens =
      (omens ++
         truncation_omens ++
         constraint_omens ++
         keyword_omens ++
         annotation_omens ++
         integrity_omens)
      |> Enum.reverse()

    accepted = integrity_omens == [] and policy_accepts?(policy, omens)
    worst = Omen.worst(omens)

    %{
      schema: schema,
      omens: omens,
      accepted: accepted,
      worst_severity: worst
    }
  end

  defp project_scroll(%Scroll{} = scroll, profile, policy, path) do
    {schema, omens} = project_node(scroll, profile, policy, path)

    {schema, definition_omens} =
      project_definitions(schema, scroll.definitions, profile, policy, path)

    {schema, omens ++ definition_omens}
  end

  defp project_definitions(schema, nil, _profile, _policy, _path), do: {schema, []}

  defp project_definitions(schema, defs, _profile, _policy, _path) when map_size(defs) == 0,
    do: {schema, []}

  defp project_definitions(schema, defs, profile, policy, path) do
    if profile.reference_support == :none do
      omen =
        Omen.lossy("NYA-SCHEMA-012",
          schema_path: path ++ ["$defs"],
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
            project_scroll(child_scroll, profile, policy, path ++ ["$defs", name])

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

  defp integrity_omens(scroll, projected_schema, check_required) do
    required_omens = if check_required, do: collect_undeclared_required_omens(scroll), else: []

    required_omens ++
      collect_dangling_reference_omens(scroll, projected_schema)
  end

  defp collect_undeclared_required_omens(%Scroll{kind: :object} = scroll) do
    declared = scroll.properties || %{}

    own =
      (scroll.required || [])
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(declared, &1))
      |> Enum.sort()
      |> Enum.map(fn name ->
        Omen.rejected("NYA-SCHEMA-013",
          schema_path: scroll.path ++ ["required"],
          rule: "required_property_undeclared",
          source: name,
          target: nil,
          explanation: "required property is not declared in properties",
          action: "declare the property schema or remove it from required"
        )
      end)

    own ++ Enum.flat_map(scroll_children(scroll), &collect_undeclared_required_omens/1)
  end

  defp collect_undeclared_required_omens(%Scroll{} = scroll) do
    Enum.flat_map(scroll_children(scroll), &collect_undeclared_required_omens/1)
  end

  defp collect_dangling_reference_omens(%Scroll{} = scroll, projected_schema) do
    source_schema = if is_map(scroll.raw), do: scroll.raw, else: projected_schema

    source_schema
    |> Reference.dangling_local_refs()
    |> Enum.map(fn %{path: path, reference: reference} ->
      Omen.rejected("NYA-SCHEMA-014",
        schema_path: path,
        rule: "local_reference_target_missing",
        source: reference,
        target: nil,
        explanation: "local reference target does not exist in the schema document",
        action: "define the referenced schema or correct the local JSON Pointer"
      )
    end)
  end

  defp project_node(%Scroll{kind: :object} = scroll, profile, policy, path) do
    {properties, prop_omens} =
      project_properties(scroll.properties, scroll.required, profile, policy, path)

    {required, req_omens} = project_required(scroll.required, properties, profile, path)

    {additional, addl_omens} =
      project_additional(scroll.additional_properties, profile, policy, path)

    {pattern_props, pat_omens} =
      project_pattern_properties(scroll.pattern_properties, profile, policy, path)

    schema = build_object_schema(scroll, properties, required, additional, pattern_props, profile)
    {schema, enum_const_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_metadata(schema, scroll, profile)
    omens = prop_omens ++ req_omens ++ addl_omens ++ pat_omens ++ enum_const_omens
    {schema, omens}
  end

  defp project_node(%Scroll{kind: :array} = scroll, profile, policy, path) do
    {schema, omens} =
      cond do
        scroll.tuple_items != nil ->
          project_tuple_array(scroll, profile, policy, path)

        scroll.items != nil ->
          {items_schema, items_omens} =
            project_scroll(scroll.items, profile, policy, path ++ ["items"])

          schema = %{"type" => "array", "items" => items_schema}

          schema =
            maybe_put_int(
              schema,
              "minItems",
              accepted_value(scroll.min_items, "minItems", profile)
            )

          schema =
            maybe_put_int(
              schema,
              "maxItems",
              accepted_value(scroll.max_items, "maxItems", profile)
            )

          schema =
            maybe_put_bool(
              schema,
              "uniqueItems",
              accepted_value(scroll.unique_items, "uniqueItems", profile)
            )

          {schema, items_omens}

        true ->
          omen = array_without_items_omen(path, profile, policy)
          schema = %{"type" => "array"}

          schema =
            maybe_put_int(
              schema,
              "minItems",
              accepted_value(scroll.min_items, "minItems", profile)
            )

          schema =
            maybe_put_int(
              schema,
              "maxItems",
              accepted_value(scroll.max_items, "maxItems", profile)
            )

          schema =
            maybe_put_bool(
              schema,
              "uniqueItems",
              accepted_value(scroll.unique_items, "uniqueItems", profile)
            )

          {schema, [omen]}
      end

    {schema, enum_const_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_metadata(schema, scroll, profile)
    {schema, omens ++ enum_const_omens}
  end

  defp project_node(%Scroll{kind: :string} = scroll, profile, policy, path) do
    schema = %{"type" => "string"}

    schema =
      Enum.reduce(
        [
          {"minLength", accepted_value(scroll.min_length, "minLength", profile)},
          {"maxLength", accepted_value(scroll.max_length, "maxLength", profile)},
          {"pattern", accepted_value(scroll.pattern, "pattern", profile)},
          {"format", accepted_format(scroll.format, profile)}
        ],
        schema,
        fn {key, value}, acc ->
          if value != nil, do: Map.put(acc, key, value), else: acc
        end
      )

    {schema, ec_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_metadata(schema, scroll, profile)
    omens = format_omens(scroll.format, path, profile) ++ ec_omens
    {schema, omens}
  end

  defp project_node(%Scroll{kind: :integer} = scroll, profile, policy, path) do
    schema = numeric_schema("integer", scroll, profile)
    {schema, ec_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_metadata(schema, scroll, profile)
    {schema, ec_omens}
  end

  defp project_node(%Scroll{kind: :number} = scroll, profile, policy, path) do
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

    schema = numeric_schema(type, scroll, profile)
    {schema, ec_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_metadata(schema, scroll, profile)
    {schema, omens ++ ec_omens}
  end

  defp project_node(%Scroll{kind: :boolean} = scroll, profile, policy, path) do
    schema = %{"type" => "boolean"}
    {schema, ec_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_metadata(schema, scroll, profile)
    {schema, ec_omens}
  end

  defp project_node(%Scroll{kind: :null} = scroll, profile, policy, path) do
    {schema, omens} = attach_enum_const(%{"type" => "null"}, scroll, profile, policy, path)
    schema = maybe_put_metadata(schema, scroll, profile)
    {schema, omens}
  end

  defp project_node(%Scroll{kind: :enum} = scroll, profile, policy, path) do
    {schema, omens} = project_enum(scroll, profile, policy, path)
    schema = maybe_put_metadata(schema, scroll, profile)
    {schema, omens}
  end

  defp project_node(%Scroll{kind: :const} = scroll, profile, policy, path) do
    {schema, omens} = attach_enum_const(%{}, scroll, profile, policy, path)
    schema = maybe_put_metadata(schema, scroll, profile)
    {schema, omens}
  end

  defp project_node(%Scroll{kind: :union} = scroll, profile, policy, path) do
    combinator = determine_union_combinator(scroll, profile)

    if combinator == :unsupported do
      project_unsupported_union(scroll, profile, policy, path)
    else
      project_union_supported(scroll, profile, policy, path, combinator)
    end
  end

  defp project_node(%Scroll{kind: :intersection} = scroll, profile, policy, path) do
    if MapSet.member?(profile.supported_combinators, :allOf) do
      {branches, branch_omens} =
        scroll.branches
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {branch, index}, {schemas, omens} ->
          {schema, branch_omens} =
            project_scroll(
              branch,
              profile,
              policy,
              path ++ ["allOf", Integer.to_string(index)]
            )

          {schemas ++ [schema], omens ++ branch_omens}
        end)

      schema = %{"allOf" => branches}
      schema = maybe_put_metadata(schema, scroll, profile)
      {schema, branch_omens}
    else
      if policy == :strict do
        omen = unsupported_intersection_omen(:strict, path)
        {project_rejected(omen, scroll, profile), [omen]}
      else
        case try_merge_intersection(scroll.branches, profile, policy, path) do
          {:ok, schema, omens} ->
            schema = enforce_projected_object_requirements(schema, profile)
            schema = maybe_put_metadata(schema, scroll, profile)
            {schema, [unsupported_intersection_omen(policy, path) | omens]}

          {:error, omen} ->
            {project_rejected(omen, scroll, profile), [omen]}
        end
      end
    end
  end

  defp project_node(%Scroll{kind: :ref} = scroll, profile, policy, path) do
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

  defp project_node(%Scroll{kind: :any, raw: true}, %{name: "canonical"}, _policy, _path) do
    {true, []}
  end

  defp project_node(%Scroll{kind: :any, raw: true} = scroll, _profile, _policy, path) do
    omen = unrepresentable_schema_omen(path, "boolean true schema")
    {project_rejected(omen, scroll, nil), [omen]}
  end

  defp project_node(%Scroll{kind: :any} = scroll, %{name: "openai_strict"}, _policy, path) do
    omen = unrepresentable_schema_omen(path, "untyped schema")
    {project_rejected(omen, scroll, nil), [omen]}
  end

  defp project_node(%Scroll{kind: :any} = _scroll, _profile, _policy, _path) do
    {%{}, []}
  end

  defp project_node(%Scroll{kind: :never, raw: false}, %{name: "canonical"}, _policy, _path) do
    {false, []}
  end

  defp project_node(%Scroll{kind: :never} = scroll, _profile, _policy, path) do
    omen = unrepresentable_schema_omen(path, "boolean false schema")
    {project_rejected(omen, scroll, nil), [omen]}
  end

  defp project_node(
         %Scroll{kind: :unknown} = scroll,
         %{name: "openai_strict"},
         _policy,
         path
       ) do
    omen = unrepresentable_schema_omen(path, "schema without a supported type")
    {project_rejected(omen, scroll, nil), [omen]}
  end

  defp project_node(%Scroll{kind: :unknown} = scroll, profile, _policy, _path) do
    schema = scroll.raw || %{}
    schema = maybe_put_metadata(schema, scroll, profile)
    {schema, []}
  end

  defp project_union_supported(scroll, profile, policy, path, combinator) do
    branch_key =
      if combinator in [:oneOf, :anyOf], do: combinator_key(combinator), else: "branches"

    {branches, branch_omens} =
      scroll.branches
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {branch, index}, {schemas, omens} ->
        {schema, branch_omens} =
          project_scroll(
            branch,
            profile,
            policy,
            path ++ [branch_key, Integer.to_string(index)]
          )

        {schemas ++ [schema], omens ++ branch_omens}
      end)

    nullable? = union_is_nullable?(scroll.branches)

    {schema, nullable_omens} =
      if nullable? and profile.nullable_representation == :type_array and
           requested_union_combinator(scroll) == nil do
        {project_nullable_union(branches), []}
      else
        {%{combinator_key(combinator) => branches}, []}
      end

    schema = put_numeric_constraints(schema, scroll, profile)
    {schema, enum_const_omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_metadata(schema, scroll, profile)
    {schema, branch_omens ++ nullable_omens ++ enum_const_omens}
  end

  defp project_nullable_union(branches) do
    non_null = Enum.reject(branches, fn b -> Map.get(b, "type") == "null" end)

    case non_null do
      [schema] ->
        case Map.get(schema, "type") do
          type when is_binary(type) -> Map.put(schema, "type", [type, "null"])
          types when is_list(types) -> Map.put(schema, "type", Enum.uniq(types ++ ["null"]))
          _ -> %{"anyOf" => branches}
        end

      schemas ->
        types = schemas |> Enum.map(&Map.get(&1, "type")) |> Enum.filter(&is_binary/1)

        if length(types) == length(schemas) and Enum.all?(schemas, &(map_size(&1) == 1)) do
          %{"type" => Enum.uniq(types ++ ["null"])}
        else
          %{"anyOf" => branches}
        end
    end
  end

  defp project_properties(nil, _required, _profile, _policy, _path) do
    {%{}, []}
  end

  defp project_properties(properties, required, profile, policy, path) do
    required = MapSet.new(required || [])

    Enum.reduce(properties, {%{}, []}, fn {name, child}, {schemas, omens} ->
      {schema, child_omens} = project_scroll(child, profile, policy, path ++ ["properties", name])
      schema = maybe_make_optional_nullable(schema, name, required, profile)
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

  defp build_object_schema(scroll, properties, required, additional, pattern_props, profile) do
    %{"type" => "object"}
    |> put_if_non_empty("properties", properties)
    |> put_required(required)
    |> put_additional(additional)
    |> put_if_non_empty("patternProperties", pattern_props)
    |> maybe_put_int(
      "minProperties",
      accepted_value(scroll.min_properties, "minProperties", profile)
    )
    |> maybe_put_int(
      "maxProperties",
      accepted_value(scroll.max_properties, "maxProperties", profile)
    )
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

  defp const_unsupported_omen(_policy, path) do
    Omen.normalized("NYA-PROFILE-006",
      schema_path: path,
      rule: "const_to_enum",
      source: "const",
      target: "enum",
      explanation: "const converted to an equivalent single-value enum"
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
    schema = put_numeric_constraints(schema, scroll, profile)
    {schema, omens} = attach_enum_const(schema, scroll, profile, policy, path)
    schema = maybe_put_metadata(schema, scroll, profile)
    {schema, omens}
  end

  defp project_required(required, properties, profile, path) do
    required = required || []

    if profile.requires_all_properties_required do
      all_required = properties |> Map.keys() |> Enum.sort()

      if MapSet.new(required) == MapSet.new(all_required) do
        {all_required, []}
      else
        {all_required,
         [
           Omen.normalized("NYA-PROFILE-001",
             schema_path: path,
             rule: "all_properties_required",
             source: inspect(required),
             target: inspect(all_required),
             explanation: "profile requires all object properties to be listed in required"
           )
         ]}
      end
    else
      {required, []}
    end
  end

  defp project_additional(nil, %{requires_additional_properties_false: true}, _policy, path) do
    {false, [required_additional_properties_omen(path, "omitted")]}
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

  defp project_additional(true, %{requires_additional_properties_false: true}, _policy, path) do
    {false, [required_additional_properties_omen(path, "true")]}
  end

  defp project_additional(true, _profile, _policy, _path) do
    {nil, []}
  end

  defp project_additional(
         %Scroll{},
         %{requires_additional_properties_false: true},
         policy,
         path
       ) do
    {false, [schema_valued_additional_properties_omen(policy, path)]}
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
        scroll.tuple_items
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {item, index}, {schemas, acc_omens} ->
          {schema, item_omens} =
            project_scroll(
              item,
              profile,
              policy,
              path ++ ["items", Integer.to_string(index)]
            )

          {schemas ++ [schema], acc_omens ++ item_omens}
        end)

      {additional_items, additional_omens} =
        project_additional_items(scroll.additional_items, profile, policy, path)

      schema = %{"type" => "array", "items" => items}
      schema = put_additional_items(schema, additional_items)

      schema =
        maybe_put_int(schema, "minItems", accepted_value(scroll.min_items, "minItems", profile))

      schema =
        maybe_put_int(schema, "maxItems", accepted_value(scroll.max_items, "maxItems", profile))

      schema =
        maybe_put_bool(
          schema,
          "uniqueItems",
          accepted_value(scroll.unique_items, "uniqueItems", profile)
        )

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
          branches
          |> Enum.with_index()
          |> Enum.reduce({[], []}, fn {branch, index}, {schemas, acc_omens} ->
            {schema, branch_omens} =
              project_scroll(
                branch,
                profile,
                policy,
                path ++ ["allOf", Integer.to_string(index)]
              )

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

  defp numeric_schema(type, scroll, profile) do
    put_numeric_constraints(%{"type" => type}, scroll, profile)
  end

  defp put_numeric_constraints(schema, scroll, profile) do
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
        value = accepted_value(value, key, profile)
        if value != nil, do: Map.put(acc, key, value), else: acc
      end
    )
  end

  defp accepted_value(nil, _keyword, _profile), do: nil

  defp accepted_value(value, keyword, profile) do
    if MapSet.member?(profile.accepted_keywords, keyword), do: value
  end

  defp accepted_format(nil, _profile), do: nil

  defp accepted_format(format, profile) do
    if format_supported?(format, profile), do: format
  end

  defp maybe_make_optional_nullable(
         schema,
         name,
         required,
         %{requires_all_properties_required: true}
       ) do
    if MapSet.member?(required, name), do: schema, else: make_nullable(schema)
  end

  defp maybe_make_optional_nullable(schema, _name, _required, _profile), do: schema

  defp make_nullable(schema) do
    schema
    |> make_nullable_schema()
    |> make_enum_nullable()
  end

  defp make_nullable_schema(%{"type" => types} = schema) when is_list(types) do
    Map.put(schema, "type", Enum.uniq(types ++ ["null"]))
  end

  defp make_nullable_schema(%{"type" => "null"} = schema), do: schema

  defp make_nullable_schema(%{"type" => type} = schema) when is_binary(type) do
    Map.put(schema, "type", [type, "null"])
  end

  defp make_nullable_schema(%{"anyOf" => branches} = schema) when is_list(branches) do
    if Enum.any?(branches, &null_schema?/1) do
      schema
    else
      Map.put(schema, "anyOf", branches ++ [%{"type" => "null"}])
    end
  end

  defp make_nullable_schema(%{"enum" => values} = schema) when is_list(values) do
    Map.put(schema, "enum", Enum.uniq(values ++ [nil]))
  end

  defp make_nullable_schema(schema), do: %{"anyOf" => [schema, %{"type" => "null"}]}

  defp make_enum_nullable(%{"enum" => values} = schema) when is_list(values) do
    Map.put(schema, "enum", Enum.uniq(values ++ [nil]))
  end

  defp make_enum_nullable(schema), do: schema

  defp null_schema?(%{"type" => "null"}), do: true
  defp null_schema?(%{"type" => types}) when is_list(types), do: "null" in types
  defp null_schema?(_schema), do: false

  defp unsupported_intersection_omen(:strict, path) do
    Omen.rejected("NYA-PROFILE-010",
      schema_path: path,
      rule: "all_of_unsupported",
      source: "allOf",
      target: nil,
      explanation: "allOf is not supported by this profile",
      action: "remove allOf or select a profile that supports it"
    )
  end

  defp unsupported_intersection_omen(_policy, path) do
    Omen.lossy("NYA-PROFILE-010",
      schema_path: path,
      rule: "all_of_merged",
      source: "allOf",
      target: "merged schema",
      explanation: "allOf branches merged because the profile does not support allOf"
    )
  end

  defp required_additional_properties_omen(path, source) do
    Omen.lossy("NYA-PROFILE-011",
      schema_path: path,
      rule: "closed_object_required",
      source: "additionalProperties: #{source}",
      target: "additionalProperties: false",
      explanation: "profile requires a closed object, narrowing additional-property semantics"
    )
  end

  defp enforce_projected_object_requirements(%{"type" => "object"} = schema, profile) do
    schema =
      if profile.requires_all_properties_required do
        Map.put(
          schema,
          "required",
          schema |> Map.get("properties", %{}) |> Map.keys() |> Enum.sort()
        )
      else
        schema
      end

    if profile.requires_additional_properties_false do
      Map.put(schema, "additionalProperties", false)
    else
      schema
    end
  end

  defp enforce_projected_object_requirements(schema, _profile), do: schema

  defp schema_valued_additional_properties_omen(:strict, path) do
    Omen.rejected("NYA-PROFILE-011",
      schema_path: path,
      rule: "schema_valued_additional_properties_unsupported",
      source: "additionalProperties schema",
      target: nil,
      explanation: "profile requires additionalProperties: false on every object",
      action: "replace schema-valued additionalProperties with false"
    )
  end

  defp schema_valued_additional_properties_omen(_policy, path) do
    Omen.lossy("NYA-PROFILE-011",
      schema_path: path,
      rule: "schema_valued_additional_properties_replaced",
      source: "additionalProperties schema",
      target: "additionalProperties: false",
      explanation: "schema-valued additionalProperties replaced with false for this profile"
    )
  end

  defp format_omens(nil, _path, _profile), do: []

  defp format_omens(format, path, profile) do
    if format_supported?(format, profile) do
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

  defp format_supported?(format, profile) do
    MapSet.member?(profile.accepted_keywords, "format") and
      (profile.supported_formats == :any or
         MapSet.member?(profile.supported_formats, format))
  end

  defp profile_constraint_omens(scroll, schema, profile) do
    root_object_omens(schema, profile) ++
      schema_depth_omens(scroll, profile) ++ object_depth_omens(scroll, profile)
  end

  defp root_object_omens(%{"type" => "object"}, %{requires_root_object: true}), do: []

  defp root_object_omens(_scroll, %{requires_root_object: true}) do
    [
      Omen.rejected("NYA-PROFILE-008",
        schema_path: [],
        rule: "root_object_required",
        source: "non-object root",
        target: nil,
        explanation: "profile requires the root schema to be an object",
        action: "wrap the schema in a root object"
      )
    ]
  end

  defp root_object_omens(_scroll, _profile), do: []

  defp schema_depth_omens(_scroll, %{max_schema_depth: :unlimited}), do: []

  defp schema_depth_omens(scroll, %{max_schema_depth: limit}) do
    depth = scroll_depth(scroll)

    if depth > limit do
      [depth_omen("schema_depth_exceeded", depth, limit)]
    else
      []
    end
  end

  defp object_depth_omens(_scroll, %{max_object_depth: :unlimited}), do: []

  defp object_depth_omens(scroll, %{max_object_depth: limit}) do
    depth = object_depth(scroll, 0)

    if depth > limit do
      [depth_omen("object_depth_exceeded", depth, limit)]
    else
      []
    end
  end

  defp depth_omen(rule, depth, limit) do
    Omen.rejected("NYA-PROFILE-009",
      schema_path: [],
      rule: rule,
      source: Integer.to_string(depth),
      target: Integer.to_string(limit),
      explanation: "schema exceeds the profile nesting limit",
      action: "reduce schema nesting or select another profile"
    )
  end

  defp scroll_depth(%Scroll{} = scroll) do
    children = scroll_children(scroll)
    1 + Enum.max([0 | Enum.map(children, &scroll_depth/1)])
  end

  defp object_depth(%Scroll{} = scroll, current) do
    next = if scroll.kind == :object, do: current + 1, else: current
    Enum.max([next | Enum.map(scroll_children(scroll), &object_depth(&1, next))])
  end

  defp scroll_children(%Scroll{} = scroll) do
    map_children(scroll.properties) ++
      map_children(scroll.pattern_properties) ++
      map_children(scroll.definitions) ++
      one_child(scroll.additional_properties) ++
      one_child(scroll.items) ++
      one_child(scroll.additional_items) ++
      list_children(scroll.tuple_items) ++ list_children(scroll.branches)
  end

  defp collect_unsupported_keyword_omens(%Scroll{} = scroll, profile) do
    fields = [
      {"title", scroll.title, nil},
      {"default", scroll.default, :unset},
      {"examples", scroll.examples, nil},
      {"minProperties", scroll.min_properties, nil},
      {"maxProperties", scroll.max_properties, nil},
      {"minItems", scroll.min_items, nil},
      {"maxItems", scroll.max_items, nil},
      {"uniqueItems", scroll.unique_items, nil},
      {"pattern", scroll.pattern, nil},
      {"minLength", scroll.min_length, nil},
      {"maxLength", scroll.max_length, nil},
      {"minimum", scroll.minimum, nil},
      {"maximum", scroll.maximum, nil},
      {"exclusiveMinimum", scroll.exclusive_minimum, nil},
      {"exclusiveMaximum", scroll.exclusive_maximum, nil},
      {"multipleOf", scroll.multiple_of, nil}
    ]

    own =
      fields
      |> Enum.filter(fn {keyword, value, sentinel} ->
        value != sentinel and not MapSet.member?(profile.accepted_keywords, keyword)
      end)
      |> Enum.map(fn {keyword, _value, _sentinel} ->
        Omen.lossy("NYA-PROFILE-012",
          schema_path: scroll.path,
          rule: "keyword_dropped",
          source: keyword,
          target: "#{keyword} omitted",
          explanation: "keyword is not accepted by this profile"
        )
      end)

    own ++ Enum.flat_map(scroll_children(scroll), &collect_unsupported_keyword_omens(&1, profile))
  end

  defp collect_unsupported_annotation_omens(%Scroll{} = scroll, profile) do
    annotations = scroll.annotations || %{}

    keys =
      annotations
      |> Map.keys()
      |> Enum.reject(fn key ->
        key == "nya:combinator" or vendor_extension_allowed?(key, profile)
      end)

    keys = keys ++ raw_schema_identifier_keys(scroll.raw)

    own =
      keys
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn keyword ->
        Omen.rejected("NYA-PROFILE-012",
          schema_path: scroll.path,
          rule: "unsupported_schema_construct",
          source: keyword,
          target: nil,
          explanation: "schema construct is not supported by this profile",
          action: "remove the construct or select another profile"
        )
      end)

    own ++
      Enum.flat_map(
        scroll_children(scroll),
        &collect_unsupported_annotation_omens(&1, profile)
      )
  end

  defp raw_schema_identifier_keys(raw) when is_map(raw) do
    Enum.filter(["$id", "$schema"], &Map.has_key?(raw, &1))
  end

  defp raw_schema_identifier_keys(_raw), do: []

  defp vendor_extension_allowed?(keyword, profile) do
    Enum.any?(profile.vendor_extension_prefixes, &String.starts_with?(keyword, &1))
  end

  defp map_children(nil), do: []
  defp map_children(map) when is_map(map), do: Map.values(map)
  defp one_child(%Scroll{} = scroll), do: [scroll]
  defp one_child(_value), do: []
  defp list_children(nil), do: []
  defp list_children(list) when is_list(list), do: list

  defp array_without_items_omen(path, profile, _policy) do
    if MapSet.member?(profile.supported_array_forms, :no_items) do
      Omen.exact("NYA-SCHEMA-009",
        schema_path: path,
        rule: "array_without_items_preserved",
        source: "array without items",
        target: "array without items",
        explanation: "array without items preserved as-is"
      )
    else
      Omen.rejected("NYA-SCHEMA-009",
        schema_path: path,
        rule: "array_without_items_unsupported",
        source: "array without items",
        target: nil,
        explanation: "array without items cannot be represented by this profile",
        action: "define items or select a profile that accepts untyped arrays"
      )
    end
  end

  defp unrepresentable_schema_omen(path, source) do
    Omen.rejected("NYA-PROFILE-012",
      schema_path: path,
      rule: "unsupported_schema_construct",
      source: source,
      target: nil,
      explanation: "schema cannot be represented by this profile",
      action: "use a supported typed schema or select another profile"
    )
  end

  defp maybe_put_metadata(schema, scroll, profile) do
    schema
    |> maybe_put_description(accepted_value(scroll.description, "description", profile), profile)
    |> maybe_put_metadata_value("title", scroll.title, profile)
    |> maybe_put_metadata_value("default", scroll.default, profile)
    |> maybe_put_metadata_value("examples", scroll.examples, profile)
  end

  defp maybe_put_metadata_value(schema, "default", value, profile) when value != :unset do
    if MapSet.member?(profile.accepted_keywords, "default"),
      do: Map.put(schema, "default", value),
      else: schema
  end

  defp maybe_put_metadata_value(schema, _key, nil, _profile), do: schema
  defp maybe_put_metadata_value(schema, _key, :unset, _profile), do: schema

  defp maybe_put_metadata_value(schema, key, value, profile) do
    if MapSet.member?(profile.accepted_keywords, key),
      do: Map.put(schema, key, value),
      else: schema
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
    if is_nil(scroll.raw), do: fallback_rejected_schema(scroll), else: scroll.raw
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
