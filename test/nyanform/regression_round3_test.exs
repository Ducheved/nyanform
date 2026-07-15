defmodule Nyanform.RegressionRound3Test do
  use ExUnit.Case, async: true

  alias Nyanform.Profile.{Builtins, Projector}
  alias Nyanform.Schema.{Pipeline, Reference, Serializer}

  defp project(raw, profile_name \\ "canonical", policy \\ :strict) do
    {:ok, result} = Pipeline.compile(raw)
    {:ok, profile} = Builtins.fetch(profile_name)
    Projector.project(result.scroll, profile, policy)
  end

  describe "typed const and enum profile rules" do
    test "object, array, and null constraints are preserved" do
      object_enum = [%{"kind" => "fixed"}]
      object = project(%{"type" => "object", "enum" => object_enum})
      array = project(%{"type" => "array", "items" => %{"type" => "integer"}, "const" => [1]})
      null = project(%{"type" => "null", "const" => nil})

      assert object.schema == %{"type" => "object", "enum" => object_enum}

      assert array.schema == %{
               "type" => "array",
               "items" => %{"type" => "integer"},
               "const" => [1]
             }

      assert null.schema == %{"type" => "null", "const" => nil}
    end

    test "typed mixed and empty enums obey profile compatibility" do
      mixed = project(%{"type" => "string", "enum" => ["a", 1]}, "gemini")
      empty = project(%{"type" => "string", "enum" => []}, "gemini")

      refute mixed.accepted
      assert Enum.any?(mixed.omens, &(&1.rule == "mixed_enum_unsupported"))
      refute empty.accepted
      assert empty.schema == %{"type" => "string", "enum" => []}
      assert Enum.any?(empty.omens, &(&1.rule == "empty_enum_unsupported"))
    end

    test "nested typed const reports its exact schema path" do
      raw = %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string", "const" => "fixed"}}
      }

      result = project(raw, "gemini")

      refute result.accepted
      assert result.schema["properties"]["value"] == %{"type" => "string", "enum" => ["fixed"]}

      assert Enum.any?(
               result.omens,
               &(&1.rule == "const_unsupported" and
                   &1.schema_path == ["properties", "value"] and &1.severity == :rejected)
             )
    end

    test "enum and const retain intersection semantics" do
      contradictory = %{"type" => "string", "enum" => ["b"], "const" => "a"}
      canonical = project(contradictory)
      gemini = project(contradictory, "gemini")

      matching =
        project(
          %{"type" => "string", "enum" => ["a", "b"], "const" => "a"},
          "gemini",
          :compatible
        )

      assert canonical.schema == contradictory
      refute gemini.accepted
      assert gemini.schema == %{"type" => "string", "enum" => []}
      assert Enum.any?(gemini.omens, &(&1.rule == "enum_const_empty_intersection"))
      assert matching.accepted
      assert matching.schema == %{"type" => "string", "enum" => ["a"]}
    end
  end

  describe "compile_idempotent" do
    test "recompiles the canonical Scroll through the complete pipeline" do
      raw = %{
        "type" => "object",
        "properties" => %{"node" => %{"$ref" => "#/$defs/Node"}},
        "$defs" => %{
          "Node" => %{
            "type" => "object",
            "required" => ["value", "value"],
            "properties" => %{"value" => %{"type" => "string"}}
          }
        }
      }

      assert {:ok, first} = Pipeline.compile(raw)
      assert {:ok, second} = Pipeline.compile(first.scroll)
      assert first.scroll == second.scroll
      assert first.digest == second.digest
      assert Serializer.digest(second.scroll) == second.digest
      assert {:ok, idempotent} = Pipeline.compile_idempotent(raw)
      assert idempotent.digest == first.digest
    end

    test "invalid schema returns an error" do
      assert {:error, _error} = Pipeline.compile_idempotent(42)
    end
  end

  describe "structured references" do
    test "preserves local pointers, relative URIs, URNs, and anchors exactly" do
      references = [
        "#/httpNode",
        "#/urn:local",
        "other.json#/Foo",
        "https://example.com/schema.json#/Foo",
        "#anchor",
        "https://example.com/schema.json#anchor",
        "urn:example:schema#/Foo",
        "urn:example:schema#anchor",
        "#",
        ""
      ]

      for reference <- references do
        result = project(%{"$ref" => reference})
        assert result.schema == %{"$ref" => reference}
      end
    end

    test "distinguishes JSON pointers from anchors and decodes pointer tokens" do
      {:ok, pointer_result} = Pipeline.compile(%{"$ref" => "other.json#/a~1b~0c"})
      {:ok, anchor_result} = Pipeline.compile(%{"$ref" => "other.json#a/b"})

      assert %Reference{uri: "other.json", fragment: {:pointer, ["a/b~c"]}} =
               pointer_result.scroll.ref_target

      assert %Reference{uri: "other.json", fragment: {:anchor, "a/b"}} =
               anchor_result.scroll.ref_target

      assert project(%{"$ref" => "other.json#/a~1b~0c"}).schema == %{
               "$ref" => "other.json#/a~1b~0c"
             }
    end

    test "local-only profiles accept local pointers but reject external references" do
      local = project(%{"$ref" => "#/urn:local"}, "gemini")
      external = project(%{"$ref" => "other.json#/Foo"}, "gemini")

      assert local.accepted
      assert local.schema == %{"$ref" => "#/urn:local"}
      refute external.accepted
      assert Enum.any?(external.omens, &(&1.rule == "reference_unsupported"))
    end
  end

  describe "recursive references" do
    test "marks refs whose resolved objects contain a recursive ref" do
      raw = %{
        "type" => "object",
        "properties" => %{"tree" => %{"$ref" => "#/$defs/Tree"}},
        "$defs" => %{
          "Tree" => %{
            "type" => "object",
            "properties" => %{"next" => %{"$ref" => "#/$defs/Tree"}}
          }
        }
      }

      assert {:ok, result} = Pipeline.compile(raw)
      assert result.scroll.properties["tree"].recursive
      assert result.scroll.definitions["Tree"].properties["next"].recursive
    end
  end

  describe "$defs canonicalization" do
    test "canonicalizes required and formats inside definitions" do
      raw = %{
        "$ref" => "#/$defs/Node",
        "$defs" => %{
          "Node" => %{
            "type" => "object",
            "required" => ["value", "value"],
            "properties" => %{"value" => %{"type" => "string", "format" => "madeup"}}
          }
        }
      }

      assert {:ok, result} = Pipeline.compile(raw)
      node = result.scroll.definitions["Node"]
      assert node.required == ["value"]
      assert node.properties["value"].format == nil

      projection = project(raw)
      assert projection.schema["$defs"]["Node"]["required"] == ["value"]
      refute Map.has_key?(projection.schema["$defs"]["Node"]["properties"]["value"], "format")
    end
  end

  describe "tuple additionalItems" do
    test "canonical projection preserves false and schema values" do
      closed =
        project(%{
          "type" => "array",
          "items" => [%{"type" => "string"}],
          "additionalItems" => false
        })

      typed =
        project(%{
          "type" => "array",
          "items" => [%{"type" => "string"}],
          "additionalItems" => %{"type" => "integer"}
        })

      assert closed.schema == %{
               "type" => "array",
               "items" => [%{"type" => "string"}],
               "additionalItems" => false
             }

      assert typed.schema["additionalItems"] == %{"type" => "integer"}
    end

    test "unsupported additionalItems is explicit" do
      result =
        project(
          %{
            "type" => "array",
            "items" => [%{"type" => "string"}],
            "additionalItems" => false
          },
          "claude"
        )

      refute result.accepted
      refute Map.has_key?(result.schema, "additionalItems")

      assert Enum.any?(
               result.omens,
               &(&1.rule == "additional_items_unsupported" and
                   &1.schema_path == ["additionalItems"] and &1.severity == :rejected)
             )
    end
  end

  describe "combinator identity and siblings" do
    test "anyOf remains anyOf and keeps numeric siblings" do
      raw = %{
        "anyOf" => [%{"type" => "integer"}, %{"type" => "number"}],
        "minimum" => 5
      }

      result = project(raw)

      assert result.schema == %{
               "anyOf" => [%{"type" => "integer"}, %{"type" => "number"}],
               "minimum" => 5
             }

      refute Map.has_key?(result.schema, "oneOf")
    end
  end

  describe "schema-valued additionalProperties" do
    test "projects the child schema exactly" do
      raw = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "additionalProperties" => %{"type" => "integer"}
      }

      result = project(raw)
      assert result.schema["additionalProperties"] == %{"type" => "integer"}
    end
  end

  describe "message parsing shape validation" do
    alias Nyanform.Protocol.Message

    test "rejects scalar error value gracefully" do
      json = ~s({"jsonrpc":"2.0","id":1,"error":"boom"})
      result = Message.parse(json, 1_048_576)
      assert match?({:error, {:parse_error, _}}, result)
    end

    test "rejects non-string method" do
      json = ~s({"jsonrpc":"2.0","id":1,"method":123})
      assert {:error, {:parse_error, _message}} = Message.parse(json, 1_048_576)
    end

    test "accepts params as array" do
      json = ~s({"jsonrpc":"2.0","id":1,"method":"test","params":[]})
      assert {:ok, msg} = Message.parse(json, 1_048_576)
      assert msg.params == []
    end
  end
end
