defmodule Nyanform.Schema.Pipeline do
  alias Nyanform.Diagnostic.Omen
  alias Nyanform.Schema.{Canonicalizer, Parser, Reference, Scroll, Serializer}

  @type stage ::
          :parse
          | :validate
          | :canonicalize
          | :references
          | :project
          | :analyze
          | :serialize
          | :digest

  @type result :: %{
          scroll: Scroll.t() | nil,
          digest: String.t() | nil,
          omens: [Omen.t()],
          stages: [{stage(), pos_integer()}]
        }

  @spec compile(term()) :: {:ok, result()} | {:error, Nyanform.Schema.ValidationError.t()}
  def compile(raw) do
    compile(raw, Nyanform.Limits.default())
  end

  @spec compile(term(), map()) ::
          {:ok, result()} | {:error, Nyanform.Schema.ValidationError.t()}
  def compile(raw, limits) do
    started = System.monotonic_time(:microsecond)

    with {:ok, parsed} <- Parser.parse(raw, [], 0, limits.max_schema_depth),
         {:ok, canonical} <- Canonicalizer.canonicalize(parsed),
         {:ok, resolved} <- mark_recursive_refs(canonical, limits) do
      digest = Serializer.digest(resolved)
      finished = System.monotonic_time(:microsecond)

      {:ok,
       %{
         scroll: resolved,
         digest: digest,
         omens: [],
         stages: [
           {:parse, 0},
           {:canonicalize, 0},
           {:references, 0},
           {:digest, finished - started}
         ]
       }}
    end
  end

  @spec compile_idempotent(term()) ::
          {:ok, result()} | {:error, Nyanform.Schema.ValidationError.t()}
  def compile_idempotent(raw) do
    case compile(raw) do
      {:ok, first} ->
        case compile(first.scroll) do
          {:ok, second} when first.digest == second.digest ->
            {:ok, first}

          {:ok, _second} ->
            {:error,
             %Nyanform.Schema.ValidationError{code: :idempotency_violation, path: ["__root__"]}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_recursive_refs(%Scroll{} = scroll, limits) do
    definitions = scroll.definitions || %{}
    {:ok, mark_recursive(scroll, definitions, %{}, 0, limits.max_reference_depth)}
  end

  defp mark_recursive(%Scroll{kind: :ref} = scroll, defs, seen, depth, max) do
    target_name = Reference.definition_name(scroll.ref_target)

    cond do
      depth >= max ->
        %Scroll{scroll | recursive: true}

      target_name != nil and Map.has_key?(seen, target_name) ->
        %Scroll{scroll | recursive: true}

      target_name != nil and Map.has_key?(defs, target_name) ->
        resolved = Map.fetch!(defs, target_name)

        traversed =
          mark_recursive(resolved, defs, Map.put(seen, target_name, true), depth + 1, max)

        if contains_recursive_ref?(traversed) do
          %Scroll{scroll | recursive: true}
        else
          scroll
        end

      true ->
        scroll
    end
  end

  defp mark_recursive(%Scroll{} = scroll, defs, seen, depth, max) do
    %Scroll{
      scroll
      | definitions: mark_def_map(scroll.definitions, defs, seen, depth, max),
        properties: mark_map(scroll.properties, defs, seen, depth, max),
        pattern_properties: mark_map(scroll.pattern_properties, defs, seen, depth, max),
        additional_properties:
          mark_additional(scroll.additional_properties, defs, seen, depth, max),
        items: mark_optional(scroll.items, defs, seen, depth, max),
        tuple_items: mark_list(scroll.tuple_items, defs, seen, depth, max),
        additional_items: mark_additional(scroll.additional_items, defs, seen, depth, max),
        branches: mark_list(scroll.branches, defs, seen, depth, max)
    }
  end

  defp mark_def_map(nil, _defs, _seen, _depth, _max), do: nil

  defp mark_def_map(map, defs, seen, depth, max) when is_map(map) do
    Map.new(map, fn {name, child} ->
      {name, mark_recursive(child, defs, seen, depth, max)}
    end)
  end

  defp mark_map(nil, _defs, _seen, _depth, _max), do: nil

  defp mark_map(map, defs, seen, depth, max) when is_map(map) do
    Map.new(map, fn {name, child} -> {name, mark_recursive(child, defs, seen, depth, max)} end)
  end

  defp mark_list(nil, _defs, _seen, _depth, _max), do: nil

  defp mark_list(list, defs, seen, depth, max) when is_list(list) do
    Enum.map(list, &mark_recursive(&1, defs, seen, depth, max))
  end

  defp mark_optional(nil, _defs, _seen, _depth, _max), do: nil

  defp mark_optional(scroll, defs, seen, depth, max),
    do: mark_recursive(scroll, defs, seen, depth, max)

  defp mark_additional(nil, _defs, _seen, _depth, _max), do: nil
  defp mark_additional(false, _defs, _seen, _depth, _max), do: false

  defp mark_additional(scroll, defs, seen, depth, max),
    do: mark_recursive(scroll, defs, seen, depth, max)

  defp contains_recursive_ref?(%Scroll{kind: :ref, recursive: true}), do: true

  defp contains_recursive_ref?(%Scroll{} = scroll) do
    Enum.any?(recursive_children(scroll), &contains_recursive_ref?/1)
  end

  defp recursive_children(%Scroll{} = scroll) do
    map_children(scroll.properties) ++
      map_children(scroll.pattern_properties) ++
      additional_children(scroll.additional_properties) ++
      additional_children(scroll.items) ++
      list_children(scroll.tuple_items) ++
      additional_children(scroll.additional_items) ++
      list_children(scroll.branches)
  end

  defp map_children(map) when is_map(map), do: Map.values(map)
  defp map_children(_map), do: []

  defp additional_children(%Scroll{} = child), do: [child]
  defp additional_children(_child), do: []

  defp list_children(children) when is_list(children), do: children
  defp list_children(_children), do: []
end
