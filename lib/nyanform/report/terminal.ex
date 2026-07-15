defmodule Nyanform.Report.Terminal do
  alias Nyanform.Diagnostic.Omen
  alias Nyanform.Report.{CompatibilityResult, Table}

  @spec render_inspect(map()) :: String.t()
  def render_inspect(report) do
    lines = []

    lines = lines ++ ["Nyanform Inspect Report", String.duplicate("=", 40), ""]

    lines =
      lines ++
        [
          format_kv("Server", server_name(report)),
          format_kv("Protocol", Map.get(report, :protocol_revision, "unknown")),
          format_kv("Tools", Integer.to_string(Map.get(report, :tool_count, 0))),
          format_kv("Valid", boolean_label(Map.get(report, :schema_valid, true))),
          ""
        ]

    omens = Map.get(report, :omens, [])

    lines =
      if omens == [] do
        lines ++ ["No diagnostics.", ""]
      else
        lines ++
          ["Diagnostics:", render_omen_table(omens), ""]
      end

    unsupported = Map.get(report, :unsupported_constructs, [])

    lines =
      if unsupported == [] do
        lines
      else
        lines ++ ["Unsupported constructs:", render_list(unsupported), ""]
      end

    rejected = Map.get(report, :rejected_tools, [])

    lines =
      if rejected == [] do
        lines
      else
        lines ++ ["Rejected tools:", render_list(rejected), ""]
      end

    duration = Map.get(report, :duration_us, 0)
    lines = lines ++ [format_kv("Duration", format_duration(duration))]

    Enum.join(lines, "\n")
  end

  @spec render_matrix([CompatibilityResult.t()]) :: String.t()
  def render_matrix(results) do
    headers = ["Profile", "Policy", "Tools", "Accepted", "Worst", "Omens", "Duration"]

    rows =
      Enum.map(results, fn result ->
        tool_count = length(result.tool_results)
        omen_count = length(result.omens) + count_tool_omens(result.tool_results)

        [
          result.profile,
          Atom.to_string(result.policy),
          Integer.to_string(tool_count),
          boolean_label(result.accepted),
          severity_label(result.worst_severity),
          Integer.to_string(omen_count),
          format_duration(result.duration_us)
        ]
      end)

    Table.render(headers, rows)
  end

  defp render_omen_table(omens) do
    headers = ["Code", "Severity", "Rule", "Path", "Explanation"]
    rows = Enum.map(omens, &omen_to_row/1)
    Table.render(headers, rows)
  end

  defp omen_to_row(%Omen{} = omen) do
    [
      omen.code,
      severity_label(omen.severity),
      omen.rule || "",
      Enum.join(omen.schema_path, "."),
      truncate(omen.explanation, 50)
    ]
  end

  defp render_list(items) do
    items
    |> Enum.map_join("\n", &"  - #{&1}")
  end

  defp format_kv(key, value) do
    String.pad_trailing(key <> ":", 16) <> to_string(value || "unknown")
  end

  defp boolean_label(true), do: "yes"
  defp boolean_label(false), do: "no"

  defp severity_label(nil), do: "-"
  defp severity_label(:exact), do: "exact"
  defp severity_label(:normalized), do: "normalized"
  defp severity_label(:lossy), do: "lossy"
  defp severity_label(:rejected), do: "rejected"

  defp truncate(string, max) when is_binary(string) do
    if String.length(string) > max do
      String.slice(string, 0, max - 1) <> "…"
    else
      string
    end
  end

  defp truncate(nil, _), do: ""

  defp format_duration(us) when is_integer(us) do
    cond do
      us >= 1_000_000 -> :erlang.float_to_binary(us / 1_000_000, decimals: 2) <> "s"
      us >= 1_000 -> :erlang.float_to_binary(us / 1_000, decimals: 1) <> "ms"
      true -> Integer.to_string(us) <> "µs"
    end
  end

  defp count_tool_omens(tool_results) do
    Enum.reduce(tool_results, 0, fn tr, acc -> acc + length(tr.omens) end)
  end

  defp server_name(report) do
    case Map.get(report, :server_info) do
      %{"name" => name} when is_binary(name) -> name
      %{name: name} when is_binary(name) -> name
      _ -> "unknown"
    end
  end
end

defmodule Nyanform.Report.Table do
  @spec render([String.t()], [[String.t()]]) :: String.t()
  def render(headers, rows) do
    all_rows = [headers | rows]
    widths = column_widths(all_rows)

    formatted =
      Enum.map(all_rows, fn row ->
        cells =
          row
          |> Enum.with_index()
          |> Enum.map(fn {cell, index} ->
            String.pad_trailing(to_string(cell), Enum.at(widths, index, 0) + 2)
          end)

        Enum.join(cells)
      end)

    separator = String.duplicate("-", Enum.sum(widths) + length(widths) * 2)

    {header_line, rest} = List.pop_at(formatted, 0)

    Enum.join([header_line, separator | rest], "\n")
  end

  defp column_widths(rows) do
    rows
    |> Enum.zip()
    |> Enum.map(fn column ->
      column
      |> Tuple.to_list()
      |> Enum.map(fn cell -> String.length(to_string(cell)) end)
      |> Enum.max()
    end)
  end
end
