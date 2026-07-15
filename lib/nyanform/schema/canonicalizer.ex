defmodule Nyanform.Schema.Canonicalizer do
  alias Nyanform.Schema.Scroll
  alias Nyanform.Schema.ValidationError

  @spec canonicalize(Scroll.t()) :: {:ok, Scroll.t()} | {:error, ValidationError.t()}
  def canonicalize(scroll) do
    canonicalize(scroll, [], %{})
  end

  defp canonicalize(%Scroll{} = scroll, path, seen) do
    key = {scroll.kind, scroll.path}

    if Map.has_key?(seen, key) do
      {:ok, %Scroll{scroll | recursive: true}}
    else
      seen = Map.put(seen, key, true)

      with {:ok, canonical} <- canonicalize_kind(scroll, path, seen),
           {:ok, definitions} <-
             canonicalize_map(canonical.definitions, path, "$defs", seen) do
        {:ok, %Scroll{canonical | definitions: definitions}}
      end
    end
  end

  defp canonicalize_kind(%Scroll{kind: :object} = scroll, path, seen) do
    with {:ok, properties} <- canonicalize_map(scroll.properties, path, "properties", seen),
         {:ok, pattern_properties} <-
           canonicalize_map(scroll.pattern_properties, path, "patternProperties", seen),
         {:ok, additional} <-
           canonicalize_additional(
             scroll.additional_properties,
             path,
             "additionalProperties",
             seen
           ) do
      required = normalize_required(scroll.required, properties)

      {:ok,
       %Scroll{
         scroll
         | properties: properties,
           pattern_properties: pattern_properties,
           additional_properties: additional,
           required: required
       }}
    end
  end

  defp canonicalize_kind(%Scroll{kind: :array} = scroll, path, seen) do
    cond do
      scroll.tuple_items != nil ->
        with {:ok, tuple_items} <- canonicalize_list(scroll.tuple_items, path, "items", seen),
             {:ok, additional_items} <-
               canonicalize_additional(scroll.additional_items, path, "additionalItems", seen) do
          {:ok, %Scroll{scroll | tuple_items: tuple_items, additional_items: additional_items}}
        end

      scroll.items != nil ->
        case canonicalize(scroll.items, path, seen) do
          {:ok, items} -> {:ok, %Scroll{scroll | items: items}}
          error -> error
        end

      true ->
        {:ok, scroll}
    end
  end

  defp canonicalize_kind(%Scroll{kind: k} = scroll, path, seen)
       when k in [:union, :intersection] do
    case canonicalize_list(scroll.branches, path, "branches", seen) do
      {:ok, branches} -> {:ok, %Scroll{scroll | branches: branches}}
      error -> error
    end
  end

  defp canonicalize_kind(%Scroll{kind: :enum} = scroll, _path, _seen) do
    {:ok, scroll}
  end

  defp canonicalize_kind(%Scroll{kind: :string, format: format} = scroll, _path, _seen)
       when format != nil do
    if format_atom(format) == :unsupported do
      {:ok, %Scroll{scroll | format: nil}}
    else
      {:ok, scroll}
    end
  end

  defp canonicalize_kind(%Scroll{kind: :string} = scroll, _path, _seen) do
    {:ok, scroll}
  end

  defp canonicalize_kind(%Scroll{kind: :integer} = scroll, _path, _seen) do
    {:ok, scroll}
  end

  defp canonicalize_kind(%Scroll{kind: :number} = scroll, _path, _seen) do
    {:ok, scroll}
  end

  defp canonicalize_kind(%Scroll{kind: :const} = scroll, _path, _seen) do
    {:ok, scroll}
  end

  defp canonicalize_kind(%Scroll{} = scroll, _path, _seen) do
    {:ok, scroll}
  end

  defp canonicalize_map(nil, _path, _key, _seen), do: {:ok, nil}

  defp canonicalize_map(map, path, key, seen) when is_map(map) do
    result =
      Enum.reduce_while(map, {:ok, %{}}, fn {name, child}, {:ok, acc} ->
        case canonicalize(child, path ++ [key, name], seen) do
          {:ok, canon} -> {:cont, {:ok, Map.put(acc, name, canon)}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, finalized} -> {:ok, maybe_nilify(finalized)}
      error -> error
    end
  end

  defp canonicalize_list(nil, _path, _key, _seen), do: {:ok, nil}

  defp canonicalize_list(list, path, key, seen) when is_list(list) do
    result =
      Enum.reduce_while(list, {:ok, []}, fn child, {:ok, acc} ->
        case canonicalize(child, path ++ [key], seen) do
          {:ok, canon} -> {:cont, {:ok, acc ++ [canon]}}
          error -> {:halt, error}
        end
      end)

    result
  end

  defp canonicalize_additional(nil, _path, _key, _seen), do: {:ok, nil}
  defp canonicalize_additional(false, _path, _key, _seen), do: {:ok, false}

  defp canonicalize_additional(schema, path, key, seen) do
    canonicalize(schema, path ++ [key], seen)
  end

  defp normalize_required(nil, _properties), do: nil

  defp normalize_required(required, _properties) when is_list(required) do
    required |> Enum.uniq() |> Enum.sort()
  end

  defp maybe_nilify(map) when map_size(map) == 0, do: nil
  defp maybe_nilify(map), do: map

  defp format_atom("date-time"), do: :date_time
  defp format_atom("date"), do: :date
  defp format_atom("time"), do: :time
  defp format_atom("duration"), do: :duration
  defp format_atom("email"), do: :email
  defp format_atom("idn-email"), do: :email
  defp format_atom("hostname"), do: :hostname
  defp format_atom("idn-hostname"), do: :hostname
  defp format_atom("ipv4"), do: :ipv4
  defp format_atom("ipv6"), do: :ipv6
  defp format_atom("uri"), do: :uri
  defp format_atom("uri-reference"), do: :uri
  defp format_atom("iri"), do: :iri
  defp format_atom("uuid"), do: :uuid
  defp format_atom(_), do: :unsupported
end
