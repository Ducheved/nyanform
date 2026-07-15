defmodule Nyanform.Report.RendererTest do
  use ExUnit.Case, async: true

  alias Nyanform.Diagnostic.Omen
  alias Nyanform.Report.{CompatibilityResult, Renderer}

  describe "parse_format" do
    test "accepts known formats" do
      assert {:ok, :terminal} = Renderer.parse_format("terminal")
      assert {:ok, :json} = Renderer.parse_format("json")
      assert {:ok, :junit} = Renderer.parse_format("junit")
      assert {:ok, :sarif} = Renderer.parse_format("sarif")
    end

    test "rejects unknown formats" do
      assert {:error, _} = Renderer.parse_format("csv")
    end

    test "limits inspect reports to implemented formats" do
      assert {:ok, :terminal} = Renderer.parse_inspect_format("terminal")
      assert {:ok, :json} = Renderer.parse_inspect_format("json")
      assert {:error, _} = Renderer.parse_inspect_format("junit")
      assert {:error, _} = Renderer.parse_inspect_format("sarif")
    end
  end

  describe "terminal matrix" do
    test "renders a table with profile rows" do
      results = [sample_result("claude", true), sample_result("gemini", false)]
      output = Renderer.matrix_report(results, :terminal)

      assert String.contains?(output, "claude")
      assert String.contains?(output, "gemini")
      assert String.contains?(output, "Profile")
    end
  end

  describe "json matrix" do
    test "produces valid JSON with results array" do
      results = [sample_result("claude", true)]
      output = Renderer.matrix_report(results, :json)
      parsed = Jason.decode!(output)

      assert length(parsed["results"]) == 1
      assert hd(parsed["results"])["profile"] == "claude"
    end
  end

  describe "junit matrix" do
    test "produces valid XML with testsuites" do
      results = [sample_result("claude", false)]
      output = Renderer.matrix_report(results, :junit)

      assert String.starts_with?(output, "<?xml")
      assert String.contains?(output, "<testsuites")
      assert String.contains?(output, "<testsuite")
      assert String.contains?(output, "<failure")
    end

    test "escapes special XML characters" do
      omen =
        Omen.rejected("NYA-SCHEMA-008",
          explanation: ~s(constraints <"a" & 'b'> conflict)
        )

      result = %CompatibilityResult{
        profile: "test",
        policy: :strict,
        tool_results: [],
        accepted: false,
        worst_severity: :rejected,
        omens: [omen],
        duration_us: 100
      }

      output = Renderer.matrix_report([result], :junit)
      assert String.contains?(output, "&lt;")
      assert String.contains?(output, "&amp;")
      assert String.contains?(output, "&quot;")
      assert String.contains?(output, "&apos;")
    end
  end

  describe "sarif matrix" do
    test "produces valid SARIF 2.1.0 JSON" do
      results = [sample_result("openai_strict", false)]
      output = Renderer.matrix_report(results, :sarif)
      parsed = Jason.decode!(output)

      assert parsed["version"] == "2.1.0"
      assert length(parsed["runs"]) == 1
      run = hd(parsed["runs"])
      assert run["tool"]["driver"]["name"] == "Nyanform"
      assert length(run["results"]) > 0
    end

    test "includes rules for each unique code" do
      results = [sample_result("openai_strict", false)]
      output = Renderer.matrix_report(results, :sarif)
      parsed = Jason.decode!(output)

      run = hd(parsed["runs"])
      rules = run["tool"]["driver"]["rules"]
      assert length(rules) > 0
      assert Enum.all?(rules, &String.starts_with?(&1["id"], "NYA-"))
    end
  end

  describe "inspect report" do
    test "terminal inspect renders server info and tool count" do
      report = %{
        server_info: %{name: "test-server"},
        protocol_revision: "2025-11-25",
        tool_count: 3,
        schema_valid: true,
        omens: [],
        duration_us: 1500
      }

      output = Renderer.inspect_report(report, :terminal)
      assert String.contains?(output, "test-server")
      assert String.contains?(output, "2025-11-25")
      assert String.contains?(output, "3")
    end

    test "json inspect produces valid JSON" do
      report = %{
        server_info: %{name: "test-server"},
        protocol_revision: "2025-11-25",
        tool_count: 1,
        schema_valid: true,
        omens: [],
        duration_us: 0
      }

      output = Renderer.inspect_report(report, :json)
      parsed = Jason.decode!(output)
      assert parsed["server_info"]["name"] == "test-server"
      assert parsed["tool_count"] == 1
    end
  end

  defp sample_result(profile, accepted) do
    omens =
      if accepted do
        []
      else
        [
          Omen.rejected("NYA-SCHEMA-007",
            schema_path: ["root"],
            rule: "union_unsupported",
            explanation: "unions are not supported"
          )
        ]
      end

    %CompatibilityResult{
      profile: profile,
      policy: :strict,
      tool_results: [
        %{
          tool: "test_tool",
          alias: nil,
          accepted: accepted,
          worst_severity: if(accepted, do: nil, else: :rejected),
          omens: omens,
          digest: "abc123"
        }
      ],
      accepted: accepted,
      worst_severity: if(accepted, do: nil, else: :rejected),
      omens: omens,
      duration_us: 500
    }
  end
end
