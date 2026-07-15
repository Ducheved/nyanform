defmodule Nyanform.Diagnostic.Omen do
  @type severity :: :exact | :normalized | :lossy | :rejected

  @type t :: %__MODULE__{
          code: String.t(),
          severity: severity(),
          schema_path: Nyanform.Schema.Scroll.path(),
          rule: String.t(),
          source: String.t() | nil,
          target: String.t() | nil,
          semantics_preserved: boolean(),
          explanation: String.t(),
          action: String.t() | nil,
          tool: String.t() | nil,
          profile: String.t() | nil
        }

  defstruct [
    :code,
    :severity,
    schema_path: [],
    rule: nil,
    source: nil,
    target: nil,
    semantics_preserved: true,
    explanation: "",
    action: nil,
    tool: nil,
    profile: nil
  ]

  @spec exact(String.t(), keyword()) :: t()
  def exact(code, opts) do
    struct(%__MODULE__{code: code, severity: :exact, semantics_preserved: true}, opts)
  end

  @spec normalized(String.t(), keyword()) :: t()
  def normalized(code, opts) do
    struct(%__MODULE__{code: code, severity: :normalized, semantics_preserved: true}, opts)
  end

  @spec lossy(String.t(), keyword()) :: t()
  def lossy(code, opts) do
    struct(%__MODULE__{code: code, severity: :lossy, semantics_preserved: false}, opts)
  end

  @spec rejected(String.t(), keyword()) :: t()
  def rejected(code, opts) do
    struct(%__MODULE__{code: code, severity: :rejected, semantics_preserved: false}, opts)
  end

  @spec severity_order(severity()) :: non_neg_integer()
  def severity_order(:exact), do: 0
  def severity_order(:normalized), do: 1
  def severity_order(:lossy), do: 2
  def severity_order(:rejected), do: 3

  @spec worst([t()]) :: severity() | nil
  def worst([]), do: nil
  def worst(omens), do: Enum.max_by(omens, &severity_order(&1.severity)).severity
end
