defmodule Nyanform.Report.Sarif do
  alias Nyanform.Diagnostic.{Codes, Omen}

  @spec render_matrix([Nyanform.Report.CompatibilityResult.t()]) :: String.t()
  def render_matrix(results) do
    all_omens =
      results
      |> Enum.flat_map(fn result ->
        profile_omens = Enum.map(result.omens, &Map.put(&1, :profile, result.profile))
        tool_omens = collect_tool_omens(result.tool_results, result.profile)
        profile_omens ++ tool_omens
      end)

    rules = build_rules(all_omens)
    results_array = Enum.map(all_omens, &omen_to_sarif_result/1)

    sarif = %{
      "$schema" =>
        "https://docs.oasis-open.org/sarif/sarif/v2.1.0/cs01/schemas/sarif-schema-2.1.0.json",
      "version" => "2.1.0",
      "runs" => [
        %{
          "tool" => %{
            "driver" => %{
              "name" => "Nyanform",
              "version" => "0.1.0",
              "informationUri" => "https://github.com/Ducheved/nyanform",
              "rules" => rules
            }
          },
          "results" => results_array
        }
      ]
    }

    Jason.encode!(sarif, pretty: true)
  end

  defp collect_tool_omens(tool_results, profile) do
    Enum.flat_map(tool_results, fn tr ->
      Enum.map(tr.omens, fn omen ->
        omen
        |> Map.put(:tool, tr.tool)
        |> Map.put(:profile, profile)
      end)
    end)
  end

  defp build_rules(omens) do
    omens
    |> Enum.map(& &1.code)
    |> Enum.uniq()
    |> Enum.map(fn code ->
      case Codes.fetch(code) do
        {:ok, info} ->
          %{
            "id" => code,
            "name" => code,
            "shortDescription" => %{"text" => info.summary},
            "defaultConfiguration" => %{"level" => severity_to_level(info.severity)}
          }

        :error ->
          %{
            "id" => code,
            "name" => code,
            "shortDescription" => %{"text" => "unknown diagnostic"}
          }
      end
    end)
  end

  defp omen_to_sarif_result(%Omen{} = omen) do
    %{
      "ruleId" => omen.code,
      "level" => severity_to_level(omen.severity),
      "message" => %{"text" => omen.explanation},
      "locations" => [
        %{
          "physicalLocation" => %{
            "artifactLocation" => %{"uri" => "schema://root"},
            "region" => %{
              "snippet" => %{"text" => Enum.join(omen.schema_path, "/")}
            }
          }
        }
      ]
    }
  end

  defp severity_to_level(:exact), do: "none"
  defp severity_to_level(:normalized), do: "note"
  defp severity_to_level(:lossy), do: "warning"
  defp severity_to_level(:rejected), do: "error"
  defp severity_to_level(_), do: "note"
end
