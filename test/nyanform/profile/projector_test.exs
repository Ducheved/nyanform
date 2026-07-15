defmodule Nyanform.Profile.ProjectorTest do
  use ExUnit.Case, async: true

  alias Nyanform.Profile.{Builtins, Projector}
  alias Nyanform.Schema.Pipeline

  defp compile(raw) do
    {:ok, %{scroll: scroll}} = Pipeline.compile(raw)
    scroll
  end

  defp project(raw, profile_name, policy \\ :strict) do
    {:ok, profile} = Builtins.fetch(profile_name)
    scroll = compile(raw)
    Projector.project(scroll, profile, policy)
  end

  describe "exact transformations" do
    test "simple object projects exactly to canonical" do
      raw = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }

      result = project(raw, "canonical")
      assert result.accepted
      assert result.worst_severity in [nil, :exact]
      assert result.schema["type"] == "object"
    end

    test "string with constraints projects exactly" do
      raw = %{"type" => "string", "minLength" => 1, "maxLength" => 100}
      result = project(raw, "claude")
      assert result.accepted
      assert result.schema["minLength"] == 1
      assert result.schema["maxLength"] == 100
    end
  end

  describe "normalized transformations" do
    test "openai_strict normalizes partial required to all required" do
      raw = %{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "integer"}},
        "required" => ["a"]
      }

      result = project(raw, "openai_strict", :compatible)
      assert result.schema["required"] == ["a", "b"]
      assert result.schema["additionalProperties"] == false
      assert result.schema["properties"]["b"]["type"] == ["integer", "null"]
      assert Enum.any?(result.omens, &(&1.severity == :normalized))
    end

    test "openai_strict keeps an optional typed enum nullable" do
      raw = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "mode" => %{"type" => "string", "enum" => ["a", "b"]}
        }
      }

      result = project(raw, "openai_strict", :strict)
      mode = result.schema["properties"]["mode"]

      assert result.accepted
      assert result.schema["required"] == ["mode"]
      assert mode["type"] == ["string", "null"]
      assert mode["enum"] == ["a", "b", nil]
    end

    test "openai_strict closes and requires nested objects" do
      raw = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "config" => %{
            "type" => "object",
            "properties" => %{"enabled" => %{"type" => "boolean"}}
          }
        }
      }

      result = project(raw, "openai_strict", :compatible)
      nested = result.schema["properties"]["config"]

      assert result.accepted
      assert result.schema["required"] == ["config"]
      assert result.schema["additionalProperties"] == false
      assert nested["required"] == ["enabled"]
      assert nested["additionalProperties"] == false
    end
  end

  describe "lossy transformations" do
    test "additionalProperties: false is preserved for gemini" do
      raw = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "additionalProperties" => false
      }

      result = project(raw, "gemini", :permissive)
      assert result.schema["additionalProperties"] == false
      refute Enum.any?(result.omens, &(&1.code == "NYA-SCHEMA-003"))
    end

    test "const is normalized to an equivalent enum for gemini" do
      raw = %{"const" => 42}
      result = project(raw, "gemini", :permissive)
      assert result.schema["enum"] == [42]
      assert Enum.any?(result.omens, &(&1.severity == :normalized))
    end

    test "format dropped is reported as lossy when unsupported" do
      raw = %{"type" => "string", "format" => "date-time"}
      {:ok, profile} = Builtins.fetch("canonical")
      profile = %{profile | accepted_keywords: MapSet.delete(profile.accepted_keywords, "format")}
      result = Projector.project(compile(raw), profile, :permissive)

      refute Map.has_key?(result.schema, "format")
      assert Enum.any?(result.omens, &(&1.code == "NYA-PROFILE-003"))
    end

    test "openai_strict accepts only its documented string formats" do
      raw = %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "format" => "uuid"},
          "link" => %{"type" => "string", "format" => "uri"}
        }
      }

      result = project(raw, "openai_strict", :strict)

      assert result.schema["properties"]["id"]["format"] == "uuid"
      refute Map.has_key?(result.schema["properties"]["link"], "format")
      refute result.accepted
      assert Enum.any?(result.omens, &(&1.code == "NYA-PROFILE-003"))
    end

    test "openai_strict rejects implicit open objects under strict policy" do
      raw = %{"type" => "object", "properties" => %{"value" => %{"type" => "string"}}}
      result = project(raw, "openai_strict", :strict)

      refute result.accepted
      assert Enum.any?(result.omens, &(&1.code == "NYA-PROFILE-011"))
      assert Enum.any?(result.omens, &(&1.severity == :lossy))
    end
  end

  describe "strict policy rejection" do
    test "const normalization is accepted in strict mode for gemini" do
      raw = %{"const" => 42}
      result = project(raw, "gemini", :strict)
      assert result.accepted
      assert result.schema["enum"] == [42]
    end

    test "tuple array rejected for openai_strict" do
      raw = %{"type" => "array", "items" => [%{"type" => "string"}, %{"type" => "integer"}]}
      result = project(raw, "openai_strict", :strict)
      refute result.accepted
      assert Enum.any?(result.omens, &(&1.severity == :rejected))
    end

    test "root anyOf rejected for openai_strict" do
      raw = %{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}]}
      result = project(raw, "openai_strict", :strict)
      refute result.accepted
      assert Enum.any?(result.omens, &(&1.code == "NYA-PROFILE-008"))
    end

    test "allOf rejected for openai_strict" do
      raw = %{
        "type" => "object",
        "allOf" => [
          %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}},
          %{"type" => "object", "properties" => %{"b" => %{"type" => "integer"}}}
        ]
      }

      result = project(raw, "openai_strict", :strict)
      refute result.accepted
      assert Enum.any?(result.omens, &(&1.code == "NYA-PROFILE-010"))
    end

    test "unsupported string length constraints are not emitted for openai_strict" do
      raw = %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "string", "minLength" => 2}}
      }

      strict = project(raw, "openai_strict", :strict)
      compatible = project(raw, "openai_strict", :compatible)

      refute strict.accepted
      assert compatible.accepted
      refute Map.has_key?(compatible.schema["properties"]["value"], "minLength")
      assert Enum.any?(compatible.omens, &(&1.code == "NYA-PROFILE-012"))
    end
  end

  describe "compatible policy acceptance" do
    test "const accepted in compatible mode as enum" do
      raw = %{"const" => 42}
      result = project(raw, "gemini", :compatible)
      assert result.accepted
      assert result.schema["enum"] == [42]
    end

    test "nullable union accepted in compatible mode" do
      raw = %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => ["string", "null"]}}
      }

      result = project(raw, "openai_strict", :compatible)
      assert result.accepted
      assert result.schema["properties"]["value"]["type"] == ["string", "null"]
    end

    test "nested anyOf and local references are accepted for openai_strict" do
      raw = %{
        "type" => "object",
        "properties" => %{
          "choice" => %{
            "anyOf" => [
              %{"type" => "string"},
              %{"$ref" => "#/$defs/Choice"}
            ]
          }
        },
        "$defs" => %{
          "Choice" => %{
            "type" => "object",
            "properties" => %{"value" => %{"type" => "integer"}}
          }
        }
      }

      result = project(raw, "openai_strict", :compatible)

      assert result.accepted
      assert is_list(result.schema["properties"]["choice"]["anyOf"])

      assert Enum.any?(
               result.schema["properties"]["choice"]["anyOf"],
               &Map.has_key?(&1, "$ref")
             )

      assert result.schema["$defs"]["Choice"]["additionalProperties"] == false
    end

    test "legacy definitions and references normalize together for openai_strict" do
      raw = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "choice" => %{"$ref" => "#/definitions/Choice"}
        },
        "required" => ["choice"],
        "definitions" => %{
          "Choice" => %{"type" => "string"}
        }
      }

      result = project(raw, "openai_strict", :strict)

      assert result.accepted
      assert result.schema["properties"]["choice"]["$ref"] == "#/$defs/Choice"
      assert result.schema["$defs"]["Choice"] == %{"type" => "string"}
      refute Map.has_key?(result.schema, "definitions")
    end

    test "nested legacy definitions and recursive local references remain valid" do
      node_ref = "#/properties/payload/definitions/Node"

      raw = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "payload" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{"root" => %{"$ref" => node_ref}},
            "required" => ["root"],
            "definitions" => %{
              "Node" => %{
                "type" => "object",
                "additionalProperties" => false,
                "properties" => %{
                  "next" => %{
                    "anyOf" => [%{"$ref" => node_ref}, %{"type" => "null"}]
                  }
                },
                "required" => ["next"]
              }
            }
          }
        },
        "required" => ["payload"]
      }

      result = project(raw, "openai_strict", :strict)
      payload = result.schema["properties"]["payload"]
      canonical_ref = "#/properties/payload/$defs/Node"

      assert result.accepted
      assert payload["properties"]["root"]["$ref"] == canonical_ref

      assert payload["$defs"]["Node"]["properties"]["next"]["anyOf"] == [
               %{"$ref" => canonical_ref},
               %{"type" => "null"}
             ]

      refute Map.has_key?(payload, "definitions")
    end

    test "external and anchor references are not treated as dangling local pointers" do
      external = project(%{"$ref" => "https://example.com/schema.json#/$defs/Node"}, "canonical")
      anchor = project(%{"$ref" => "#Node"}, "canonical")

      assert external.accepted
      assert anchor.accepted
      refute Enum.any?(external.omens, &(&1.code == "NYA-SCHEMA-014"))
      refute Enum.any?(anchor.omens, &(&1.code == "NYA-SCHEMA-014"))
    end

    test "const becomes an enum accepted by openai_strict" do
      raw = %{
        "type" => "object",
        "properties" => %{"kind" => %{"const" => "fixed"}},
        "required" => ["kind"],
        "additionalProperties" => false
      }

      result = project(raw, "openai_strict", :strict)

      assert result.accepted
      assert result.schema["properties"]["kind"]["enum"] == ["fixed"]
      refute Map.has_key?(result.schema["properties"]["kind"], "const")
    end
  end

  describe "deterministic diagnostics" do
    test "same schema and profile produce identical omens" do
      raw = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "additionalProperties" => false
      }

      r1 = project(raw, "gemini", :permissive)
      r2 = project(raw, "gemini", :permissive)
      assert r1.omens == r2.omens
    end
  end

  describe "no silent validation weakening" do
    test "undeclared required properties reject the projection" do
      raw = %{
        "type" => "object",
        "properties" => %{"known" => %{"type" => "string"}},
        "required" => ["known", "missing"],
        "additionalProperties" => false
      }

      result = project(raw, "openai_strict", :compatible)

      refute result.accepted

      assert Enum.any?(result.omens, fn omen ->
               omen.code == "NYA-SCHEMA-013" and omen.severity == :rejected and
                 omen.schema_path == ["required"] and omen.source == "missing"
             end)
    end

    test "undeclared required properties remain rejected for rewriting profiles in permissive mode" do
      raw = %{
        "type" => "object",
        "properties" => %{"known" => %{"type" => "string"}},
        "required" => ["missing"]
      }

      result = project(raw, "openai_strict", :permissive)

      refute result.accepted
      assert Enum.any?(result.omens, &(&1.code == "NYA-SCHEMA-013"))
    end

    test "canonical preserves undeclared required properties" do
      raw = %{
        "type" => "object",
        "properties" => %{"known" => %{"type" => "string"}},
        "required" => ["ghost"]
      }

      result = project(raw, "canonical", :strict)

      assert result.accepted
      assert result.schema["required"] == ["ghost"]
      refute Enum.any?(result.omens, &(&1.code == "NYA-SCHEMA-013"))
    end

    test "passthrough preserves undeclared required properties" do
      raw = %{
        "type" => "object",
        "properties" => %{"known" => %{"type" => "string"}},
        "required" => ["ghost"]
      }

      result = project(raw, "passthrough", :strict)

      assert result.accepted
      assert result.schema == raw
      refute Enum.any?(result.omens, &(&1.code == "NYA-SCHEMA-013"))
    end

    test "dangling local references reject the projection" do
      raw = %{
        "type" => "object",
        "properties" => %{"child" => %{"$ref" => "#/$defs/Missing"}},
        "$defs" => %{"Node" => %{"type" => "string"}}
      }

      result = project(raw, "canonical", :compatible)

      refute result.accepted

      assert Enum.any?(result.omens, fn omen ->
               omen.code == "NYA-SCHEMA-014" and omen.severity == :rejected and
                 omen.schema_path == ["properties", "child", "$ref"] and
                 omen.source == "#/$defs/Missing"
             end)
    end

    test "dangling references to nested definitions reject the projection" do
      raw = %{
        "type" => "object",
        "properties" => %{
          "payload" => %{
            "type" => "object",
            "properties" => %{
              "child" => %{"$ref" => "#/properties/payload/$defs/Missing"}
            },
            "$defs" => %{"Node" => %{"type" => "string"}}
          }
        }
      }

      result = project(raw, "canonical", :compatible)

      refute result.accepted
      assert Enum.any?(result.omens, &(&1.code == "NYA-SCHEMA-014"))
    end

    test "array without items is not silently relaxed in strict" do
      raw = %{"type" => "array"}
      result = project(raw, "openai_strict", :strict)
      refute result.accepted
      assert Enum.any?(result.omens, &(&1.severity == :rejected))
    end

    test "array without items remains rejected in compatible mode" do
      raw = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{"values" => %{"type" => "array"}},
        "required" => ["values"]
      }

      result = project(raw, "openai_strict", :compatible)

      refute result.accepted
      assert Enum.any?(result.omens, &(&1.code == "NYA-SCHEMA-009" and &1.severity == :rejected))
    end

    test "empty enum is reported" do
      raw = %{"enum" => []}
      result = project(raw, "claude", :permissive)

      assert Enum.any?(result.omens, fn o ->
               String.contains?(o.rule, "empty") or String.contains?(o.explanation, "empty")
             end)
    end

    test "mixed enum rejected for gemini" do
      raw = %{"enum" => ["red", 42, true]}
      result = project(raw, "gemini", :strict)
      refute result.accepted
      assert Enum.any?(result.omens, &(&1.severity == :rejected))
    end
  end

  describe "description truncation" do
    test "claude hypothesis does not impose an undocumented description limit" do
      long = String.duplicate("a", 2000)
      raw = %{"type" => "string", "description" => long}
      result = project(raw, "claude")
      assert result.schema["description"] == long
      refute Enum.any?(result.omens, &(&1.code == "NYA-PROFILE-007"))
    end
  end

  describe "allOf merge" do
    test "non-contradictory allOf merges for openai_strict" do
      raw = %{
        "allOf" => [
          %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}},
          %{"type" => "object", "properties" => %{"b" => %{"type" => "integer"}}}
        ]
      }

      result = project(raw, "openai_strict", :compatible)
      assert result.accepted
      assert Map.has_key?(result.schema["properties"], "a")
      assert Map.has_key?(result.schema["properties"], "b")
      assert result.schema["required"] == ["a", "b"]
      assert result.schema["additionalProperties"] == false
      assert Enum.any?(result.omens, &(&1.code == "NYA-PROFILE-010"))
    end

    test "contradictory allOf rejected" do
      raw = %{
        "allOf" => [
          %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}},
          %{"type" => "object", "properties" => %{"x" => %{"type" => "integer"}}}
        ]
      }

      result = project(raw, "openai_strict", :strict)
      assert Enum.any?(result.omens, &(&1.severity == :rejected))
    end
  end

  describe "nullable handling" do
    test "nullable type array preserves null" do
      raw = %{"type" => ["string", "null"]}
      result = project(raw, "claude")
      assert result.accepted
      assert result.schema["type"] == ["string", "null"]
    end

    test "explicit nullable anyOf remains anyOf" do
      raw = %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
      result = project(raw, "canonical")

      assert result.accepted
      assert is_list(result.schema["anyOf"])
      refute Map.has_key?(result.schema, "type")
    end
  end

  describe "profile boundaries" do
    test "canonical rejects unmodeled prefixItems instead of dropping it silently" do
      raw = %{
        "type" => "array",
        "prefixItems" => [%{"type" => "string"}]
      }

      result = project(raw, "canonical", :compatible)

      refute result.accepted

      assert Enum.any?(result.omens, fn omen ->
               omen.code == "NYA-PROFILE-012" and omen.severity == :rejected and
                 omen.schema_path == [] and omen.source == "prefixItems"
             end)
    end

    test "canonical rejects root and nested schema identifiers it cannot preserve" do
      raw = %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "https://example.com/root",
        "type" => "object",
        "properties" => %{
          "value" => %{
            "$schema" => "https://json-schema.org/draft/2020-12/schema",
            "$id" => "https://example.com/value",
            "type" => "string"
          }
        }
      }

      result = project(raw, "canonical", :compatible)

      refute result.accepted

      for {path, keyword} <- [
            {[], "$id"},
            {[], "$schema"},
            {["properties", "value"], "$id"},
            {["properties", "value"], "$schema"}
          ] do
        assert Enum.any?(result.omens, fn omen ->
                 omen.code == "NYA-PROFILE-012" and omen.schema_path == path and
                   omen.source == keyword
               end)
      end
    end

    test "canonical preserves boolean schemas at root and in modeled children" do
      assert %{accepted: true, schema: true} = project(true, "canonical")
      assert %{accepted: true, schema: false} = project(false, "canonical")

      object =
        project(
          %{
            "type" => "object",
            "properties" => %{"allowed" => true, "forbidden" => false}
          },
          "canonical"
        )

      array = project(%{"type" => "array", "items" => false}, "canonical")

      assert object.accepted
      assert object.schema["properties"] == %{"allowed" => true, "forbidden" => false}
      assert array.accepted
      assert array.schema["items"] == false
    end

    test "named compatibility profiles reject boolean schemas explicitly" do
      for profile <- ["claude", "gemini", "openai_strict", "vscode"], schema <- [true, false] do
        result = project(schema, profile, :compatible)

        refute result.accepted
        assert result.schema == schema

        assert Enum.any?(result.omens, fn omen ->
                 omen.code == "NYA-PROFILE-012" and omen.severity == :rejected
               end)
      end

      for profile <- ["claude", "gemini", "openai_strict", "vscode"] do
        result = project(%{"type" => "array", "items" => false}, profile, :compatible)

        refute result.accepted
        assert result.schema["items"] == false

        assert Enum.any?(result.omens, fn omen ->
                 omen.code == "NYA-PROFILE-012" and omen.schema_path == ["items"]
               end)
      end
    end

    test "configured vendor extensions remain exempt from unmodeled diagnostics" do
      {:ok, profile} = Builtins.fetch("canonical")
      profile = %{profile | vendor_extension_prefixes: ["x-"]}
      scroll = compile(%{"type" => "string", "x-vendor" => %{"enabled" => true}})

      result = Projector.project(scroll, profile, :compatible)

      assert result.accepted
      refute Enum.any?(result.omens, &(&1.code == "NYA-PROFILE-012"))
    end

    test "passthrough preserves and accepts prefixItems" do
      raw = %{
        "type" => "array",
        "prefixItems" => [%{"type" => "string"}],
        "items" => false
      }

      result = project(raw, "passthrough", :strict)

      assert result.accepted
      assert result.schema == raw
      assert result.omens == []
    end

    test "passthrough returns the original schema" do
      raw = %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "string",
        "title" => "Label",
        "default" => "x",
        "examples" => ["x"],
        "x-vendor" => %{"keep" => true}
      }

      result = project(raw, "passthrough")
      assert result.schema == raw
      assert result.omens == []
    end

    test "passthrough preserves a false boolean schema" do
      result = project(false, "passthrough")

      assert result.schema == false
      assert result.accepted
    end

    test "openai_strict rejects unsupported raw constructs" do
      raw = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "value" => %{"type" => "string", "if" => %{"const" => "x"}}
        },
        "required" => ["value"]
      }

      result = project(raw, "openai_strict", :strict)

      refute result.accepted
      assert Enum.any?(result.omens, &(&1.code == "NYA-PROFILE-012"))
    end

    test "openai_strict rejects nested boolean schemas" do
      raw = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{"value" => false},
        "required" => ["value"]
      }

      result = project(raw, "openai_strict", :strict)

      refute result.accepted
      assert Enum.any?(result.omens, &(&1.code == "NYA-PROFILE-012"))
    end

    test "canonical projection preserves supported metadata" do
      raw = %{
        "type" => "string",
        "title" => "Label",
        "default" => nil,
        "examples" => ["x"]
      }

      result = project(raw, "canonical")

      assert result.schema["title"] == "Label"
      assert Map.has_key?(result.schema, "default")
      assert result.schema["default"] == nil
      assert result.schema["examples"] == ["x"]
    end

    test "openai_strict accepts ten object levels and rejects eleven" do
      accepted = project(nested_objects(10), "openai_strict", :compatible)
      rejected = project(nested_objects(11), "openai_strict", :compatible)

      assert accepted.accepted
      refute rejected.accepted
      assert Enum.any?(rejected.omens, &(&1.code == "NYA-PROFILE-009"))
    end
  end

  describe "omen structure" do
    test "every omen has required fields" do
      raw = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "additionalProperties" => false
      }

      result = project(raw, "gemini", :permissive)

      for omen <- result.omens do
        assert is_binary(omen.code)
        assert omen.severity in [:exact, :normalized, :lossy, :rejected]
        assert is_list(omen.schema_path)
        assert is_binary(omen.rule)
        assert is_binary(omen.explanation)
        assert is_boolean(omen.semantics_preserved)
      end
    end

    test "diagnostic codes follow NYA- prefix pattern" do
      raw = %{"const" => 1}
      result = project(raw, "gemini", :permissive)

      for omen <- result.omens do
        assert String.starts_with?(omen.code, "NYA-")
      end
    end
  end

  defp nested_objects(1), do: %{"type" => "object"}

  defp nested_objects(depth) do
    %{
      "type" => "object",
      "properties" => %{"next" => nested_objects(depth - 1)},
      "required" => ["next"],
      "additionalProperties" => false
    }
  end
end
