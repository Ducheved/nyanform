defmodule Nyanform.Schema.Scroll do
  @type kind ::
          :object
          | :array
          | :string
          | :integer
          | :number
          | :boolean
          | :null
          | :enum
          | :const
          | :union
          | :intersection
          | :ref
          | :any
          | :never
          | :unknown

  @type path :: [String.t()]

  @type t :: %__MODULE__{
          kind: kind(),
          path: path(),
          description: String.t() | nil,
          title: String.t() | nil,
          default: term() | :unset,
          examples: [term()] | nil,
          annotations: %{optional(String.t()) => term()} | nil,
          properties: %{optional(String.t()) => t()} | nil,
          required: [String.t()] | nil,
          pattern_properties: %{optional(String.t()) => t()} | nil,
          additional_properties: t() | false | nil,
          min_properties: non_neg_integer() | nil,
          max_properties: non_neg_integer() | nil,
          items: t() | nil,
          tuple_items: [t()] | nil,
          additional_items: t() | false | nil,
          min_items: non_neg_integer() | nil,
          max_items: non_neg_integer() | nil,
          unique_items: boolean() | nil,
          format: String.t() | nil,
          pattern: String.t() | nil,
          min_length: non_neg_integer() | nil,
          max_length: non_neg_integer() | nil,
          enum: [term()] | nil,
          const: term() | :unset,
          minimum: number() | nil,
          maximum: number() | nil,
          exclusive_minimum: number() | nil,
          exclusive_maximum: number() | nil,
          multiple_of: number() | nil,
          branches: [t()] | nil,
          ref_target: Nyanform.Schema.Reference.t() | nil,
          recursive: boolean() | nil,
          definitions: %{optional(String.t()) => t()} | nil,
          raw: term() | nil
        }

  defstruct kind: :any,
            path: [],
            description: nil,
            title: nil,
            default: :unset,
            examples: nil,
            annotations: nil,
            properties: nil,
            required: nil,
            pattern_properties: nil,
            additional_properties: nil,
            min_properties: nil,
            max_properties: nil,
            items: nil,
            tuple_items: nil,
            additional_items: nil,
            min_items: nil,
            max_items: nil,
            unique_items: nil,
            format: nil,
            pattern: nil,
            min_length: nil,
            max_length: nil,
            enum: nil,
            const: :unset,
            minimum: nil,
            maximum: nil,
            exclusive_minimum: nil,
            exclusive_maximum: nil,
            multiple_of: nil,
            branches: nil,
            ref_target: nil,
            recursive: nil,
            definitions: nil,
            raw: nil

  @spec any(path()) :: t()
  def any(path \\ []) do
    %__MODULE__{kind: :any, path: path}
  end

  @spec never(path()) :: t()
  def never(path \\ []) do
    %__MODULE__{kind: :never, path: path}
  end

  @spec object?(t()) :: boolean()
  def object?(%__MODULE__{kind: :object}), do: true
  def object?(%__MODULE__{}), do: false

  @spec ref?(t()) :: boolean()
  def ref?(%__MODULE__{kind: :ref}), do: true
  def ref?(%__MODULE__{}), do: false

  @spec primitive?(t()) :: boolean()
  def primitive?(%__MODULE__{kind: k}) when k in [:string, :integer, :number, :boolean, :null] do
    true
  end

  def primitive?(%__MODULE__{}), do: false
end
