defmodule Nyanform.Report.CompatibilityResult do
  alias Nyanform.Diagnostic.Omen

  @type t :: %__MODULE__{
          profile: String.t(),
          policy: :strict | :compatible | :permissive,
          tool_results: [tool_result()],
          accepted: boolean(),
          worst_severity: Omen.severity() | nil,
          omens: [Omen.t()],
          duration_us: non_neg_integer()
        }

  @type tool_result :: %{
          tool: String.t(),
          alias: String.t() | nil,
          accepted: boolean(),
          worst_severity: Omen.severity() | nil,
          omens: [Omen.t()],
          digest: String.t() | nil
        }

  defstruct [
    :profile,
    :policy,
    tool_results: [],
    accepted: true,
    worst_severity: nil,
    omens: [],
    duration_us: 0
  ]

  @spec aggregate([tool_result()], Omen.severity() | nil) :: {boolean(), Omen.severity() | nil}
  def aggregate(tool_results, profile_worst) do
    accepted = Enum.all?(tool_results, & &1.accepted)

    severities =
      Enum.filter([profile_worst | Enum.map(tool_results, & &1.worst_severity)], &(&1 != nil))

    worst = if severities == [], do: nil, else: Enum.max_by(severities, &Omen.severity_order/1)
    {accepted, worst}
  end
end
