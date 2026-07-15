defmodule Nyanform.RewriteTalisman do
  alias Nyanform.Diagnostic.Omen
  alias Nyanform.Schema.Scroll

  @type repair_result :: %{
          arguments: map(),
          omens: [Omen.t()],
          original_preserved: map()
        }

  @spec repair(map(), Scroll.t() | nil) :: repair_result()
  def repair(arguments, schema) when is_map(arguments) do
    repair(arguments, schema, [])
  end

  def repair(arguments, _schema) when not is_map(arguments) do
    %{arguments: arguments, omens: [], original_preserved: arguments}
  end

  @spec repair(map(), Scroll.t() | nil, keyword()) :: repair_result()
  def repair(arguments, schema, opts) when is_map(arguments) and is_list(opts) do
    drop_optional_nulls = Keyword.get(opts, :drop_optional_nulls, false)
    {repaired, omens} = repair_object(arguments, schema, [], drop_optional_nulls)
    %{arguments: repaired, omens: omens, original_preserved: arguments}
  end

  defp repair_object(
         obj,
         %Scroll{kind: :object, properties: props, required: required},
         path,
         drop_optional_nulls
       )
       when is_map(obj) do
    case props do
      nil ->
        {obj, []}

      prop_map when is_map(prop_map) ->
        Enum.reduce(obj, {obj, []}, fn {key, value}, {acc, acc_omens} ->
          case Map.fetch(prop_map, key) do
            {:ok, prop_schema} ->
              repair_property(
                key,
                value,
                prop_schema,
                required,
                acc,
                acc_omens,
                path,
                drop_optional_nulls
              )

            :error ->
              {acc, acc_omens}
          end
        end)
    end
  end

  defp repair_object(obj, _schema, _path, _drop_optional_nulls), do: {obj, []}

  defp repair_property(key, nil, schema, required, acc, acc_omens, path, true) do
    if optional_non_nullable?(key, schema, required) do
      omen =
        Omen.normalized("NYA-ARG-004",
          schema_path: path ++ [key],
          rule: "synthetic_optional_null_removed",
          source: "null",
          target: "property omitted",
          explanation: "synthetic null removed for an originally optional property"
        )

      {Map.delete(acc, key), acc_omens ++ [omen]}
    else
      {acc, acc_omens}
    end
  end

  defp repair_property(
         key,
         value,
         schema,
         _required,
         acc,
         acc_omens,
         path,
         drop_optional_nulls
       ) do
    {repaired_value, value_omens} =
      repair_value(value, schema, path ++ [key], drop_optional_nulls)

    {Map.put(acc, key, repaired_value), acc_omens ++ value_omens}
  end

  defp optional_non_nullable?(key, schema, required) do
    key not in (required || []) and not accepts_null?(schema)
  end

  defp accepts_null?(%Scroll{kind: kind}) when kind in [:any, :null], do: true

  defp accepts_null?(%Scroll{branches: branches}) when is_list(branches) do
    Enum.any?(branches, &accepts_null?/1)
  end

  defp accepts_null?(%Scroll{enum: enum}) when is_list(enum), do: nil in enum
  defp accepts_null?(%Scroll{const: nil}), do: true
  defp accepts_null?(_schema), do: false

  defp repair_value(value, %Scroll{kind: :object} = schema, path, drop_optional_nulls)
       when is_binary(value) do
    case try_parse_json(value) do
      {:ok, parsed} when is_map(parsed) ->
        {repaired, omens} = repair_object(parsed, schema, path, drop_optional_nulls)

        omen =
          Omen.normalized("NYA-ARG-001",
            schema_path: path,
            rule: "string_repaired_to_object",
            source: "JSON string",
            target: "object",
            explanation: "string argument parsed as JSON object at object-typed path"
          )

        {repaired, [omen | omens]}

      _ ->
        {value, []}
    end
  end

  defp repair_value(
         value,
         %Scroll{kind: :array, items: %Scroll{} = items_schema},
         path,
         drop_optional_nulls
       )
       when is_binary(value) do
    case try_parse_json(value) do
      {:ok, parsed} when is_list(parsed) ->
        {repaired_items, omens} =
          Enum.reduce(parsed, {[], []}, fn item, {acc, acc_omens} ->
            {repaired, item_omens} =
              repair_value(item, items_schema, path ++ ["items"], drop_optional_nulls)

            {acc ++ [repaired], acc_omens ++ item_omens}
          end)

        omen =
          Omen.normalized("NYA-ARG-002",
            schema_path: path,
            rule: "string_repaired_to_array",
            source: "JSON string",
            target: "array",
            explanation: "string argument parsed as JSON array at array-typed path"
          )

        {repaired_items, [omen | omens]}

      _ ->
        {value, []}
    end
  end

  defp repair_value(
         value,
         %Scroll{kind: :object, properties: props} = schema,
         path,
         drop_optional_nulls
       )
       when is_map(value) do
    repair_object(value, schema, path ++ props_property_hint(props), drop_optional_nulls)
  end

  defp repair_value(
         value,
         %Scroll{kind: :array, items: %Scroll{} = items_schema},
         path,
         drop_optional_nulls
       )
       when is_list(value) do
    {repaired_items, omens} =
      Enum.reduce(value, {[], []}, fn item, {acc, acc_omens} ->
        {repaired, item_omens} =
          repair_value(item, items_schema, path ++ ["items"], drop_optional_nulls)

        {acc ++ [repaired], acc_omens ++ item_omens}
      end)

    {repaired_items, omens}
  end

  defp repair_value(value, _schema, _path, _drop_optional_nulls) do
    {value, []}
  end

  defp props_property_hint(nil), do: []
  defp props_property_hint(_), do: ["properties"]

  defp try_parse_json(string) when is_binary(string) do
    trimmed = String.trim(string)

    if String.length(trimmed) > 0 and String.first(trimmed) in ["{", "["] do
      Jason.decode(trimmed)
    else
      {:error, :not_json}
    end
  end

  @spec redact_secrets(map(), [String.t()]) :: map()
  def redact_secrets(arguments, secret_keys \\ default_secret_keys()) when is_map(arguments) do
    redact_map(arguments, secret_keys)
  end

  defp redact_map(map, secret_keys) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if secret_key?(key, secret_keys) do
        {key, "[REDACTED]"}
      else
        {key, redact_value(value, secret_keys)}
      end
    end)
  end

  defp redact_list(list, secret_keys) when is_list(list) do
    Enum.map(list, &redact_value(&1, secret_keys))
  end

  defp redact_value(map, secret_keys) when is_map(map), do: redact_map(map, secret_keys)
  defp redact_value(list, secret_keys) when is_list(list), do: redact_list(list, secret_keys)
  defp redact_value(value, _secret_keys), do: value

  defp secret_key?(key, secret_keys) when is_binary(key) do
    lower = String.downcase(key)
    Enum.any?(secret_keys, &String.contains?(lower, &1))
  end

  defp secret_key?(key, secret_keys) when is_atom(key) do
    secret_key?(Atom.to_string(key), secret_keys)
  end

  defp secret_key?(_, _), do: false

  defp default_secret_keys do
    ~w(password secret token api_key apikey access_key private_key credential auth cookie session)
  end
end
