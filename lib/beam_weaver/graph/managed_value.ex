defmodule BeamWeaver.Graph.ManagedValue do
  @moduledoc """
  Behaviour for runtime-projected graph state values.

  Managed values are visible to nodes but are not channels: they are read-only,
  not checkpointed, and not accepted as user writes.
  """

  alias BeamWeaver.Graph.Runtime

  @type t :: struct()

  @callback get(t(), Runtime.t()) :: term()
end
