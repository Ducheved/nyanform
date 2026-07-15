defmodule Nyanform.Report.Renderer do
  alias Nyanform.Report.{Json, JUnit, Sarif, Terminal}

  @type format :: :terminal | :json | :junit | :sarif

  @spec inspect_report(map(), format()) :: String.t()
  def inspect_report(report, :terminal), do: Terminal.render_inspect(report)
  def inspect_report(report, :json), do: Json.render_inspect(report)

  @spec matrix_report([Nyanform.Report.CompatibilityResult.t()], format()) :: String.t()
  def matrix_report(results, :terminal), do: Terminal.render_matrix(results)
  def matrix_report(results, :json), do: Json.render_matrix(results)
  def matrix_report(results, :junit), do: JUnit.render_matrix(results)
  def matrix_report(results, :sarif), do: Sarif.render_matrix(results)

  @spec parse_inspect_format(String.t()) :: {:ok, :terminal | :json} | {:error, String.t()}
  def parse_inspect_format("terminal"), do: {:ok, :terminal}
  def parse_inspect_format("json"), do: {:ok, :json}
  def parse_inspect_format(other), do: {:error, "unknown inspect format: #{other}"}

  @spec parse_format(String.t()) :: {:ok, format()} | {:error, String.t()}
  def parse_format("terminal"), do: {:ok, :terminal}
  def parse_format("json"), do: {:ok, :json}
  def parse_format("junit"), do: {:ok, :junit}
  def parse_format("sarif"), do: {:ok, :sarif}
  def parse_format(other), do: {:error, "unknown format: #{other}"}
end
