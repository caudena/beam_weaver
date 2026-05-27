defmodule BeamWeaver.Graph.StateSnapshot do
  @moduledoc """
  Internal state snapshot representation.

  Public graph state APIs continue to return map-compatible snapshots. This
  struct gives checkpoint/state code a typed shape to evolve toward without
  breaking callers.
  """

  defstruct [
    :values,
    :channel_versions,
    :versions_seen,
    :updated_channels,
    :next,
    :next_tasks,
    :config,
    :metadata,
    :created_at,
    :parent_config,
    :tasks,
    :interrupts,
    :pending_writes,
    :pending_write_records,
    :pending_write_paths
  ]

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: t()
  def from_map(map), do: struct(__MODULE__, map)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot), do: Map.from_struct(snapshot)
end
