defmodule Nyanform.Profile.Loader do
  alias Nyanform.Profile.{Builtins, Constellation}

  @spec load(String.t()) :: {:ok, Constellation.t()} | {:error, term()}
  def load(name) when is_binary(name) do
    case Builtins.fetch(name) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, {:unknown_profile, name}}
    end
  end

  @spec load(String.t(), map() | nil) :: {:ok, Constellation.t()} | {:error, term()}
  def load(name, overrides) when is_binary(name) and is_map(overrides) do
    with {:ok, base} <- load(name) do
      apply_overrides(base, overrides)
    end
  end

  def load(name, nil) when is_binary(name) do
    load(name)
  end

  @spec validate(Constellation.t()) :: :ok | {:error, [String.t()]}
  def validate(%Constellation{} = profile) do
    errors =
      []
      |> validate_name(profile)
      |> validate_nullable(profile)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  defp apply_overrides(%Constellation{} = base, overrides) do
    fields = [
      :label,
      :description,
      :requires_all_properties_required,
      :requires_additional_properties_false,
      :requires_root_object,
      :accepts_additional_properties,
      :supports_additional_properties_false,
      :max_schema_depth,
      :max_object_depth,
      :max_tool_name_length,
      :max_description_length,
      :supports_const,
      :supports_pattern_properties,
      :integer_vs_number_distinguished
    ]

    reduced =
      Enum.reduce(fields, base, fn field, acc ->
        case Map.fetch(overrides, Atom.to_string(field)) do
          {:ok, value} -> %{acc | field => value}
          :error -> acc
        end
      end)

    {:ok, reduced}
  end

  defp validate_name(errors, %Constellation{name: name})
       when is_binary(name) and byte_size(name) > 0 do
    errors
  end

  defp validate_name(errors, _profile) do
    ["profile name must be a non-empty string" | errors]
  end

  defp validate_nullable(errors, %Constellation{nullable_representation: form})
       when form in [:type_array, :nullable_keyword, :union_null, :unsupported] do
    errors
  end

  defp validate_nullable(errors, _profile) do
    ["nullable_representation must be a known form" | errors]
  end
end
