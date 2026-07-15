defmodule Nyanform.Schema.PipelineSmokeTest do
  use ExUnit.Case, async: true

  alias Nyanform.Schema.{Pipeline, Reference, Scroll, Serializer, ValidationError}

  test "compiles a simple object schema" do
    raw = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "minLength" => 1},
        "age" => %{"type" => "integer", "minimum" => 0}
      },
      "required" => ["name"],
      "additionalProperties" => false
    }

    assert {:ok, result} = Pipeline.compile(raw)
    assert %Scroll{kind: :object} = result.scroll
    assert result.digest != nil
    assert byte_size(result.digest) == 64
  end

  test "rejects malformed required values without raising" do
    schema = %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}},
      "required" => "name"
    }

    assert {:error, %ValidationError{code: :invalid_keyword_value, path: ["required"]}} =
             Pipeline.compile(schema)
  end

  test "rejects explicit null structural keywords" do
    for schema <- [
          %{"type" => "object", "properties" => nil},
          %{"type" => "object", "required" => nil},
          %{"type" => "object", "additionalProperties" => nil},
          %{"type" => "array", "items" => nil},
          %{"enum" => nil},
          %{"$defs" => nil},
          %{"definitions" => nil}
        ] do
      assert {:error, %ValidationError{code: :invalid_keyword_value}} = Pipeline.compile(schema)
    end
  end

  test "validates structural siblings independently of the selected kind" do
    for schema <- [
          %{"type" => "string", "required" => "bad"},
          %{"$ref" => "#", "properties" => %{"value" => nil}},
          %{"anyOf" => [%{"type" => "string"}], "additionalProperties" => 7},
          %{"type" => "string", "items" => [%{"type" => "integer"}, nil]}
        ] do
      assert {:error, %ValidationError{}} = Pipeline.compile(schema)
    end
  end

  test "preserves boolean false items as a rejecting child schema" do
    assert {:ok, constrained} = Pipeline.compile(%{"type" => "array", "items" => false})
    assert {:ok, unconstrained} = Pipeline.compile(%{"type" => "array"})

    assert %Scroll{kind: :array, items: %Scroll{kind: :never}} = constrained.scroll
    assert constrained.digest != unconstrained.digest
  end

  test "compiles a schema with oneOf union" do
    raw = %{
      "oneOf" => [
        %{"type" => "string"},
        %{"type" => "integer"}
      ]
    }

    assert {:ok, result} = Pipeline.compile(raw)
    assert %Scroll{kind: :union, branches: [_ | _]} = result.scroll
    assert length(result.scroll.branches) == 2
  end

  test "compiles a schema with local $defs and $ref" do
    raw = %{
      "type" => "object",
      "properties" => %{
        "child" => %{"$ref" => "#/$defs/Node"}
      },
      "$defs" => %{
        "Node" => %{
          "type" => "object",
          "properties" => %{
            "value" => %{"type" => "string"}
          }
        }
      }
    }

    assert {:ok, result} = Pipeline.compile(raw)
    assert %Scroll{kind: :object} = result.scroll
  end

  test "compiles a recursive schema" do
    raw = %{
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => "string"},
        "next" => %{"$ref" => "#/$defs/Tree"}
      },
      "$defs" => %{
        "Tree" => %{
          "type" => "object",
          "properties" => %{
            "value" => %{"type" => "string"},
            "next" => %{"$ref" => "#/$defs/Tree"}
          }
        }
      }
    }

    assert {:ok, result} = Pipeline.compile(raw)
    assert %Scroll{kind: :object} = result.scroll
    assert Reference.dangling_local_refs(result.scroll.raw) == []
  end

  test "finds dangling root and nested local reference targets" do
    raw = %{
      "type" => "object",
      "properties" => %{
        "root" => %{"$ref" => "#/$defs/Missing"},
        "payload" => %{
          "type" => "object",
          "properties" => %{
            "nested" => %{"$ref" => "#/properties/payload/$defs/Missing"}
          },
          "$defs" => %{"Present" => %{"type" => "string"}}
        }
      },
      "$defs" => %{"Present" => %{"type" => "string"}}
    }

    assert {:ok, result} = Pipeline.compile(raw)

    assert Reference.dangling_local_refs(result.scroll.raw) == [
             %{
               path: ["properties", "payload", "properties", "nested", "$ref"],
               reference: "#/properties/payload/$defs/Missing"
             },
             %{path: ["properties", "root", "$ref"], reference: "#/$defs/Missing"}
           ]
  end

  test "accepts local pointers through legacy definitions and escaped tokens" do
    raw = %{
      "type" => "object",
      "properties" => %{
        "legacy" => %{"$ref" => "#/definitions/Node"},
        "escaped" => %{"$ref" => "#/$defs/a~1b~0c"}
      },
      "definitions" => %{"Node" => %{"type" => "string"}},
      "$defs" => %{"a/b~c" => %{"type" => "integer"}}
    }

    assert {:ok, result} = Pipeline.compile(raw)
    assert Reference.dangling_local_refs(result.scroll.raw) == []
  end

  test "does not resolve external or anchor references as local pointers" do
    raw = %{
      "anyOf" => [
        %{"$ref" => "https://example.com/schema.json#/$defs/Missing"},
        %{"$ref" => "#Node"}
      ]
    }

    assert {:ok, result} = Pipeline.compile(raw)
    assert Reference.dangling_local_refs(result.scroll.raw) == []
  end

  test "compiles a tuple-style array" do
    raw = %{
      "type" => "array",
      "items" => [%{"type" => "string"}, %{"type" => "integer"}]
    }

    assert {:ok, result} = Pipeline.compile(raw)
    assert %Scroll{kind: :array, tuple_items: [_, _]} = result.scroll
  end

  test "compiles an enum" do
    raw = %{"enum" => ["red", "green", "blue"]}
    assert {:ok, result} = Pipeline.compile(raw)
    assert %Scroll{kind: :enum, enum: ["red", "green", "blue"]} = result.scroll
  end

  test "compiles a const" do
    raw = %{"const" => 42}
    assert {:ok, result} = Pipeline.compile(raw)
    assert %Scroll{kind: :const, const: 42} = result.scroll
  end

  test "rejects a malformed enum" do
    raw = %{"enum" => "not-a-list"}
    assert {:error, _} = Pipeline.compile(raw)
  end

  test "compilation is idempotent" do
    raw = %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
      }
    }

    assert {:ok, first} = Pipeline.compile(raw)
    serialized = Serializer.serialize(first.scroll)
    reparsed_scroll = first.scroll
    second_digest = Serializer.digest(reparsed_scroll)
    assert first.digest == second_digest
    assert is_binary(serialized)
  end

  test "digest is deterministic across runs" do
    raw = %{"type" => "string", "minLength" => 3, "maxLength" => 100}

    assert {:ok, first} = Pipeline.compile(raw)
    assert {:ok, second} = Pipeline.compile(raw)
    assert first.digest == second.digest
  end

  test "digest ignores required ordering" do
    left = %{
      "type" => "object",
      "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "string"}},
      "required" => ["a", "b"]
    }

    right = Map.put(left, "required", ["b", "a"])

    assert {:ok, left_result} = Pipeline.compile(left)
    assert {:ok, right_result} = Pipeline.compile(right)
    assert left_result.digest == right_result.digest
  end

  test "digest ignores nested descriptive metadata" do
    left = %{
      "type" => "object",
      "properties" => %{"value" => %{"type" => "string", "description" => "left"}}
    }

    right = put_in(left, ["properties", "value", "description"], "right")

    assert {:ok, left_result} = Pipeline.compile(left)
    assert {:ok, right_result} = Pipeline.compile(right)
    assert left_result.digest == right_result.digest
  end

  test "handles nullable type arrays" do
    raw = %{"type" => ["string", "null"]}
    assert {:ok, result} = Pipeline.compile(raw)
    assert %Scroll{kind: :union} = result.scroll
  end

  test "handles boolean schema true" do
    assert {:ok, result} = Pipeline.compile(true)
    assert %Scroll{kind: :any} = result.scroll
  end

  test "handles boolean schema false" do
    assert {:ok, result} = Pipeline.compile(false)
    assert %Scroll{kind: :never} = result.scroll
  end

  test "handles vendor extensions as annotations" do
    raw = %{
      "type" => "string",
      "x-vendor-format" => "custom",
      "x-meta" => %{"internal" => true}
    }

    assert {:ok, result} = Pipeline.compile(raw)
    assert result.scroll.annotations != nil
    assert Map.has_key?(result.scroll.annotations, "x-vendor-format")
  end

  test "respects schema depth limit" do
    deeply_nested = build_nested(100)
    limits = %{Nyanform.Limits.default() | max_schema_depth: 10}
    assert {:error, %{code: :schema_depth_exceeded}} = Pipeline.compile(deeply_nested, limits)
  end

  defp build_nested(0), do: %{"type" => "string"}

  defp build_nested(n),
    do: %{"type" => "object", "properties" => %{"child" => build_nested(n - 1)}}
end
