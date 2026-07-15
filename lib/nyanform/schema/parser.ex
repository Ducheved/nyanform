defmodule Nyanform.Schema.Parser do
  alias Nyanform.Schema.{Reference, Scroll}

  @type combinator :: :oneOf | :anyOf | :allOf | nil
  @schema_types ~w(object array string integer number boolean null)
  @map_keywords ~w(properties patternProperties $defs definitions)
  @branch_keywords ~w(oneOf anyOf allOf)
  @additional_keywords ~w(additionalProperties additionalItems)
  @string_keywords ~w(description title format pattern $ref $schema $id)
  @non_negative_integer_keywords ~w(minLength maxLength minItems maxItems minProperties maxProperties)
  @number_keywords ~w(minimum maximum exclusiveMinimum exclusiveMaximum)

  @spec parse(term(), Scroll.path(), non_neg_integer(), pos_integer()) ::
          {:ok, Scroll.t()} | {:error, Nyanform.Schema.ValidationError.t()}
  def parse(node, path \\ [], depth \\ 0, max_depth \\ 64)

  def parse(_node, _path, depth, max_depth) when depth > max_depth do
    {:error, %Nyanform.Schema.ValidationError{code: :schema_depth_exceeded, path: ["__root__"]}}
  end

  def parse(true, path, _depth, _max_depth), do: {:ok, %{Scroll.any(path) | raw: true}}
  def parse(false, path, _depth, _max_depth), do: {:ok, %{Scroll.never(path) | raw: false}}
  def parse(%Scroll{} = scroll, _path, _depth, _max_depth), do: {:ok, scroll}

  def parse(node, path, depth, max_depth) when is_map(node) do
    with {:ok, base} <- parse_node(node, path, depth, max_depth) do
      attach_definitions(base, node, path, depth, max_depth)
    end
  end

  def parse(_node, path, _depth, _max_depth) do
    {:error,
     %Nyanform.Schema.ValidationError{code: :invalid_schema_node, path: path ++ ["__root__"]}}
  end

  defp attach_definitions(%Scroll{} = scroll, node, path, depth, max_depth) do
    raw_defs = Map.get(node, "$defs") || Map.get(node, "definitions")

    if raw_defs == nil do
      {:ok, scroll}
    else
      with {:ok, defs} <- parse_definition_map(raw_defs, path, depth, max_depth) do
        {:ok, %{scroll | definitions: defs}}
      end
    end
  end

  defp parse_definition_map(raw_defs, path, depth, max_depth) when is_map(raw_defs) do
    Enum.reduce_while(raw_defs, {:ok, %{}}, fn {name, raw_schema}, {:ok, acc} ->
      case parse(raw_schema, path ++ ["$defs", name], depth + 1, max_depth) do
        {:ok, parsed} -> {:cont, {:ok, Map.put(acc, name, parsed)}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_definition_map(_raw, path, _depth, _max_depth) do
    {:error,
     %Nyanform.Schema.ValidationError{code: :invalid_property_map, path: path ++ ["$defs"]}}
  end

  defp parse_node(node, path, depth, max_depth) do
    combinator = detect_combinator(node)
    has_ref = Map.has_key?(node, "$ref")
    has_const = Map.has_key?(node, "const")
    has_enum = Map.has_key?(node, "enum")

    base = %Scroll{
      path: path,
      description: Map.get(node, "description"),
      title: Map.get(node, "title"),
      default: Map.get(node, "default", :unset),
      examples: Map.get(node, "examples"),
      annotations: extract_annotations(node),
      raw: node
    }

    with :ok <- validate_type_keyword(node, path),
         :ok <- validate_keyword_shapes(node, path, depth, max_depth) do
      cond do
        combinator != nil ->
          parse_combinator(base, node, combinator, path, depth, max_depth)

        has_ref ->
          parse_ref_node(base, node)

        true ->
          parse_value_node(base, node, has_const, has_enum, path, depth, max_depth)
      end
    end
  end

  defp validate_type_keyword(node, path) do
    case Map.fetch(node, "type") do
      :error -> :ok
      {:ok, type} -> validate_type_value(type, path)
    end
  end

  defp validate_type_value(type, path) when is_binary(type) do
    if type in @schema_types, do: :ok, else: invalid_type(path)
  end

  defp validate_type_value(types, path) when is_list(types) do
    valid =
      types != [] and
        Enum.uniq(types) == types and
        Enum.all?(types, &(is_binary(&1) and &1 in @schema_types))

    if valid, do: :ok, else: invalid_type(path)
  end

  defp validate_type_value(_type, path), do: invalid_type(path)

  defp invalid_type(path) do
    {:error, %Nyanform.Schema.ValidationError{code: :invalid_type, path: path ++ ["type"]}}
  end

  defp validate_keyword_shapes(node, path, depth, max_depth) do
    with :ok <- validate_keywords(node, @map_keywords, &valid_schema_map?/1, path),
         :ok <- validate_keywords(node, ["required"], &valid_required?/1, path),
         :ok <- validate_keywords(node, ["enum"], &is_list/1, path),
         :ok <- validate_keywords(node, @branch_keywords, &valid_branches?/1, path),
         :ok <- validate_keywords(node, @additional_keywords, &valid_schema_value?/1, path),
         :ok <- validate_keywords(node, ["items"], &valid_items?/1, path),
         :ok <- validate_keywords(node, @string_keywords, &is_binary/1, path),
         :ok <- validate_keywords(node, ["examples"], &is_list/1, path),
         :ok <-
           validate_keywords(
             node,
             @non_negative_integer_keywords,
             &non_negative_integer?/1,
             path
           ),
         :ok <- validate_keywords(node, @number_keywords, &is_number/1, path),
         :ok <- validate_keywords(node, ["multipleOf"], &positive_number?/1, path),
         :ok <- validate_keywords(node, ["uniqueItems"], &is_boolean/1, path),
         do: validate_schema_children(node, path, depth, max_depth)
  end

  defp validate_schema_children(node, path, depth, max_depth) do
    with :ok <- validate_schema_maps(node, path, depth, max_depth),
         :ok <- validate_schema_values(node, path, depth, max_depth),
         :ok <- validate_schema_lists(node, path, depth, max_depth),
         do: validate_items_children(node, path, depth, max_depth)
  end

  defp validate_schema_maps(node, path, depth, max_depth) do
    Enum.reduce_while(@map_keywords, :ok, fn keyword, :ok ->
      case Map.fetch(node, keyword) do
        {:ok, schemas} ->
          schemas
          |> validate_schema_map_entries(path, keyword, depth, max_depth)
          |> validation_step()

        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_schema_map_entries(schemas, path, keyword, depth, max_depth) do
    Enum.reduce_while(schemas, :ok, fn {name, schema}, :ok ->
      schema
      |> validate_schema_term(path ++ [keyword, name], depth + 1, max_depth)
      |> validation_step()
    end)
  end

  defp validate_schema_values(node, path, depth, max_depth) do
    Enum.reduce_while(@additional_keywords, :ok, fn keyword, :ok ->
      case Map.fetch(node, keyword) do
        {:ok, schema} ->
          schema
          |> validate_schema_term(path ++ [keyword], depth + 1, max_depth)
          |> validation_step()

        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_schema_lists(node, path, depth, max_depth) do
    Enum.reduce_while(@branch_keywords, :ok, fn keyword, :ok ->
      case Map.fetch(node, keyword) do
        {:ok, schemas} ->
          schemas
          |> validate_schema_list(path, keyword, depth, max_depth)
          |> validation_step()

        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_items_children(node, path, depth, max_depth) do
    case Map.fetch(node, "items") do
      {:ok, schemas} when is_list(schemas) ->
        validate_schema_list(schemas, path, "items", depth, max_depth)

      {:ok, schema} ->
        validate_schema_term(schema, path ++ ["items"], depth + 1, max_depth)

      :error ->
        :ok
    end
  end

  defp validate_schema_list(schemas, path, keyword, depth, max_depth) do
    schemas
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {schema, index}, :ok ->
      child_path = path ++ [keyword, Integer.to_string(index)]

      schema
      |> validate_schema_term(child_path, depth + 1, max_depth)
      |> validation_step()
    end)
  end

  defp validation_step(:ok), do: {:cont, :ok}
  defp validation_step({:error, _error} = error), do: {:halt, error}

  defp validate_schema_term(_schema, path, depth, max_depth) when depth > max_depth do
    {:error, %Nyanform.Schema.ValidationError{code: :schema_depth_exceeded, path: path}}
  end

  defp validate_schema_term(schema, _path, _depth, _max_depth) when is_boolean(schema), do: :ok

  defp validate_schema_term(schema, path, depth, max_depth) when is_map(schema) do
    with :ok <- validate_type_keyword(schema, path) do
      validate_keyword_shapes(schema, path, depth, max_depth)
    end
  end

  defp validate_schema_term(_schema, path, _depth, _max_depth) do
    {:error,
     %Nyanform.Schema.ValidationError{code: :invalid_schema_node, path: path ++ ["__root__"]}}
  end

  defp validate_keywords(node, keywords, predicate, path) do
    Enum.reduce_while(keywords, :ok, fn keyword, :ok ->
      case Map.fetch(node, keyword) do
        :error ->
          {:cont, :ok}

        {:ok, value} ->
          if predicate.(value), do: {:cont, :ok}, else: {:halt, invalid_keyword(path, keyword)}
      end
    end)
  end

  defp valid_schema_map?(value) do
    is_map(value) and Enum.all?(Map.keys(value), &is_binary/1)
  end

  defp valid_required?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp valid_branches?(value), do: is_list(value) and value != []
  defp valid_schema_value?(value), do: is_boolean(value) or is_map(value)
  defp valid_items?(value), do: is_boolean(value) or is_map(value) or is_list(value)
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp positive_number?(value), do: is_number(value) and value > 0

  defp invalid_keyword(path, keyword) do
    {:error,
     %Nyanform.Schema.ValidationError{
       code: :invalid_keyword_value,
       path: path ++ [keyword]
     }}
  end

  defp detect_combinator(%{"oneOf" => _}), do: :oneOf
  defp detect_combinator(%{"anyOf" => _}), do: :anyOf
  defp detect_combinator(%{"allOf" => _}), do: :allOf
  defp detect_combinator(_), do: nil

  defp parse_combinator(base, node, combinator, path, depth, max_depth) do
    raw_branches = Map.get(node, Atom.to_string(combinator))
    key = Atom.to_string(combinator)

    with {:ok, branches} <- parse_branch_list(raw_branches, path, key, depth, max_depth) do
      kind =
        case combinator do
          :allOf -> :intersection
          _ -> :union
        end

      annotations =
        case base.annotations do
          nil -> %{"nya:combinator" => Atom.to_string(combinator)}
          existing -> Map.put(existing, "nya:combinator", Atom.to_string(combinator))
        end

      base = %{base | kind: kind, branches: branches, annotations: annotations}
      {:ok, attach_sibling_constraints(base, node)}
    end
  end

  defp parse_ref_node(base, node) do
    raw_ref = Map.get(node, "$ref")

    case Reference.parse(raw_ref) do
      {:ok, target} ->
        ref_scroll = %{base | kind: :ref, ref_target: target}
        {:ok, attach_sibling_constraints(ref_scroll, node)}

      :error ->
        {:error,
         %Nyanform.Schema.ValidationError{code: :invalid_schema_node, path: base.path ++ ["$ref"]}}
    end
  end

  defp parse_value_node(base, node, has_const, has_enum, path, depth, max_depth) do
    enum = Map.get(node, "enum")

    if has_enum and enum != nil and not is_list(enum) do
      {:error, %Nyanform.Schema.ValidationError{code: :invalid_enum, path: path}}
    else
      type = resolve_type(node)

      inferred_kind =
        cond do
          type != :unknown -> type
          has_const -> :const
          has_enum -> :enum
          true -> type
        end

      base = %{base | kind: inferred_kind}

      with {:ok, typed} <- apply_type(base, inferred_kind, node, path, depth, max_depth),
           with_enum <- maybe_attach_const_enum(typed, node, has_const, has_enum),
           final <- attach_numeric_constraints(with_enum, node) do
        {:ok, final}
      end
    end
  end

  defp maybe_attach_const(%Scroll{} = scroll, node) do
    if Map.has_key?(node, "const") do
      %{scroll | const: Map.get(node, "const")}
    else
      scroll
    end
  end

  defp maybe_attach_enum(%Scroll{} = scroll, node) do
    enum = Map.get(node, "enum")

    if is_list(enum) do
      %{scroll | enum: enum}
    else
      if enum != nil do
        scroll
      else
        scroll
      end
    end
  end

  defp maybe_attach_const_enum(scroll, node, _has_const, _has_enum) do
    scroll
    |> maybe_attach_const(node)
    |> maybe_attach_enum(node)
  end

  defp attach_sibling_constraints(%Scroll{} = scroll, node) do
    scroll
    |> maybe_attach_const(node)
    |> maybe_attach_enum(node)
    |> attach_numeric_constraints(node)
  end

  defp attach_numeric_constraints(%Scroll{} = scroll, node) do
    numeric_fields = [
      {"minimum", :minimum},
      {"maximum", :maximum},
      {"exclusiveMinimum", :exclusive_minimum},
      {"exclusiveMaximum", :exclusive_maximum},
      {"multipleOf", :multiple_of}
    ]

    has_any =
      Enum.any?(numeric_fields, fn {key, _} -> Map.has_key?(node, key) end)

    if has_any do
      Enum.reduce(numeric_fields, scroll, fn {json_key, field}, acc ->
        case Map.get(node, json_key) do
          nil -> acc
          value -> %{acc | field => value}
        end
      end)
    else
      scroll
    end
  end

  defp parse_branch_list(nil, path, key, _depth, _max_depth) do
    {:error, %Nyanform.Schema.ValidationError{code: :missing_branches, path: path ++ [key]}}
  end

  defp parse_branch_list(raw_branches, path, key, depth, max_depth) when is_list(raw_branches) do
    results =
      raw_branches
      |> Enum.with_index()
      |> Enum.map(fn {child, index} ->
        parse(child, path ++ [key, Integer.to_string(index)], depth + 1, max_depth)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, s} -> s end)}
      error -> error
    end
  end

  defp parse_branch_list(_raw, path, key, _depth, _max_depth) do
    {:error, %Nyanform.Schema.ValidationError{code: :invalid_branches, path: path ++ [key]}}
  end

  defp resolve_type(%{"type" => types}) when is_list(types) do
    if length(types) == 1, do: type_atom(hd(types)), else: :union_of_types
  end

  defp resolve_type(%{"type" => type}) when is_binary(type), do: type_atom(type)

  defp resolve_type(node) when is_map(node) do
    cond do
      Map.has_key?(node, "properties") or Map.has_key?(node, "additionalProperties") ->
        :object

      Map.has_key?(node, "items") ->
        :array

      true ->
        :unknown
    end
  end

  defp type_atom("object"), do: :object
  defp type_atom("array"), do: :array
  defp type_atom("string"), do: :string
  defp type_atom("integer"), do: :integer
  defp type_atom("number"), do: :number
  defp type_atom("boolean"), do: :boolean
  defp type_atom("null"), do: :null
  defp type_atom(_), do: :unknown

  defp apply_type(%Scroll{} = scroll, :union_of_types, node, path, depth, max_depth) do
    types = Map.get(node, "type")

    result =
      types
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {type, index}, {:ok, branches} ->
        single = Map.put(node, "type", type)

        case parse(single, path ++ ["type", Integer.to_string(index)], depth + 1, max_depth) do
          {:ok, branch} -> {:cont, {:ok, [branch | branches]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    case result do
      {:ok, branches} -> {:ok, %Scroll{scroll | kind: :union, branches: Enum.reverse(branches)}}
      {:error, error} -> {:error, error}
    end
  end

  defp apply_type(%Scroll{} = scroll, :object, node, path, depth, max_depth) do
    with {:ok, properties} <-
           parse_property_map(Map.get(node, "properties"), path, "properties", depth, max_depth),
         {:ok, pattern_properties} <-
           parse_property_map(
             Map.get(node, "patternProperties"),
             path,
             "patternProperties",
             depth,
             max_depth
           ),
         {:ok, required} <- parse_required(Map.get(node, "required"), path),
         {:ok, additional} <-
           parse_additional(
             Map.get(node, "additionalProperties"),
             path,
             "additionalProperties",
             depth,
             max_depth
           ) do
      {:ok,
       %Scroll{
         scroll
         | properties: properties,
           required: required,
           pattern_properties: pattern_properties,
           additional_properties: additional,
           min_properties: Map.get(node, "minProperties"),
           max_properties: Map.get(node, "maxProperties")
       }}
    end
  end

  defp apply_type(%Scroll{} = scroll, :array, node, path, depth, max_depth) do
    items = Map.get(node, "items")

    cond do
      is_list(items) ->
        with {:ok, tuple_items} <-
               parse_branch_list(items, path, "items", depth, max_depth),
             {:ok, additional_items} <-
               parse_additional(
                 Map.get(node, "additionalItems"),
                 path,
                 "additionalItems",
                 depth,
                 max_depth
               ) do
          {:ok,
           %Scroll{
             scroll
             | tuple_items: tuple_items,
               additional_items: additional_items,
               min_items: Map.get(node, "minItems"),
               max_items: Map.get(node, "maxItems"),
               unique_items: Map.get(node, "uniqueItems")
           }}
        end

      is_map(items) ->
        case parse(items, path ++ ["items"], depth + 1, max_depth) do
          {:ok, parsed_items} ->
            {:ok,
             %Scroll{
               scroll
               | items: parsed_items,
                 min_items: Map.get(node, "minItems"),
                 max_items: Map.get(node, "maxItems"),
                 unique_items: Map.get(node, "uniqueItems")
             }}

          error ->
            error
        end

      is_boolean(items) ->
        case parse(items, path ++ ["items"], depth + 1, max_depth) do
          {:ok, parsed_items} ->
            {:ok,
             %Scroll{
               scroll
               | items: parsed_items,
                 min_items: Map.get(node, "minItems"),
                 max_items: Map.get(node, "maxItems"),
                 unique_items: Map.get(node, "uniqueItems")
             }}

          error ->
            error
        end

      true ->
        {:ok,
         %Scroll{
           scroll
           | items: nil,
             min_items: Map.get(node, "minItems"),
             max_items: Map.get(node, "maxItems"),
             unique_items: Map.get(node, "uniqueItems")
         }}
    end
  end

  defp apply_type(%Scroll{} = scroll, :string, node, _path, _depth, _max_depth) do
    {:ok,
     %Scroll{
       scroll
       | format: Map.get(node, "format"),
         pattern: Map.get(node, "pattern"),
         min_length: Map.get(node, "minLength"),
         max_length: Map.get(node, "maxLength")
     }}
  end

  defp apply_type(%Scroll{} = scroll, :integer, node, _path, _depth, _max_depth) do
    {:ok, apply_numeric(scroll, node)}
  end

  defp apply_type(%Scroll{} = scroll, :number, node, _path, _depth, _max_depth) do
    {:ok, apply_numeric(scroll, node)}
  end

  defp apply_type(%Scroll{} = scroll, _type, _node, _path, _depth, _max_depth) do
    {:ok, scroll}
  end

  defp apply_numeric(%Scroll{} = scroll, node) do
    %Scroll{
      scroll
      | minimum: Map.get(node, "minimum"),
        maximum: Map.get(node, "maximum"),
        exclusive_minimum: Map.get(node, "exclusiveMinimum"),
        exclusive_maximum: Map.get(node, "exclusiveMaximum"),
        multiple_of: Map.get(node, "multipleOf")
    }
  end

  defp parse_property_map(nil, _path, _key, _depth, _max_depth), do: {:ok, nil}

  defp parse_property_map(map, path, key, depth, max_depth) when is_map(map) do
    results =
      map
      |> Enum.map(fn {name, child} ->
        case parse(child, path ++ [key, name], depth + 1, max_depth) do
          {:ok, parsed} -> {name, parsed}
          error -> error
        end
      end)

    case Enum.find(results, &(not is_tuple(&1) or match?({:error, _}, &1))) do
      nil -> {:ok, Map.new(results)}
      {:error, _} = error -> error
    end
  end

  defp parse_property_map(_raw, path, key, _depth, _max_depth) do
    {:error, %Nyanform.Schema.ValidationError{code: :invalid_property_map, path: path ++ [key]}}
  end

  defp parse_required(nil, _path), do: {:ok, nil}

  defp parse_required(required, path) when is_list(required) do
    if Enum.all?(required, &is_binary/1) do
      {:ok, required}
    else
      invalid_required(path)
    end
  end

  defp parse_required(_required, path), do: invalid_required(path)

  defp invalid_required(path) do
    {:error,
     %Nyanform.Schema.ValidationError{code: :invalid_required, path: path ++ ["required"]}}
  end

  defp parse_additional(nil, _path, _key, _depth, _max_depth), do: {:ok, nil}
  defp parse_additional(true, _path, _key, _depth, _max_depth), do: {:ok, nil}
  defp parse_additional(false, _path, _key, _depth, _max_depth), do: {:ok, false}

  defp parse_additional(schema, path, key, depth, max_depth) when is_map(schema) do
    parse(schema, path ++ [key], depth + 1, max_depth)
  end

  defp parse_additional(_raw, path, key, _depth, _max_depth) do
    {:error,
     %Nyanform.Schema.ValidationError{code: :invalid_additional_properties, path: path ++ [key]}}
  end

  defp extract_annotations(node) when is_map(node) do
    known = ~w(type properties required additionalProperties patternProperties
               items additionalItems minItems maxItems uniqueItems description title
               default examples format pattern minLength maxLength enum const
               minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
               minProperties maxProperties oneOf anyOf allOf $ref $defs definitions
               $schema $id)

    node
    |> Enum.reject(fn {key, _} -> key in known end)
    |> case do
      [] -> nil
      entries -> Map.new(entries)
    end
  end
end
