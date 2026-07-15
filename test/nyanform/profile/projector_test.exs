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
      assert Enum.any?(result.omens, &(&1.severity == :normalized))
    end
  end

  describe "lossy transformations" do
    test "additionalProperties: false is lossy when unsupported" do
      raw = %{
        "type" => "object",
        "properties" => %{"x" => %{"type" => "string"}},
        "additionalProperties" => false
      }

      result = project(raw, "gemini", :permissive)
      lossy = Enum.filter(result.omens, &(&1.severity == :lossy))
      assert length(lossy) >= 1
    end

    test "const is lossy for gemini" do
      raw = %{"const" => 42}
      result = project(raw, "gemini", :permissive)
      lossy = Enum.filter(result.omens, &(&1.severity == :lossy))
      assert length(lossy) >= 1
    end

    test "format dropped is reported as lossy when unsupported" do
      raw = %{"type" => "string", "format" => "date-time"}
      result = project(raw, "canonical", :permissive)
      assert result.accepted
    end
  end

  describe "strict policy rejection" do
    test "const rejected in strict mode for gemini" do
      raw = %{"const" => 42}
      result = project(raw, "gemini", :strict)
      refute result.accepted
      assert Enum.any?(result.omens, &(&1.severity == :rejected))
    end

    test "tuple array rejected for openai_strict" do
      raw = %{"type" => "array", "items" => [%{"type" => "string"}, %{"type" => "integer"}]}
      result = project(raw, "openai_strict", :strict)
      refute result.accepted
      assert Enum.any?(result.omens, &(&1.severity == :rejected))
    end

    test "union rejected for openai_strict" do
      raw = %{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]}
      result = project(raw, "openai_strict", :strict)
      refute result.accepted
      assert Enum.any?(result.omens, &(&1.severity == :rejected))
    end

    test "reference rejected for openai_strict" do
      raw = %{"$ref" => "#/$defs/Foo"}
      result = project(raw, "openai_strict", :strict)
      refute result.accepted
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
      raw = %{"type" => ["string", "null"]}
      result = project(raw, "openai_strict", :compatible)
      assert result.accepted
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
    test "array without items is not silently relaxed in strict" do
      raw = %{"type" => "array"}
      result = project(raw, "openai_strict", :strict)
      refute result.accepted
      assert Enum.any?(result.omens, &(&1.severity == :rejected))
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
    test "description truncated for claude" do
      long = String.duplicate("a", 2000)
      raw = %{"type" => "string", "description" => long}
      result = project(raw, "claude")
      assert String.length(result.schema["description"]) == 1024

      assert Enum.any?(
               result.omens,
               &(&1.severity == :normalized or &1.severity == :lossy or &1.severity == :exact)
             )
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
    test "nullable type array collapsed to single type" do
      raw = %{"type" => ["string", "null"]}
      result = project(raw, "claude")
      assert result.accepted
      assert result.schema["type"] == "string"
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
end
