defmodule Nyanform.Report.JUnit do
  alias Nyanform.Diagnostic.Omen
  alias Nyanform.Report.CompatibilityResult

  @spec render_matrix([CompatibilityResult.t()]) :: String.t()
  def render_matrix(results) do
    suites =
      results
      |> Enum.map_join("\n", &result_to_suite/1)

    total_tests = Enum.reduce(results, 0, fn r, acc -> acc + length(r.tool_results) + 1 end)
    total_failures = count_failures(results)

    ~s|<?xml version="1.0" encoding="UTF-8"?>\n| <>
      ~s|<testsuites tests="#{total_tests}" failures="#{total_failures}">\n| <>
      suites <> "\n</testsuites>"
  end

  defp result_to_suite(%CompatibilityResult{} = result) do
    test_count = length(result.tool_results) + 1
    failures = count_result_failures(result)

    cases =
      [
        suite_case(result)
        | Enum.map(result.tool_results, &tool_case(&1, result.profile))
      ]
      |> Enum.join("\n")

    ~s|  <testsuite name="#{attr(result.profile)}" tests="#{test_count}" failures="#{failures}">\n| <>
      cases <> "\n  </testsuite>"
  end

  defp suite_case(%CompatibilityResult{} = result) do
    name = "profile:#{result.profile}"

    if result.accepted do
      "    <testcase name=\"#{attr(name)}\" classname=\"nyanform.profile\"/>"
    else
      msg = worst_message(result)

      ~s|    <testcase name="#{attr(name)}" classname="nyanform.profile">\n| <>
        "      <failure message=\"#{attr(msg)}\"/>\n" <>
        "    </testcase>"
    end
  end

  defp tool_case(tool_result, profile) do
    name = "tool:#{tool_result.tool}"

    if tool_result.accepted do
      "    <testcase name=\"#{attr(name)}\" classname=\"nyanform.#{profile}\"/>"
    else
      msg = worst_tool_message(tool_result)

      ~s|    <testcase name="#{attr(name)}" classname="nyanform.#{profile}">\n| <>
        "      <failure message=\"#{attr(msg)}\"/>\n" <>
        "    </testcase>"
    end
  end

  defp count_failures(results) do
    Enum.reduce(results, 0, fn result, acc ->
      acc + count_result_failures(result)
    end)
  end

  defp count_result_failures(%CompatibilityResult{} = result) do
    tool_fails = Enum.count(result.tool_results, &(not &1.accepted))
    suite_fail = if result.accepted, do: 0, else: 1
    tool_fails + suite_fail
  end

  defp worst_message(%CompatibilityResult{omens: []}), do: "no diagnostics"

  defp worst_message(%CompatibilityResult{omens: omens}) do
    worst = Enum.max_by(omens, &Omen.severity_order(&1.severity))
    "#{worst.code}: #{worst.explanation}"
  end

  defp worst_tool_message(%{omens: []}), do: "no diagnostics"

  defp worst_tool_message(%{omens: omens}) do
    worst = Enum.max_by(omens, &Omen.severity_order(&1.severity))
    "#{worst.code}: #{worst.explanation}"
  end

  defp attr(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
