defmodule Nyanform.Schema.Reference do
  alias Nyanform.Limits
  alias Nyanform.Schema.Scroll
  alias Nyanform.Schema.ValidationError

  @type fragment :: :none | :empty | {:pointer, [String.t()]} | {:anchor, String.t()}
  @type t :: %__MODULE__{uri: String.t(), fragment: fragment()}

  defstruct uri: "", fragment: :none

  @spec parse(term()) :: {:ok, t()} | :error
  def parse(ref) when is_binary(ref) do
    case String.split(ref, "#", parts: 2) do
      [uri] -> {:ok, %__MODULE__{uri: uri}}
      [uri, ""] -> {:ok, %__MODULE__{uri: uri, fragment: :empty}}
      [uri, "/" <> pointer] -> {:ok, %__MODULE__{uri: uri, fragment: parse_pointer(pointer)}}
      [uri, anchor] -> {:ok, %__MODULE__{uri: uri, fragment: {:anchor, anchor}}}
    end
  end

  def parse(_ref), do: :error

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{uri: uri, fragment: :none}), do: uri
  def to_string(%__MODULE__{uri: uri, fragment: :empty}), do: uri <> "#"

  def to_string(%__MODULE__{uri: uri, fragment: {:pointer, tokens}}) do
    uri <> "#/" <> Enum.map_join(tokens, "/", &encode_pointer_token/1)
  end

  def to_string(%__MODULE__{uri: uri, fragment: {:anchor, anchor}}), do: uri <> "#" <> anchor

  @spec normalize_definition_refs(term()) :: term()
  def normalize_definition_refs(schema) do
    normalize_definition_refs(schema, Limits.default().max_schema_depth)
  end

  @spec normalize_definition_refs(term(), non_neg_integer()) :: term()
  def normalize_definition_refs(schema, max_depth)
      when is_map(schema) and is_integer(max_depth) and max_depth >= 0 do
    normalize_definition_refs_at(schema, schema, 0, max_depth)
  end

  def normalize_definition_refs(schema, max_depth)
      when is_integer(max_depth) and max_depth >= 0,
      do: schema

  @spec dangling_local_refs(term()) :: [%{path: Scroll.path(), reference: String.t()}]
  def dangling_local_refs(schema) do
    dangling_local_refs(schema, Limits.default().max_schema_depth)
  end

  @spec dangling_local_refs(term(), non_neg_integer()) :: [
          %{path: Scroll.path(), reference: String.t()}
        ]
  def dangling_local_refs(schema, max_depth)
      when is_map(schema) and is_integer(max_depth) and max_depth >= 0 do
    normalized = normalize_definition_refs(schema, max_depth)

    normalized
    |> collect_dangling_local_refs(normalized, [], 0, max_depth)
    |> Enum.sort_by(fn %{path: path, reference: reference} -> {path, reference} end)
  end

  def dangling_local_refs(_schema, max_depth)
      when is_integer(max_depth) and max_depth >= 0,
      do: []

  @spec local?(t()) :: boolean()
  def local?(%__MODULE__{uri: ""}), do: true
  def local?(%__MODULE__{}), do: false

  @spec definition_name(t() | nil) :: String.t() | nil
  def definition_name(%__MODULE__{
        uri: "",
        fragment: {:pointer, [container, name | _rest]}
      })
      when container in ["$defs", "definitions"],
      do: name

  def definition_name(_reference), do: nil

  @spec resolve(Scroll.t(), %{optional(String.t()) => Scroll.t()}) ::
          {:ok, Scroll.t()} | {:error, ValidationError.t()}
  def resolve(scroll, definitions) do
    resolve(scroll, definitions, %{}, 0, 32)
  end

  defp resolve(%Scroll{kind: :ref} = ref, _definitions, _seen, depth, max_depth)
       when depth >= max_depth do
    {:error, %ValidationError{code: :reference_depth_exceeded, path: ref.path}}
  end

  defp resolve(%Scroll{kind: :ref, ref_target: target} = ref, definitions, seen, depth, max_depth) do
    case definition_name(target) do
      nil ->
        {:ok, ref}

      name ->
        if Map.has_key?(seen, name) do
          {:ok, %Scroll{ref | recursive: true}}
        else
          case Map.fetch(definitions, name) do
            {:ok, resolved} ->
              seen = Map.put(seen, name, true)
              resolve(resolved, definitions, seen, depth + 1, max_depth)

            :error ->
              {:ok, ref}
          end
        end
    end
  end

  defp resolve(%Scroll{} = scroll, definitions, seen, depth, max_depth) do
    with {:ok, properties} <- resolve_map(scroll.properties, definitions, seen, depth, max_depth),
         {:ok, pattern} <-
           resolve_map(scroll.pattern_properties, definitions, seen, depth, max_depth),
         {:ok, additional} <-
           resolve_additional(scroll.additional_properties, definitions, seen, depth, max_depth),
         {:ok, items} <- resolve_optional(scroll.items, definitions, seen, depth, max_depth),
         {:ok, tuple_items} <-
           resolve_list(scroll.tuple_items, definitions, seen, depth, max_depth),
         {:ok, additional_items} <-
           resolve_additional(scroll.additional_items, definitions, seen, depth, max_depth),
         {:ok, branches} <-
           resolve_list(scroll.branches, definitions, seen, depth, max_depth) do
      {:ok,
       %Scroll{
         scroll
         | properties: properties,
           pattern_properties: pattern,
           additional_properties: additional,
           items: items,
           tuple_items: tuple_items,
           additional_items: additional_items,
           branches: branches
       }}
    end
  end

  defp resolve_map(nil, _defs, _seen, _depth, _max_depth), do: {:ok, nil}

  defp resolve_map(map, defs, seen, depth, max_depth) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {name, child}, {:ok, acc} ->
      case resolve(child, defs, seen, depth, max_depth) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, name, resolved)}}
        error -> {:halt, error}
      end
    end)
  end

  defp resolve_list(nil, _defs, _seen, _depth, _max_depth), do: {:ok, nil}

  defp resolve_list(list, defs, seen, depth, max_depth) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn child, {:ok, acc} ->
      case resolve(child, defs, seen, depth, max_depth) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        error -> {:halt, error}
      end
    end)
  end

  defp resolve_optional(nil, _defs, _seen, _depth, _max_depth), do: {:ok, nil}

  defp resolve_optional(scroll, defs, seen, depth, max_depth) do
    resolve(scroll, defs, seen, depth, max_depth)
  end

  defp resolve_additional(nil, _defs, _seen, _depth, _max_depth), do: {:ok, nil}
  defp resolve_additional(false, _defs, _seen, _depth, _max_depth), do: {:ok, false}

  defp resolve_additional(scroll, defs, seen, depth, max_depth) do
    resolve(scroll, defs, seen, depth, max_depth)
  end

  @spec detect_cycles(Scroll.t(), %{optional(String.t()) => Scroll.t()}) :: boolean()
  def detect_cycles(scroll, definitions) do
    detect_cycles(scroll, definitions, %{})
  end

  defp detect_cycles(%Scroll{kind: :ref, ref_target: target}, definitions, seen) do
    case definition_name(target) do
      nil ->
        false

      name ->
        if Map.has_key?(seen, name) do
          true
        else
          case Map.fetch(definitions, name) do
            {:ok, resolved} -> detect_cycles(resolved, definitions, Map.put(seen, name, true))
            :error -> false
          end
        end
    end
  end

  defp detect_cycles(%Scroll{} = scroll, definitions, seen) do
    children = collect_children(scroll)

    Enum.any?(children, fn child ->
      detect_cycles(child, definitions, seen)
    end)
  end

  defp collect_children(%Scroll{} = scroll) do
    map_children(scroll.properties) ++
      map_children(scroll.pattern_properties) ++
      optional_child(scroll.additional_properties) ++
      optional_child(scroll.items) ++
      list_children(scroll.tuple_items) ++
      optional_child(scroll.additional_items) ++
      list_children(scroll.branches)
  end

  defp map_children(map) when is_map(map), do: Map.values(map)
  defp map_children(_map), do: []

  defp optional_child(%Scroll{} = child), do: [child]
  defp optional_child(_child), do: []

  defp list_children(children) when is_list(children), do: children
  defp list_children(_children), do: []

  defp parse_pointer(pointer) do
    {:pointer, pointer |> String.split("/", trim: false) |> Enum.map(&decode_pointer_token/1)}
  end

  defp decode_pointer_token(token) do
    token
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  defp encode_pointer_token(token) do
    token
    |> String.replace("~", "~0")
    |> String.replace("/", "~1")
  end

  defp collect_dangling_local_refs(schema, root, path, depth, max_depth)
       when is_map(schema) do
    own = dangling_ref(schema, root, path, max_depth)

    if depth >= max_depth do
      own
    else
      own ++
        collect_schema_maps(
          schema,
          root,
          path,
          ~w(properties patternProperties $defs definitions dependentSchemas),
          depth,
          max_depth
        ) ++
        collect_schema_children(
          schema,
          root,
          path,
          ~w(additionalProperties additionalItems items not if then else contains propertyNames
             unevaluatedProperties unevaluatedItems contentSchema),
          depth,
          max_depth
        ) ++
        collect_schema_lists(
          schema,
          root,
          path,
          ~w(prefixItems allOf anyOf oneOf),
          depth,
          max_depth
        )
    end
  end

  defp collect_dangling_local_refs(_schema, _root, _path, _depth, _max_depth), do: []

  defp dangling_ref(%{"$ref" => reference}, root, path, max_depth)
       when is_binary(reference) do
    case parse(reference) do
      {:ok, %__MODULE__{uri: "", fragment: {:pointer, tokens}}} ->
        if pointer_exists?(root, tokens, max_depth) do
          []
        else
          [%{path: path ++ ["$ref"], reference: reference}]
        end

      _ ->
        []
    end
  end

  defp dangling_ref(_schema, _root, _path, _max_depth), do: []

  defp collect_schema_maps(schema, root, path, keys, depth, max_depth) do
    Enum.flat_map(keys, fn key ->
      case Map.get(schema, key) do
        children when is_map(children) ->
          children
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.flat_map(fn {name, child} ->
            collect_dangling_local_refs(
              child,
              root,
              path ++ [key, name],
              depth + 1,
              max_depth
            )
          end)

        _ ->
          []
      end
    end)
  end

  defp collect_schema_children(schema, root, path, keys, depth, max_depth) do
    Enum.flat_map(keys, fn key ->
      case Map.get(schema, key) do
        children when is_list(children) ->
          children
          |> Enum.with_index()
          |> Enum.flat_map(fn {child, index} ->
            collect_dangling_local_refs(
              child,
              root,
              path ++ [key, Integer.to_string(index)],
              depth + 1,
              max_depth
            )
          end)

        child ->
          collect_dangling_local_refs(child, root, path ++ [key], depth + 1, max_depth)
      end
    end)
  end

  defp collect_schema_lists(schema, root, path, keys, depth, max_depth) do
    Enum.flat_map(keys, fn key ->
      case Map.get(schema, key) do
        children when is_list(children) ->
          children
          |> Enum.with_index()
          |> Enum.flat_map(fn {child, index} ->
            collect_dangling_local_refs(
              child,
              root,
              path ++ [key, Integer.to_string(index)],
              depth + 1,
              max_depth
            )
          end)

        _ ->
          []
      end
    end)
  end

  defp pointer_exists?(root, tokens, max_depth),
    do: pointer_exists_at?(root, tokens, 0, max_depth)

  defp pointer_exists_at?(_current, [], _depth, _max_depth), do: true

  defp pointer_exists_at?(_current, [_token | _rest], depth, max_depth)
       when depth >= max_depth,
       do: true

  defp pointer_exists_at?(current, [token | rest], depth, max_depth) do
    case fetch_pointer_token(current, token) do
      {:ok, next} -> pointer_exists_at?(next, rest, depth + 1, max_depth)
      :error -> false
    end
  end

  defp fetch_pointer_token(current, token) when is_map(current), do: Map.fetch(current, token)

  defp fetch_pointer_token(current, token) when is_list(current) do
    case Integer.parse(token) do
      {index, ""} when index >= 0 ->
        if Integer.to_string(index) == token and index < length(current),
          do: {:ok, Enum.at(current, index)},
          else: :error

      _ ->
        :error
    end
  end

  defp fetch_pointer_token(_current, _token), do: :error

  defp normalize_definition_refs_at(value, root, depth, max_depth) when is_map(value) do
    normalized = normalize_ref(value, root, max_depth)

    if depth >= max_depth do
      normalized
    else
      normalized
      |> normalize_schema_map("properties", root, depth, max_depth)
      |> normalize_schema_map("patternProperties", root, depth, max_depth)
      |> normalize_schema_map("$defs", root, depth, max_depth)
      |> normalize_schema_map("definitions", root, depth, max_depth)
      |> normalize_schema_map("dependentSchemas", root, depth, max_depth)
      |> normalize_schema_child("additionalProperties", root, depth, max_depth)
      |> normalize_schema_child("additionalItems", root, depth, max_depth)
      |> normalize_schema_child("items", root, depth, max_depth)
      |> normalize_schema_child("not", root, depth, max_depth)
      |> normalize_schema_child("if", root, depth, max_depth)
      |> normalize_schema_child("then", root, depth, max_depth)
      |> normalize_schema_child("else", root, depth, max_depth)
      |> normalize_schema_child("contains", root, depth, max_depth)
      |> normalize_schema_child("propertyNames", root, depth, max_depth)
      |> normalize_schema_child("unevaluatedProperties", root, depth, max_depth)
      |> normalize_schema_child("unevaluatedItems", root, depth, max_depth)
      |> normalize_schema_child("contentSchema", root, depth, max_depth)
      |> normalize_schema_list("prefixItems", root, depth, max_depth)
      |> normalize_schema_list("allOf", root, depth, max_depth)
      |> normalize_schema_list("anyOf", root, depth, max_depth)
      |> normalize_schema_list("oneOf", root, depth, max_depth)
    end
  end

  defp normalize_definition_refs_at(value, _root, _depth, _max_depth), do: value

  defp normalize_ref(%{"$ref" => ref} = schema, root, max_depth) when is_binary(ref) do
    Map.put(schema, "$ref", normalize_definition_ref(ref, root, max_depth))
  end

  defp normalize_ref(schema, _root, _max_depth), do: schema

  defp normalize_schema_map(schema, key, root, depth, max_depth) do
    case Map.get(schema, key) do
      children when is_map(children) ->
        Map.put(
          schema,
          key,
          Map.new(children, fn {name, child} ->
            {name, normalize_definition_refs_at(child, root, depth + 1, max_depth)}
          end)
        )

      _ ->
        schema
    end
  end

  defp normalize_schema_child(schema, key, root, depth, max_depth) do
    case Map.get(schema, key) do
      child when is_map(child) ->
        Map.put(
          schema,
          key,
          normalize_definition_refs_at(child, root, depth + 1, max_depth)
        )

      children when is_list(children) ->
        Map.put(
          schema,
          key,
          Enum.map(
            children,
            &normalize_definition_refs_at(&1, root, depth + 1, max_depth)
          )
        )

      _ ->
        schema
    end
  end

  defp normalize_schema_list(schema, key, root, depth, max_depth) do
    case Map.get(schema, key) do
      children when is_list(children) ->
        Map.put(
          schema,
          key,
          Enum.map(
            children,
            &normalize_definition_refs_at(&1, root, depth + 1, max_depth)
          )
        )

      _ ->
        schema
    end
  end

  defp normalize_definition_ref(ref, root, max_depth) do
    case parse(ref) do
      {:ok, %__MODULE__{uri: "", fragment: {:pointer, tokens}} = reference} ->
        normalized = normalize_pointer(tokens, root, [], 0, max_depth)
        __MODULE__.to_string(%__MODULE__{reference | fragment: {:pointer, normalized}})

      _ ->
        ref
    end
  end

  defp normalize_pointer([], _current, acc, _depth, _max_depth), do: Enum.reverse(acc)

  defp normalize_pointer(tokens, _current, acc, depth, max_depth) when depth >= max_depth,
    do: Enum.reverse(acc) ++ tokens

  defp normalize_pointer([token | rest], current, acc, depth, max_depth)
       when is_map(current) do
    cond do
      Map.has_key?(current, token) ->
        normalize_pointer(
          rest,
          Map.fetch!(current, token),
          [token | acc],
          depth + 1,
          max_depth
        )

      token == "definitions" and Map.has_key?(current, "$defs") ->
        normalize_pointer(
          rest,
          Map.fetch!(current, "$defs"),
          ["$defs" | acc],
          depth + 1,
          max_depth
        )

      true ->
        Enum.reverse(acc) ++ [token | rest]
    end
  end

  defp normalize_pointer([token | rest], current, acc, depth, max_depth)
       when is_list(current) do
    case Integer.parse(token) do
      {index, ""} when index >= 0 and index < length(current) ->
        normalize_pointer(
          rest,
          Enum.at(current, index),
          [token | acc],
          depth + 1,
          max_depth
        )

      _ ->
        Enum.reverse(acc) ++ [token | rest]
    end
  end

  defp normalize_pointer(tokens, _current, acc, _depth, _max_depth),
    do: Enum.reverse(acc) ++ tokens
end
