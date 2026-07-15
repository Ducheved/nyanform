defmodule Nyanform.Schema.ValidationError do
  @type code ::
          :schema_depth_exceeded
          | :invalid_schema_node
          | :invalid_type
          | :invalid_keyword_value
          | :invalid_enum
          | :missing_branches
          | :invalid_branches
          | :invalid_property_map
          | :invalid_required
          | :invalid_additional_properties
          | :reference_cycle
          | :reference_resolution_failed
          | :reference_depth_exceeded
          | :idempotency_violation

  @type t :: %__MODULE__{
          code: code(),
          path: Nyanform.Schema.Scroll.path()
        }

  defstruct [:code, :path]
end
