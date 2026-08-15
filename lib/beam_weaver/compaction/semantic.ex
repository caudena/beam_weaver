defmodule BeamWeaver.Compaction.Semantic do
  @moduledoc """
  Structured, source-linked continuation state produced by portable compaction.

  The value has a closed schema for objectives, user requests, constraints,
  decisions, progress, critical context, errors, artifact references, and
  source coverage. Construction validates shape; the compaction engine also
  validates exact coverage, cited source IDs, direct-user excerpts, uniqueness,
  and the configured byte limit before returning a checkpoint.
  """

  alias BeamWeaver.Compaction.{Fields, Validator}
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
  @field_names Map.new(@fields, &{Atom.to_string(&1), &1})

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{}

  @doc "Builds and shape-validates a closed semantic value."
  @spec new(map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = semantic), do: Validator.validate_shape(semantic)

  def new(%{} = attrs) do
    with {:ok, attrs} <- Fields.normalize(attrs, @field_names) do
      case Map.keys(attrs) -- @fields do
        [] ->
          {:ok, struct!(__MODULE__, attrs)}
          |> then(fn {:ok, semantic} -> Validator.validate_shape(semantic) end)

        unknown ->
          {:error, Error.new(:invalid_compaction_semantic, "unknown semantic fields", %{fields: unknown})}
      end
    else
      {:error, :duplicate_field} ->
        {:error, Error.new(:invalid_compaction_semantic, "semantic output has duplicate fields")}
    end
  rescue
    _error -> {:error, Error.new(:invalid_compaction_semantic, "required semantic fields are missing")}
  end

  def new(_attrs), do: {:error, Error.new(:invalid_compaction_semantic, "semantic output must be a map")}

  @doc "Converts semantic continuation state to its plain map representation."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = semantic), do: Map.from_struct(semantic)
end
