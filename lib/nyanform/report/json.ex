defmodule Nyanform.Report.Json do
  alias Nyanform.Diagnostic.Omen
  alias Nyanform.Report.CompatibilityResult

  @spec render_inspect(map()) :: String.t()
  def render_inspect(report) do
    report
    |> inspect_to_map()
    |> Jason.encode!(pretty: true)
  end

  @spec render_matrix([CompatibilityResult.t()]) :: String.t()
  def render_matrix(results) do
    results
    |> Enum.map(&result_to_map/1)
    |> then(&%{"results" => &1})
    |> Jason.encode!(pretty: true)
  end

  defp inspect_to_map(report) do
    %{
      server_info: Map.get(report, :server_info, %{}),
      protocol_revision: Map.get(report, :protocol_revision),
      capabilities: Map.get(report, :capabilities, %{}),
      tool_count: Map.get(report, :tool_count, 0),
      schema_valid: Map.get(report, :schema_valid, true),
      unsupported_constructs: Map.get(report, :unsupported_constructs, []),
      normalization_operations:
        Enum.map(Map.get(report, :normalization_operations, []), &omen_to_map/1),
      lossy_operations: Enum.map(Map.get(report, :lossy_operations, []), &omen_to_map/1),
      rejected_tools: Map.get(report, :rejected_tools, []),
      aliases: Map.get(report, :aliases, %{}),
      omens: Enum.map(Map.get(report, :omens, []), &omen_to_map/1),
      duration_us: Map.get(report, :duration_us, 0)
    }
  end

  defp result_to_map(%CompatibilityResult{} = result) do
    %{
      profile: result.profile,
      policy: Atom.to_string(result.policy),
      accepted: result.accepted,
      worst_severity: severity_to_string(result.worst_severity),
      omens: Enum.map(result.omens, &omen_to_map/1),
      tools: Enum.map(result.tool_results, &tool_result_to_map/1),
      duration_us: result.duration_us
    }
  end

  defp tool_result_to_map(tool_result) do
    %{
      tool: tool_result.tool,
      alias: tool_result.alias,
      accepted: tool_result.accepted,
      worst_severity: severity_to_string(tool_result.worst_severity),
      omens: Enum.map(tool_result.omens, &omen_to_map/1),
      digest: tool_result.digest
    }
  end

  defp omen_to_map(%Omen{} = omen) do
    %{
      code: omen.code,
      severity: Atom.to_string(omen.severity),
      schema_path: omen.schema_path,
      rule: omen.rule,
      source: omen.source,
      target: omen.target,
      semantics_preserved: omen.semantics_preserved,
      explanation: omen.explanation,
      action: omen.action,
      tool: omen.tool,
      profile: omen.profile
    }
  end

  defp severity_to_string(nil), do: nil
  defp severity_to_string(s), do: Atom.to_string(s)
end
