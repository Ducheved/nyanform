defmodule Nyanform.Schema.Reference do
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
end
