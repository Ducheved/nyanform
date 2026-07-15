defmodule Nyanform.RewriteTalismanTest do
  use ExUnit.Case, async: true

  alias Nyanform.RewriteTalisman
  alias Nyanform.Schema.Pipeline

  defp compile(raw) do
    {:ok, %{scroll: scroll}} = Pipeline.compile(raw)
    scroll
  end

  describe "repair object arguments" do
    test "valid object arguments remain unchanged" do
      args = %{"name" => "test", "count" => 5}

      schema =
        compile(%{
          "type" => "object",
          "properties" => %{"name" => %{"type" => "string"}, "count" => %{"type" => "integer"}}
        })

      result = RewriteTalisman.repair(args, schema)

      assert result.arguments == args
      assert result.omens == []
    end

    test "JSON-encoded object is repaired at object path" do
      args = %{"config" => ~s({"key":"value"})}

      schema =
        compile(%{
          "type" => "object",
          "properties" => %{
            "config" => %{"type" => "object", "properties" => %{"key" => %{"type" => "string"}}}
          }
        })

      result = RewriteTalisman.repair(args, schema)

      assert result.arguments["config"] == %{"key" => "value"}
      assert length(result.omens) == 1
      assert hd(result.omens).code == "NYA-ARG-001"
    end

    test "partial JSON strings are not repaired" do
      args = %{"config" => ~s({"key":)}

      schema =
        compile(%{"type" => "object", "properties" => %{"config" => %{"type" => "object"}}})

      result = RewriteTalisman.repair(args, schema)

      assert result.arguments["config"] == ~s({"key":)
      assert result.omens == []
    end

    test "synthetic null for an optional property becomes omission" do
      schema =
        compile(%{
          "type" => "object",
          "properties" => %{"optional" => %{"type" => "string"}}
        })

      result = RewriteTalisman.repair(%{"optional" => nil}, schema, drop_optional_nulls: true)

      refute Map.has_key?(result.arguments, "optional")
      assert Enum.any?(result.omens, &(&1.code == "NYA-ARG-004"))
    end

    test "explicitly nullable optional property keeps null" do
      schema =
        compile(%{
          "type" => "object",
          "properties" => %{"optional" => %{"type" => ["string", "null"]}}
        })

      result = RewriteTalisman.repair(%{"optional" => nil}, schema)

      assert Map.has_key?(result.arguments, "optional")
      assert result.arguments["optional"] == nil
    end

    test "non-JSON strings are not repaired" do
      args = %{"name" => "hello world"}
      schema = compile(%{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}})
      result = RewriteTalisman.repair(args, schema)

      assert result.arguments["name"] == "hello world"
      assert result.omens == []
    end
  end

  describe "repair array arguments" do
    test "JSON-encoded array is repaired at array path" do
      args = %{"tags" => ~s(["a","b","c"])}

      schema =
        compile(%{
          "type" => "object",
          "properties" => %{"tags" => %{"type" => "array", "items" => %{"type" => "string"}}}
        })

      result = RewriteTalisman.repair(args, schema)

      assert result.arguments["tags"] == ["a", "b", "c"]
      assert length(result.omens) == 1
      assert hd(result.omens).code == "NYA-ARG-002"
    end

    test "array values are recursively repaired" do
      args = %{"items" => [%{"config" => ~s({"x":1})}]}

      schema =
        compile(%{
          "type" => "object",
          "properties" => %{
            "items" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "config" => %{
                    "type" => "object",
                    "properties" => %{"x" => %{"type" => "integer"}}
                  }
                }
              }
            }
          }
        })

      result = RewriteTalisman.repair(args, schema)
      [item] = result.arguments["items"]
      assert item["config"] == %{"x" => 1}
    end
  end

  describe "forbidden repairs" do
    test "numeric strings are not guessed as numbers" do
      args = %{"count" => "42"}

      schema =
        compile(%{"type" => "object", "properties" => %{"count" => %{"type" => "integer"}}})

      result = RewriteTalisman.repair(args, schema)

      assert result.arguments["count"] == "42"
      assert result.omens == []
    end

    test "boolean strings are not guessed as booleans" do
      args = %{"active" => "true"}

      schema =
        compile(%{"type" => "object", "properties" => %{"active" => %{"type" => "boolean"}}})

      result = RewriteTalisman.repair(args, schema)

      assert result.arguments["active"] == "true"
      assert result.omens == []
    end
  end

  describe "secret redaction" do
    test "redacts secret-like keys" do
      args = %{"api_key" => "secret123", "name" => "test", "password" => "hunter2"}
      redacted = RewriteTalisman.redact_secrets(args)

      assert redacted["api_key"] == "[REDACTED]"
      assert redacted["password"] == "[REDACTED]"
      assert redacted["name"] == "test"
    end

    test "redacts nested secrets" do
      args = %{"config" => %{"token" => "abc", "value" => 42}}
      redacted = RewriteTalisman.redact_secrets(args)

      assert redacted["config"]["token"] == "[REDACTED]"
      assert redacted["config"]["value"] == 42
    end

    test "original arguments are preserved in repair result" do
      args = %{"config" => ~s({"key":"value"})}

      schema =
        compile(%{"type" => "object", "properties" => %{"config" => %{"type" => "object"}}})

      result = RewriteTalisman.repair(args, schema)

      assert result.original_preserved == args
    end
  end
end
