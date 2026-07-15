defmodule Nyanform.ToolGrimoireTest do
  use ExUnit.Case, async: true

  alias Nyanform.Profile.Builtins
  alias Nyanform.ToolGrimoire

  describe "build" do
    test "isolates a malformed required value to its tool" do
      tools = [
        %{
          "name" => "broken",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}},
            "required" => "name"
          }
        },
        %{"name" => "healthy", "inputSchema" => %{"type" => "object"}}
      ]

      {:ok, profile} = Builtins.fetch("canonical")
      grimoire = ToolGrimoire.build(tools, profile, :strict)

      assert Enum.find(grimoire.entries, &(&1.name == "broken")).accepted == false
      assert Enum.find(grimoire.entries, &(&1.name == "healthy")).accepted == true
      assert Enum.any?(grimoire.omens, &(&1.tool == "broken" and &1.code == "NYA-SCHEMA-001"))
    end

    test "isolates malformed type unions to their tool" do
      tools = [
        %{"name" => "broken", "inputSchema" => %{"type" => ["string", 1]}},
        %{"name" => "healthy", "inputSchema" => %{"type" => "object"}}
      ]

      {:ok, profile} = Builtins.fetch("canonical")
      grimoire = ToolGrimoire.build(tools, profile, :strict)

      assert Enum.find(grimoire.entries, &(&1.name == "broken")).accepted == false
      assert Enum.find(grimoire.entries, &(&1.name == "healthy")).accepted == true
      assert Enum.any?(grimoire.omens, &(&1.tool == "broken" and &1.code == "NYA-SCHEMA-001"))
    end

    test "isolates malformed tool envelopes from healthy tools" do
      tools = [
        nil,
        %{"name" => "missing_schema"},
        %{"name" => 7, "inputSchema" => %{}},
        %{"name" => "healthy", "inputSchema" => %{"type" => "object"}}
      ]

      {:ok, profile} = Builtins.fetch("canonical")
      grimoire = ToolGrimoire.build(tools, profile, :permissive)

      assert Enum.count(grimoire.entries, & &1.publishable) == 1
      assert Enum.find(grimoire.entries, &(&1.name == "healthy")).accepted
      assert {:ok, "healthy"} = ToolGrimoire.resolve_origin(grimoire, "healthy")
      assert length(Enum.filter(grimoire.omens, &(&1.rule == "invalid_tool_definition"))) == 3
    end

    test "returns a rejected catalog for a non-list tools value" do
      {:ok, profile} = Builtins.fetch("canonical")
      grimoire = ToolGrimoire.build(%{"name" => "bad"}, profile, :strict)

      assert grimoire.entries == []
      assert [%{rule: "invalid_tools_catalog", severity: :rejected}] = grimoire.omens
    end

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

    test "preserves documented Gemini CLI name characters" do
      tools = [%{"name" => "repo:search.v2", "inputSchema" => %{"type" => "object"}}]
      {:ok, profile} = Builtins.fetch("gemini")

      grimoire = ToolGrimoire.build(tools, profile, :strict)

      assert [%{alias: "repo:search.v2", accepted: true}] = grimoire.entries
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
        %{"name" => "read file", "description" => nil, "inputSchema" => %{"type" => "object"}},
        %{"name" => "read?file", "description" => nil, "inputSchema" => %{"type" => "object"}},
        %{"name" => "read_file", "description" => nil, "inputSchema" => %{"type" => "object"}}
      ]

      {:ok, profile} = Builtins.fetch("claude")
      g1 = ToolGrimoire.build(tools, profile, :strict)
      g2 = ToolGrimoire.build(Enum.reverse(tools), profile, :strict)

      aliases1 = Map.new(g1.entries, &{&1.name, &1.alias})
      aliases2 = Map.new(g2.entries, &{&1.name, &1.alias})

      assert aliases1 == aliases2
      assert aliases1["read_file"] == "read_file"
    end

    test "projection rejection hides the alias outside permissive mode" do
      tools = [
        %{
          "name" => "root_union",
          "description" => nil,
          "inputSchema" => %{
            "anyOf" => [%{"type" => "object"}, %{"type" => "object"}]
          }
        }
      ]

      {:ok, profile} = Builtins.fetch("openai_strict")
      grimoire = ToolGrimoire.build(tools, profile, :strict)
      [entry] = grimoire.entries

      refute entry.accepted
      assert {:error, :not_found} = ToolGrimoire.resolve_origin(grimoire, entry.alias)
      assert Enum.any?(entry.omens, &(&1.code == "NYA-PROFILE-008"))
    end

    test "stores the projected schema used by the live catalog" do
      tools = [
        %{
          "name" => "strict_object",
          "description" => nil,
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"value" => %{"type" => "string"}},
            "required" => ["value"],
            "additionalProperties" => false
          }
        }
      ]

      {:ok, profile} = Builtins.fetch("openai_strict")
      grimoire = ToolGrimoire.build(tools, profile, :strict)
      [entry] = grimoire.entries

      assert entry.accepted
      assert entry.projected_schema["required"] == ["value"]
      assert entry.projected_schema["additionalProperties"] == false
    end

    test "aliases remain unique and within the profile length limit" do
      prefix = String.duplicate("a", 80)

      tools =
        for suffix <- ["!", "?", ":"] do
          %{"name" => prefix <> suffix, "inputSchema" => %{"type" => "object"}}
        end

      {:ok, profile} = Builtins.fetch("openai_strict")
      grimoire = ToolGrimoire.build(tools, profile, :compatible)
      aliases = Enum.map(grimoire.entries, & &1.alias)

      assert length(Enum.uniq(aliases)) == 3
      assert Enum.all?(aliases, &(String.length(&1) <= 64))
      assert Enum.all?(aliases, &Regex.match?(~r/^[a-zA-Z0-9_-]{1,64}$/, &1))
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

  describe "append" do
    test "reuses aliases and entries when a page is requested again" do
      {:ok, profile} = Builtins.fetch("canonical")

      first =
        ToolGrimoire.build(
          [%{"name" => "collision name", "inputSchema" => %{"type" => "object"}}],
          profile,
          :compatible
        )

      page = [%{"name" => "collision_name", "inputSchema" => %{"type" => "object"}}]
      once = ToolGrimoire.append(first, page, profile, :compatible)
      twice = ToolGrimoire.append(once, page, profile, :compatible)

      assert length(twice.entries) == 2
      assert twice.entries == once.entries
      assert twice.alias_map == once.alias_map
      assert twice.omens == once.omens
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
