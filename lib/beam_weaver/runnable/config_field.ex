defmodule BeamWeaver.Runnable.ConfigField do
  @moduledoc """
  Declares a runtime-configurable field.
  """

  defstruct [:id, :field, :name, :description, default: nil, required: false]

  def new(field, opts \\ []) do
    %__MODULE__{
      id: to_string(Keyword.get(opts, :id, field)),
      field: field,
      name: Keyword.get(opts, :name),
      description: Keyword.get(opts, :description),
      default: Keyword.get(opts, :default),
      required: Keyword.get(opts, :required, false)
    }
  end
end

defmodule BeamWeaver.Runnable.ConfigSpec do
  @moduledoc false

  defstruct [:id, :field, :name, :description, :default, required: false]

  def from_field(%BeamWeaver.Runnable.ConfigField{} = field) do
    %__MODULE__{
      id: field.id,
      field: field.field,
      name: field.name,
      description: field.description,
      default: field.default,
      required: field.required
    }
  end
end
