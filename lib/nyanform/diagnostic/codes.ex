defmodule Nyanform.Diagnostic.Codes do
  @codes %{
    "NYA-SCHEMA-001" => %{
      category: :schema,
      severity: :rejected,
      summary: "schema failed structural validation"
    },
    "NYA-SCHEMA-002" => %{
      category: :schema,
      severity: :lossy,
      summary: "nullable type array normalized"
    },
    "NYA-SCHEMA-003" => %{
      category: :schema,
      severity: :lossy,
      summary: "additionalProperties: false dropped"
    },
    "NYA-SCHEMA-004" => %{
      category: :schema,
      severity: :lossy,
      summary: "empty enum dropped"
    },
    "NYA-SCHEMA-005" => %{
      category: :schema,
      severity: :rejected,
      summary: "mixed-type enum unsupported"
    },
    "NYA-SCHEMA-006" => %{
      category: :schema,
      severity: :rejected,
      summary: "tuple-style array unsupported"
    },
    "NYA-SCHEMA-007" => %{
      category: :schema,
      severity: :rejected,
      summary: "union unsupported by profile"
    },
    "NYA-SCHEMA-008" => %{
      category: :schema,
      severity: :rejected,
      summary: "contradictory intersection"
    },
    "NYA-SCHEMA-009" => %{
      category: :schema,
      severity: :rejected,
      summary: "array without items unsupported"
    },
    "NYA-SCHEMA-010" => %{
      category: :schema,
      severity: :rejected,
      summary: "schema depth exceeded"
    },
    "NYA-SCHEMA-011" => %{
      category: :schema,
      severity: :rejected,
      summary: "reference cycle detected"
    },
    "NYA-PROFILE-001" => %{
      category: :profile,
      severity: :normalized,
      summary: "all properties marked required"
    },
    "NYA-PROFILE-002" => %{
      category: :profile,
      severity: :normalized,
      summary: "number type preserved without integer distinction"
    },
    "NYA-PROFILE-003" => %{
      category: :profile,
      severity: :lossy,
      summary: "format keyword dropped"
    },
    "NYA-PROFILE-004" => %{
      category: :profile,
      severity: :rejected,
      summary: "reference unsupported by profile"
    },
    "NYA-PROFILE-005" => %{
      category: :profile,
      severity: :lossy,
      summary: "pattern properties dropped"
    },
    "NYA-PROFILE-006" => %{
      category: :profile,
      severity: :rejected,
      summary: "const unsupported by profile"
    },
    "NYA-PROFILE-007" => %{
      category: :profile,
      severity: :normalized,
      summary: "description truncated"
    },
    "NYA-ALIAS-001" => %{
      category: :alias,
      severity: :normalized,
      summary: "tool name sanitized"
    },
    "NYA-ALIAS-002" => %{
      category: :alias,
      severity: :normalized,
      summary: "collision suffix added"
    },
    "NYA-ALIAS-003" => %{
      category: :alias,
      severity: :rejected,
      summary: "ambiguous alias mapping"
    },
    "NYA-TRANSPORT-001" => %{
      category: :transport,
      severity: :rejected,
      summary: "message size exceeded"
    },
    "NYA-TRANSPORT-002" => %{
      category: :transport,
      severity: :rejected,
      summary: "malformed JSON-RPC frame"
    },
    "NYA-TRANSPORT-003" => %{
      category: :transport,
      severity: :rejected,
      summary: "request timeout"
    },
    "NYA-TRANSPORT-004" => %{
      category: :transport,
      severity: :rejected,
      summary: "upstream process failure"
    },
    "NYA-TRANSPORT-005" => %{
      category: :transport,
      severity: :normalized,
      summary: "stdout protocol purity enforced"
    },
    "NYA-TRANSPORT-006" => %{
      category: :transport,
      severity: :rejected,
      summary: "session isolation violation"
    },
    "NYA-ARG-001" => %{
      category: :argument,
      severity: :normalized,
      summary: "JSON string argument repaired to object"
    },
    "NYA-ARG-002" => %{
      category: :argument,
      severity: :normalized,
      summary: "JSON string argument repaired to array"
    },
    "NYA-ARG-003" => %{
      category: :argument,
      severity: :rejected,
      summary: "argument repair rejected"
    },
    "NYA-CONFIG-001" => %{
      category: :config,
      severity: :rejected,
      summary: "invalid configuration"
    },
    "NYA-CONFIG-002" => %{
      category: :config,
      severity: :rejected,
      summary: "unknown profile"
    },
    "NYA-CONFIG-003" => %{
      category: :config,
      severity: :rejected,
      summary: "profile validation failed"
    }
  }

  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(code) do
    Map.fetch(@codes, code)
  end

  @spec all() :: %{String.t() => map()}
  def all, do: @codes

  @spec categories() :: [atom()]
  def categories do
    @codes
    |> Map.values()
    |> Enum.map(& &1.category)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
