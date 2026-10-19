defmodule BeamWeaver.Graph.GuardedEdgeSpec do
  @moduledoc false

  defstruct [:id, :source, :target, :match, max_runs: nil, default?: false]
end

defmodule BeamWeaver.Graph.BranchSpec do
  @moduledoc false

  defstruct [:source, :router, path_map: %{}]
end

defmodule BeamWeaver.Graph.WaitingEdgeSpec do
  @moduledoc false

  defstruct [:id, :channel, upstream: [], target: nil, metadata: %{}]
end
