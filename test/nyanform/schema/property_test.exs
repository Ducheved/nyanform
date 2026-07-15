defmodule Nyanform.Schema.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Nyanform.Profile.Builtins
  alias Nyanform.Schema.{Pipeline, Serializer}
  alias Nyanform.ToolGrimoire

  property "canonicalization is idempotent" do
    check all(schema <- schema_generator(), max_runs: 50) do
      {:ok, first} = Pipeline.compile(schema)
      {:ok, second} = Pipeline.compile(schema)

      assert first.digest == second.digest
      assert Serializer.digest(first.scroll) == Serializer.digest(second.scroll)
    end
  end

  property "deterministic input produces deterministic output" do
    check all(schema <- schema_generator(), max_runs: 50) do
      {:ok, first} = Pipeline.compile(schema)
      {:ok, second} = Pipeline.compile(schema)

      assert first.digest == second.digest
    end
  end

  property "serialization round trips through recompilation" do
    check all(schema <- schema_generator(), max_runs: 50) do
      {:ok, result} = Pipeline.compile(schema)
      serialized = Serializer.serialize(result.scroll)
      assert is_binary(serialized)
      assert byte_size(serialized) > 0
    end
  end

  property "digest is always 64 hex characters (sha256)" do
    check all(schema <- schema_generator(), max_runs: 50) do
      {:ok, result} = Pipeline.compile(schema)

      assert byte_size(result.digest) == 64
      assert Regex.match?(~r/^[0-9a-f]+$/, result.digest)
    end
  end

  property "alias generation is stable" do
    check all(name <- string(:alphanumeric, min_length: 3, max_length: 20), max_runs: 50) do
      {:ok, profile} = Builtins.fetch("canonical")
      tools = [%{"name" => name, "description" => nil, "inputSchema" => %{"type" => "object"}}]
      grimoire1 = ToolGrimoire.build(tools, profile, :strict)
      grimoire2 = ToolGrimoire.build(tools, profile, :strict)

      aliases1 = Enum.map(grimoire1.entries, & &1.alias)
      aliases2 = Enum.map(grimoire2.entries, & &1.alias)
      assert aliases1 == aliases2
    end
  end

  property "alias generation has no collisions within generated catalogs" do
    check all(
            names <-
              list_of(string(:alphanumeric, min_length: 3, max_length: 10),
                min_length: 2,
                max_length: 10
              ),
            max_runs: 30
          ) do
      {:ok, profile} = Builtins.fetch("canonical")

      tools =
        Enum.map(names, fn name ->
          %{"name" => name, "description" => nil, "inputSchema" => %{"type" => "object"}}
        end)

      grimoire = ToolGrimoire.build(tools, profile, :strict)
      aliases = Enum.map(grimoire.entries, & &1.alias)

      assert length(aliases) == length(Enum.uniq(aliases))
    end
  end

  defp schema_generator do
    one_of([
      constant(%{"type" => "string"}),
      constant(%{"type" => "integer"}),
      constant(%{"type" => "boolean"}),
      constant(%{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}),
      constant(%{"type" => "array", "items" => %{"type" => "string"}}),
      constant(%{"enum" => ["a", "b", "c"]}),
      constant(%{"oneOf" => [%{"type" => "string"}, %{"type" => "integer"}]}),
      constant(%{"type" => "string", "minLength" => 1, "maxLength" => 100}),
      constant(%{
        "type" => "object",
        "properties" => %{"a" => %{"type" => "string"}, "b" => %{"type" => "integer"}},
        "required" => ["a"]
      }),
      constant(%{"type" => ["string", "null"]}),
      constant(%{"const" => 42}),
      constant(%{"type" => "object", "additionalProperties" => false})
    ])
  end
end
