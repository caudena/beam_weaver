defmodule BeamWeaver.Graph.EdgeSpec do
  @moduledoc false

  defstruct [:source, :target, metadata: %{}]
end

defmodule BeamWeaver.Graph.GuardedEdgeSpec do
  @moduledoc false

  defstruct [
    :id,
    :source,
    :target,
    :match,
    max_runs: nil,
    default?: false,
    metadata: %{}
  ]
end

defmodule BeamWeaver.Graph.BranchSpec do
  @moduledoc false

  defstruct [:source, :router, path_map: %{}, then: nil, metadata: %{}]
end

defmodule BeamWeaver.Graph.WaitingEdgeSpec do
  @moduledoc false

  defstruct [:id, :channel, upstream: [], target: nil, metadata: %{}]
end
