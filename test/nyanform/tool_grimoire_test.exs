defmodule Nyanform.ToolGrimoireTest do
  use ExUnit.Case, async: true

  alias Nyanform.Profile.Builtins
  alias Nyanform.ToolGrimoire

  describe "build" do
    test "preserves valid tool names" do
      tools = [
        %{
          "name" => "read_file",
          "description" => "Reads a file",
          "inputSchema" => %{"type" => "object"}
        }
      ]

      {:ok, profile} = Builtins.fetch("canonical")
      grimoire = ToolGrimoire.build(tools, profile, :strict)

      assert length(grimoire.entries) == 1
      [entry] = grimoire.entries
      assert entry.alias == "read_file"
      assert entry.name == "read_file"
    end

    test "sanitizes invalid characters in tool names" do
      tools = [
        %{"name" => "read file!", "description" => nil, "inputSchema" => %{"type" => "object"}}
      ]

      {:ok, profile} = Builtins.fetch("claude")
      grimoire = ToolGrimoire.build(tools, profile, :strict)

      [entry] = grimoire.entries
      assert entry.alias == "read_file"
    end

    test "adds collision suffix when names collide after sanitization" do
      tools = [
        %{"name" => "read-file", "description" => nil, "inputSchema" => %{"type" => "object"}},
        %{"name" => "read_file", "description" => nil, "inputSchema" => %{"type" => "object"}},
        %{"name" => "read.file", "description" => nil, "inputSchema" => %{"type" => "object"}}
      ]

      {:ok, profile} = Builtins.fetch("canonical")
      grimoire = ToolGrimoire.build(tools, profile, :strict)

      aliases = Enum.map(grimoire.entries, & &1.alias)
      assert length(Enum.uniq(aliases)) == 3
    end

    test "collision suffixes are deterministic" do
      tools = [
        %{"name" => "read-file", "description" => nil, "inputSchema" => %{"type" => "object"}},
        %{"name" => "read_file", "description" => nil, "inputSchema" => %{"type" => "object"}}
      ]

      {:ok, profile} = Builtins.fetch("canonical")
      g1 = ToolGrimoire.build(tools, profile, :strict)
      g2 = ToolGrimoire.build(tools, profile, :strict)

      assert Enum.map(g1.entries, & &1.alias) == Enum.map(g2.entries, & &1.alias)
    end
  end

  describe "resolve_origin" do
    test "resolves alias back to original name" do
      tools = [
        %{"name" => "read_file", "description" => nil, "inputSchema" => %{"type" => "object"}}
      ]

      {:ok, profile} = Builtins.fetch("canonical")
      grimoire = ToolGrimoire.build(tools, profile, :strict)

      assert {:ok, "read_file"} = ToolGrimoire.resolve_origin(grimoire, "read_file")
    end

    test "returns error for unknown alias" do
      {:ok, profile} = Builtins.fetch("canonical")
      grimoire = ToolGrimoire.build([], profile, :strict)

      assert {:error, :not_found} = ToolGrimoire.resolve_origin(grimoire, "nonexistent")
    end
  end

  describe "digests" do
    test "calculates stable digest for tool schemas" do
      tools = [
        %{
          "name" => "tool_a",
          "description" => nil,
          "inputSchema" => %{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}
        }
      ]

      {:ok, profile} = Builtins.fetch("canonical")
      g1 = ToolGrimoire.build(tools, profile, :strict)
      g2 = ToolGrimoire.build(tools, profile, :strict)

      [e1] = g1.entries
      [e2] = g2.entries
      assert e1.digest == e2.digest
      assert byte_size(e1.digest) == 64
    end
  end
end
