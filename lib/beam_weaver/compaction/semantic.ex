defmodule BeamWeaver.Compaction.Semantic do
  @moduledoc "Structured, source-linked continuation state produced by portable compaction."

  alias BeamWeaver.Compaction.Validator
  alias BeamWeaver.Core.Error

  @fields [
    :version,
    :objective,
    :user_requests,
    :constraints,
    :decisions,
    :progress,
    :critical_context,
    :errors,
    :artifact_refs,
    :coverage
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @spec new(map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = semantic), do: Validator.validate_shape(semantic)

  def new(%{} = attrs) do
    attrs = normalize_keys(attrs)
    unknown = Map.keys(attrs) -- @fields

    cond do
      unknown != [] ->
        {:error, Error.new(:invalid_compaction_semantic, "unknown semantic fields", %{fields: unknown})}

      true ->
        {:ok, struct!(__MODULE__, attrs)}
        |> then(fn {:ok, semantic} -> Validator.validate_shape(semantic) end)
    end
  rescue
    _error -> {:error, Error.new(:invalid_compaction_semantic, "required semantic fields are missing")}
  end

  def new(_attrs), do: {:error, Error.new(:invalid_compaction_semantic, "semantic output must be a map")}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = semantic), do: Map.from_struct(semantic)

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) ->
        atom = Enum.find(@fields, &(Atom.to_string(&1) == key))
        {atom || key, value}

      pair ->
        pair
    end)
  end
end
