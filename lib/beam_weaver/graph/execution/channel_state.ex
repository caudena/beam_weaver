defmodule BeamWeaver.Graph.Execution.ChannelState do
  @moduledoc """
  Compatibility facade for graph channel state helpers.

  Runtime code is being moved to smaller internal modules so merge,
  checkpoint projection, and lookup can evolve independently.
  """

  alias BeamWeaver.Graph.Execution.ChannelCheckpoint
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.ChannelMerge

  @doc false
  defdelegate merge_update(state, update, graph_or_reducers), to: ChannelMerge

  @doc false
  defdelegate merge_update_result(state, update, graph_or_reducers), to: ChannelMerge

  @doc false
  defdelegate apply_pending_writes(state, pending_writes, graph), to: ChannelMerge

  @doc false
  defdelegate merge_step_updates(state, updates, graph_or_reducers), to: ChannelMerge

  @doc false
  defdelegate ready_state(ready, state, graph), to: ChannelMerge

  @doc false
  defdelegate checkpoint_channel_values(graph, state), to: ChannelCheckpoint

  @doc false
  defdelegate checkpoint_snapshot_values(graph, state, channels_to_snapshot),
    to: ChannelCheckpoint

  @doc false
  defdelegate checkpoint_channel_deltas(graph, state), to: ChannelCheckpoint

  @doc false
  defdelegate channel_for(graph, key), to: ChannelLookup

  @doc false
  defdelegate public_state(graph, state), to: ChannelLookup

  @doc false
  defdelegate persisted_update(graph, update), to: ChannelLookup
end
