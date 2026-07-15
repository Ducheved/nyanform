defmodule Nyanform.Profile.Constellation do
  @type nullable_form :: :type_array | :nullable_keyword | :union_null | :unsupported

  @type t :: %__MODULE__{
          name: String.t(),
          label: String.t(),
          description: String.t(),
          accepted_keywords: MapSet.t(String.t()),
          supported_combinators: MapSet.t(:oneOf | :anyOf | :allOf),
          reference_support: :full | :local_only | :none,
          nullable_representation: nullable_form(),
          requires_all_properties_required: boolean(),
          accepts_additional_properties: boolean(),
          supports_additional_properties_false: boolean(),
          supported_array_forms: MapSet.t(:homogeneous | :tuple | :no_items),
          supported_enum_forms: MapSet.t(:homogeneous | :mixed | :empty),
          max_schema_depth: pos_integer() | :unlimited,
          tool_name_pattern: String.t(),
          max_tool_name_length: pos_integer() | :unlimited,
          max_description_length: pos_integer() | :unlimited,
          integer_vs_number_distinguished: boolean(),
          supports_const: boolean(),
          supports_pattern_properties: boolean(),
          vendor_extension_prefixes: [String.t()]
        }

  defstruct [
    :name,
    :label,
    :description,
    accepted_keywords: MapSet.new(),
    supported_combinators: MapSet.new(),
    reference_support: :none,
    nullable_representation: :type_array,
    requires_all_properties_required: false,
    accepts_additional_properties: true,
    supports_additional_properties_false: true,
    supported_array_forms: MapSet.new([:homogeneous, :tuple, :no_items]),
    supported_enum_forms: MapSet.new([:homogeneous, :mixed, :empty]),
    max_schema_depth: :unlimited,
    tool_name_pattern: "^[a-zA-Z0-9_-]+$",
    max_tool_name_length: :unlimited,
    max_description_length: :unlimited,
    integer_vs_number_distinguished: true,
    supports_const: true,
    supports_pattern_properties: true,
    vendor_extension_prefixes: []
  ]
end
