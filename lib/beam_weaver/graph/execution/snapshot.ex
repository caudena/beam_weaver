defmodule BeamWeaver.Graph.Execution.Snapshot do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelState
  alias BeamWeaver.Graph.Execution.DeltaReplay
  alias BeamWeaver.Graph.Execution.Replay

  @spec from_tuple(map()) :: map()
  def from_tuple(tuple) do
    checkpoint = tuple.checkpoint
    pending_writes = Map.get(tuple, :pending_writes, [])

    %{
      values: Map.get(checkpoint, "channel_values", Map.get(checkpoint, :channel_values, %{})),
      channel_versions: Map.get(checkpoint, "channel_versions", Map.get(checkpoint, :channel_versions, %{})),
      versions_seen: Map.get(checkpoint, "versions_seen", Map.get(checkpoint, :versions_seen, %{})),
      updated_channels: Map.get(checkpoint, "updated_channels", Map.get(checkpoint, :updated_channels, [])),
      next: Map.get(checkpoint, "next", Map.get(checkpoint, :next, [])),
      next_tasks: Map.get(checkpoint, "next_tasks", Map.get(checkpoint, :next_tasks, [])),
      config: tuple.config,
      metadata: tuple.metadata,
      created_at: Map.get(checkpoint, "ts"),
      parent_config: Map.get(tuple, :parent_config),
      tasks: Map.get(checkpoint, "tasks", Map.get(checkpoint, :tasks, [])),
      interrupts:
        Map.get(checkpoint, "interrupts", Map.get(checkpoint, :interrupts, [])) ++
          pending_interrupts(pending_writes),
      pending_writes: pending_writes,
      pending_write_records: Map.get(tuple, :pending_write_records, []),
      pending_write_paths: Map.get(tuple, :pending_write_paths, [])
    }
  end

  @spec from_tuple(map(), map(), keyword()) :: map()
  def from_tuple(compiled, tuple, opts) do
    snapshot = from_tuple(tuple)

    snapshot = %{
      snapshot
      | values:
          compiled.graph
          |> ChannelState.public_state(DeltaReplay.restore_channel_values(compiled, tuple, snapshot.values))
    }

    if Keyword.get(opts, :apply_pending?, false) and snapshot.pending_writes != [] do
      restored = Execution.checkpoint_state(tuple)

      ready =
        Replay.initial_ready(
          compiled,
          snapshot.config,
          restored,
          Replay.replay_pending?(restored)
        )

      %{
        snapshot
        | values:
            compiled.graph
            |> ChannelState.public_state(
              ChannelState.apply_pending_writes(
                snapshot.values,
                snapshot.pending_writes,
                compiled.graph
              )
            ),
          next: Replay.ready_names(ready),
          next_tasks: Replay.checkpoint_next_records(ready, compiled.graph)
      }
    else
      snapshot
    end
  end

  @spec latest_state?(map()) :: boolean()
  def latest_state?(config) do
    config
    |> Checkpoint.configurable()
    |> Map.get("checkpoint_id")
    |> is_nil()
  end

  defp pending_interrupts(pending_writes) do
    Enum.flat_map(pending_writes, fn
      {_task_id, "__interrupt__", value} -> List.wrap(value)
      _other -> []
    end)
  end
end
