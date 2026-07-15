defmodule Nyanform.ClientFamiliarTest do
  use ExUnit.Case, async: true

  alias Nyanform.ClientFamiliar

  describe "detect" do
    test "detects claude clients" do
      result = ClientFamiliar.detect(%{"name" => "Claude Code", "version" => "1.0"})
      assert result.profile == "claude"
      assert result.confidence == :known
    end

    test "detects gemini clients" do
      result = ClientFamiliar.detect(%{"name" => "Gemini CLI", "version" => "0.1"})
      assert result.profile == "gemini"
      assert result.confidence == :known
    end

    test "detects cursor as openai_strict" do
      result = ClientFamiliar.detect(%{"name" => "Cursor", "version" => "0.40"})
      assert result.profile == "openai_strict"
      assert result.confidence == :known
    end

    test "detects vscode clients" do
      result = ClientFamiliar.detect(%{"name" => "VS Code MCP", "version" => "1.90"})
      assert result.profile == "vscode"
      assert result.confidence == :known
    end

    test "unknown clients fall back to canonical" do
      result = ClientFamiliar.detect(%{"name" => "MyCustomClient", "version" => "1.0"})
      assert result.profile == "canonical"
      assert result.confidence == :unknown
    end

    test "nil client info defaults to canonical" do
      result = ClientFamiliar.detect(nil)
      assert result.profile == "canonical"
      assert result.confidence == :unknown
    end
  end

  describe "resolve" do
    test "auto resolves via detection" do
      assert {:ok, "claude"} = ClientFamiliar.resolve("auto", %{"name" => "Claude Code"})
    end

    test "explicit profile overrides auto-detection" do
      assert {:ok, "gemini"} = ClientFamiliar.resolve("gemini", %{"name" => "Claude Code"})
    end
  end
end
