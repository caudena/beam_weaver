defmodule BeamWeaver.Checkpoint.Metadata do
  @moduledoc """
  Typed checkpoint metadata used at adapter/runtime boundaries.
  """

  alias BeamWeaver.MapAccess

  defstruct source: nil,
            step: nil,
            writes: %{},
            parents: %{},
            thread: %{},
            run_id: nil,
            extra: %{}

  @type t :: %__MODULE__{}

  @fields [:source, :step, :writes, :parents, :thread, :run_id]

  @spec from_map(map()) :: t()
  def from_map(metadata) when is_map(metadata) do
    %__MODULE__{
      source: MapAccess.get(metadata, :source),
      step: MapAccess.get(metadata, :step),
      writes: MapAccess.get(metadata, :writes, %{}),
      parents: MapAccess.get(metadata, :parents, %{}),
      thread: MapAccess.get(metadata, :thread, %{}),
      run_id: MapAccess.get(metadata, :run_id),
      extra: Map.drop(metadata, @fields ++ Enum.map(@fields, &Atom.to_string/1))
    }
  end
end

defmodule BeamWeaver.Checkpoint.Record do
  @moduledoc """
  Typed checkpoint tuple projection.

  Projects saver tuple maps into named fields for application inspection,
  exporters and adapter implementations. It does not write or activate a
  checkpoint; use BeamWeaver.Checkpoint for storage operations.
  """

  alias BeamWeaver.Checkpoint.Metadata
  alias BeamWeaver.MapAccess

  defstruct [
    :config,
    :checkpoint,
    :metadata,
    :parent_config,
    :version,
    :id,
    :timestamp,
    :source,
    :step,
    :writes,
    :parents,
    pending_sends: [],
    tasks: [],
    pending_writes: [],
    pending_write_records: [],
    pending_write_paths: [],
    namespace: []
  ]

  @type t :: %__MODULE__{}

  @spec from_tuple(map()) :: t()
  def from_tuple(tuple) do
    checkpoint = tuple.checkpoint || %{}
    metadata = Metadata.from_map(tuple.metadata || %{})
    config = tuple.config || %{}

    %__MODULE__{
      config: config,
      checkpoint: checkpoint,
      metadata: metadata,
      parent_config: Map.get(tuple, :parent_config),
      version: MapAccess.get(checkpoint, :v),
      id: MapAccess.get(checkpoint, :id),
      timestamp: MapAccess.get(checkpoint, :ts),
      source: metadata.source,
      step: metadata.step,
      writes: metadata.writes,
      parents: metadata.parents,
      pending_sends: MapAccess.get(checkpoint, :pending_sends, []),
      tasks: MapAccess.get(checkpoint, :tasks, []),
      pending_writes: Map.get(tuple, :pending_writes, []),
      pending_write_records: Map.get(tuple, :pending_write_records, []),
      pending_write_paths: Map.get(tuple, :pending_write_paths, []),
      namespace: namespace(config)
    }
  end

  defp namespace(config) do
    config
    |> Map.get("configurable", Map.get(config, :configurable, %{}))
    |> Map.get("checkpoint_ns", "")
    |> case do
      "" -> []
      value when is_binary(value) -> String.split(value, ":", trim: true)
      value when is_list(value) -> value
      value -> [value]
    end
  end
end
