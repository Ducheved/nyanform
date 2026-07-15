defmodule Nyanform.Schema.ReferenceTest do
  use ExUnit.Case, async: true

  alias Nyanform.Limits
  alias Nyanform.Schema.Reference

  test "normalization stops descending at the explicit depth bound" do
    schema = %{
      "$defs" => %{"Node" => %{"type" => "string"}},
      "properties" => %{
        "first" => %{
          "$ref" => "#/definitions/Node",
          "properties" => %{
            "second" => %{"$ref" => "#/definitions/Node"}
          }
        }
      }
    }

    normalized = Reference.normalize_definition_refs(schema, 1)

    assert get_in(normalized, ["properties", "first", "$ref"]) == "#/$defs/Node"

    assert get_in(normalized, ["properties", "first", "properties", "second", "$ref"]) ==
             "#/definitions/Node"
  end

  test "dangling reference collection stops descending at the explicit depth bound" do
    schema = %{
      "properties" => %{
        "first" => %{
          "$ref" => "#/$defs/MissingFirst",
          "properties" => %{
            "second" => %{"$ref" => "#/$defs/MissingSecond"}
          }
        }
      }
    }

    assert Reference.dangling_local_refs(schema, 1) == [
             %{
               path: ["properties", "first", "$ref"],
               reference: "#/$defs/MissingFirst"
             }
           ]
  end

  test "default traversal uses the configured schema depth bound" do
    limit = Limits.default().max_schema_depth
    schema = nested_dangling_schema(limit + 2)
    references = Reference.dangling_local_refs(schema)

    assert length(references) == limit + 1
    assert Enum.any?(references, &(&1.reference == "#/$defs/Missing2"))
    refute Enum.any?(references, &(&1.reference == "#/$defs/Missing1"))
  end

  test "escaped legacy definition pointers remain normalized and resolvable" do
    schema = %{
      "$defs" => %{"a/b~c" => %{"type" => "string"}},
      "properties" => %{
        "value" => %{"$ref" => "#/definitions/a~1b~0c"}
      }
    }

    normalized = Reference.normalize_definition_refs(schema)

    assert get_in(normalized, ["properties", "value", "$ref"]) == "#/$defs/a~1b~0c"
    assert Reference.dangling_local_refs(normalized) == []
  end

  defp nested_dangling_schema(0), do: %{"$ref" => "#/$defs/Missing0"}

  defp nested_dangling_schema(depth) do
    %{
      "$ref" => "#/$defs/Missing#{depth}",
      "properties" => %{"next" => nested_dangling_schema(depth - 1)}
    }
  end
end
