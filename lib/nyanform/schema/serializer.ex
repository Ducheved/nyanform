defmodule Nyanform.Schema.Serializer do
  alias Nyanform.Schema.Scroll

  @spec serialize(Scroll.t()) :: String.t()
  def serialize(%Scroll{} = scroll) do
    scroll
    |> to_canonical_term()
    |> :erlang.term_to_binary()
    |> then(&Base.encode16(&1, case: :lower))
  end

  @spec digest(Scroll.t()) :: String.t()
  def digest(%Scroll{} = scroll) do
    serialized = serialize(scroll)
    :crypto.hash(:sha256, serialized) |> Base.encode16(case: :lower)
  end

  @spec to_canonical_term(Scroll.t()) :: term()
  def to_canonical_term(%Scroll{} = scroll) do
    scroll
    |> strip_non_semantic()
    |> canonical_map()
  end

  defp strip_non_semantic(%Scroll{} = scroll) do
    %Scroll{
      scroll
      | description: nil,
        title: nil,
        default: :unset,
        examples: nil,
        raw: nil,
        path: []
    }
  end

  defp canonical_map(%Scroll{} = scroll) do
    base = [
      {:kind, scroll.kind}
    ]

    base
    |> maybe_put(:description, scroll.description)
    |> maybe_put(:title, scroll.title)
    |> maybe_put(:default, scroll.default, :unset)
    |> maybe_put(:examples, scroll.examples)
    |> maybe_put(:annotations, scroll.annotations)
    |> maybe_put(:required, scroll.required)
    |> maybe_put(:min_properties, scroll.min_properties)
    |> maybe_put(:max_properties, scroll.max_properties)
    |> maybe_put(:format, scroll.format)
    |> maybe_put(:pattern, scroll.pattern)
    |> maybe_put(:min_length, scroll.min_length)
    |> maybe_put(:max_length, scroll.max_length)
    |> maybe_put(:enum, scroll.enum)
    |> maybe_put(:const, scroll.const, :unset)
    |> maybe_put(:minimum, scroll.minimum)
    |> maybe_put(:maximum, scroll.maximum)
    |> maybe_put(:exclusive_minimum, scroll.exclusive_minimum)
    |> maybe_put(:exclusive_maximum, scroll.exclusive_maximum)
    |> maybe_put(:multiple_of, scroll.multiple_of)
    |> maybe_put(:min_items, scroll.min_items)
    |> maybe_put(:max_items, scroll.max_items)
    |> maybe_put(:unique_items, scroll.unique_items)
    |> maybe_put(:ref_target, scroll.ref_target)
    |> maybe_put(:recursive, scroll.recursive)
    |> put_nested(:properties, scroll.properties)
    |> put_nested(:pattern_properties, scroll.pattern_properties)
    |> put_additional(:additional_properties, scroll.additional_properties)
    |> put_nested(:items, scroll.items)
    |> put_nested_list(:tuple_items, scroll.tuple_items)
    |> put_additional(:additional_items, scroll.additional_items)
    |> put_nested_list(:branches, scroll.branches)
    |> put_nested(:definitions, scroll.definitions)
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, _key, :unset), do: list
  defp maybe_put(list, _key, false), do: list
  defp maybe_put(list, key, value), do: list ++ [{key, value}]
  defp maybe_put(list, _key, value, sentinel) when value == sentinel, do: list
  defp maybe_put(list, key, value, _sentinel), do: list ++ [{key, value}]

  defp put_nested(list, _key, nil), do: list

  defp put_nested(list, key, %Scroll{} = scroll) do
    list ++ [{key, canonical_map(scroll)}]
  end

  defp put_nested(list, key, map) when is_map(map) do
    sorted =
      map
      |> Enum.map(fn {name, child} -> {name, canonical_map(child)} end)
      |> Enum.sort_by(fn {name, _} -> name end)

    list ++ [{key, sorted}]
  end

  defp put_nested(list, _key, _), do: list

  defp put_nested_list(list, _key, nil), do: list

  defp put_nested_list(list, key, list_value) when is_list(list_value) do
    list ++ [{key, Enum.map(list_value, &canonical_map/1)}]
  end

  defp put_additional(list, _key, nil), do: list
  defp put_additional(list, key, false), do: list ++ [{key, false}]
  defp put_additional(list, key, %Scroll{} = scroll), do: list ++ [{key, canonical_map(scroll)}]
  defp put_additional(list, _key, _), do: list
end
