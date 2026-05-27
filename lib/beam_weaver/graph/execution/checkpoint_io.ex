defmodule BeamWeaver.Graph.Execution.CheckpointIO do
  @moduledoc """
  Checkpoint I/O and checkpoint write helpers for compiled graphs.
  """

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelState
  alias BeamWeaver.Graph.Execution.Replay
  alias BeamWeaver.Graph.Execution.TaskWrite

  @spec get_tuple(struct() | nil, map()) :: map() | nil
  def get_tuple(nil, _config), do: nil
  def get_tuple(checkpointer, config), do: Checkpoint.get_tuple(checkpointer, config)

  @spec list(struct() | nil, map(), keyword()) :: [map()]
  def list(nil, _config, _opts), do: []
  def list(checkpointer, config, opts), do: Checkpoint.list(checkpointer, config, opts)

  @spec put(struct() | nil, map(), map(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def put(nil, config, _checkpoint, _metadata, _channel_versions), do: {:ok, config}

  def put(checkpointer, config, checkpoint, metadata, channel_versions) do
    case Checkpoint.put(checkpointer, config, checkpoint, metadata, channel_versions) do
      {:ok, config} ->
        {:ok, config}

      {:error, reason} ->
        {:error, Error.new(:checkpoint_error, "checkpoint write failed", %{reason: inspect(reason)})}
    end
  end

  @spec put_writes(struct() | nil, map(), list(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  def put_writes(nil, _config, _writes, _task_id, _path), do: :ok

  def put_writes(checkpointer, config, writes, task_id, path) do
    case Checkpoint.put_writes(checkpointer, config, writes, task_id, path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(:checkpoint_error, "pending write persistence failed", %{
           reason: inspect(reason)
         })}
    end
  end

  @spec maybe_write_input_checkpoint(map(), map(), map(), boolean(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def maybe_write_input_checkpoint(%{checkpointer: nil}, config, _state, true, _metadata),
    do: {:ok, config}

  def maybe_write_input_checkpoint(
        %{checkpointer: checkpointer},
        config,
        _state,
        true,
        _metadata
      ) do
    case get_tuple(checkpointer, config) do
      %{config: checkpoint_config} -> {:ok, merge_checkpoint_map(checkpoint_config, config)}
      _missing -> {:ok, config}
    end
  end

  def maybe_write_input_checkpoint(compiled, config, state, false, metadata) do
    metadata = %{metadata | next: metadata.next || compiled.graph.entry_points}
    maybe_write_checkpoint(compiled, config, state, metadata)
  end

  @spec maybe_write_checkpoint(map(), map(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def maybe_write_checkpoint(%{checkpointer: nil}, config, _state, _metadata),
    do: {:ok, config}

  def maybe_write_checkpoint(%{} = compiled, config, state, metadata) do
    write_checkpoint(compiled, config, state, metadata)
  end

  @spec write_checkpoint(map(), map(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def write_checkpoint(%{checkpointer: nil}, config, _state, _metadata), do: {:ok, config}

  def write_checkpoint(%{checkpointer: checkpointer} = compiled, config, state, metadata) do
    updated_channels = metadata_value(metadata, :updated_channels, Map.keys(state))
    channel_versions = metadata_value(metadata, :channel_versions, %{})
    versions_seen = metadata_value(metadata, :versions_seen, %{})
    parent_tuple = get_tuple(checkpointer, config)
    {counters, snapshot_channels} = delta_snapshot_state(compiled.graph, parent_tuple, metadata)

    channel_values =
      compiled.graph
      |> ChannelState.checkpoint_channel_values(state)
      |> Map.merge(ChannelState.checkpoint_snapshot_values(compiled.graph, state, snapshot_channels))

    step_update = metadata_value(metadata, :step_update, %{})
    channel_deltas = ChannelState.checkpoint_channel_deltas(compiled.graph, step_update)
    metadata = Map.put(metadata, :counters_since_delta_snapshot, counters)

    checkpoint = %{
      "v" => 1,
      "channel_values" => channel_values,
      "channel_deltas" => channel_deltas,
      "channel_versions" => channel_versions,
      "versions_seen" => versions_seen,
      "updated_channels" => Execution.normalize_channels(updated_channels),
      "next" => metadata_value(metadata, :next, []),
      "next_tasks" => metadata_value(metadata, :next_tasks, []),
      "tasks" => metadata_value(metadata, :tasks, []),
      "interrupts" => metadata_value(metadata, :interrupts, [])
    }

    put(checkpointer, config, checkpoint, metadata, channel_versions)
  end

  @spec persist_pending_writes(map(), list()) :: :ok | {:error, Error.t()}
  def persist_pending_writes(_run, []), do: :ok
  def persist_pending_writes(%{compiled: %{checkpointer: nil}}, _pending_writes), do: :ok

  def persist_pending_writes(run, pending_writes) do
    pending_writes
    |> Enum.filter(&persisted_pending_write?(run.compiled.graph, &1))
    |> Enum.group_by(
      fn
        %TaskWrite{task_id: task_id, path: path} -> {task_id, path || ""}
        {task_id, _channel, _value, path} -> {task_id, path || ""}
        {task_id, _channel, _value} -> {task_id, ""}
      end,
      fn
        %TaskWrite{channel: channel, value: value} -> {channel, value}
        {_task_id, channel, value, _path} -> {channel, value}
        {_task_id, channel, value} -> {channel, value}
      end
    )
    |> Enum.reduce_while(:ok, fn {{task_id, path}, writes}, :ok ->
      case put_writes(run.compiled.checkpointer, run.config, writes, task_id, path) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp persisted_pending_write?(_graph, %TaskWrite{channel: channel})
       when channel in ["__interrupt__", "__error__"],
       do: true

  defp persisted_pending_write?(graph, %TaskWrite{channel: channel}) do
    ChannelState.persisted_update(graph, %{channel => true}) != %{}
  end

  defp persisted_pending_write?(_graph, {_task_id, channel, _value})
       when channel in ["__interrupt__", "__error__"],
       do: true

  defp persisted_pending_write?(graph, {_task_id, channel, _value}) do
    ChannelState.persisted_update(graph, %{channel => true}) != %{}
  end

  defp persisted_pending_write?(_graph, {_task_id, channel, _value, _path})
       when channel in ["__interrupt__", "__error__"],
       do: true

  defp persisted_pending_write?(graph, {_task_id, channel, _value, _path}) do
    ChannelState.persisted_update(graph, %{channel => true}) != %{}
  end

  @doc false
  @spec checkpoint_task_records(list()) :: [map()]
  defdelegate checkpoint_task_records(task_events), to: Replay

  @spec checkpoint_next_records([term()], map() | nil) :: [map()]
  def checkpoint_next_records(next_ready, graph \\ nil),
    do: Replay.checkpoint_next_records(next_ready, graph)

  @doc false
  @spec ready_names([term()]) :: [String.t()]
  defdelegate ready_names(ready), to: Replay

  @doc false
  @spec ready_task_paths(term()) :: [term()]
  defdelegate ready_task_paths(ready), to: Replay

  defp metadata_value(metadata, key, default) do
    Map.get(metadata, key, Map.get(metadata, to_string(key), default))
  end

  defp merge_checkpoint_map(checkpoint_config, source_config) do
    source_configurable = Checkpoint.configurable(source_config)
    source_map = Map.get(source_configurable, "checkpoint_map", %{})

    checkpoint_config =
      case Map.get(source_configurable, "checkpoint_target_ns") do
        nil -> checkpoint_config
        target -> put_in(checkpoint_config, ["configurable", "checkpoint_target_ns"], target)
      end

    if is_map(source_map) and map_size(source_map) > 0 do
      update_in(
        checkpoint_config,
        ["configurable", "checkpoint_map"],
        &Map.merge(&1 || %{}, source_map)
      )
    else
      checkpoint_config
    end
  end

  defp delta_snapshot_state(graph, parent_tuple, metadata) do
    previous =
      parent_tuple
      |> case do
        %{metadata: metadata} ->
          Map.get(
            metadata,
            "counters_since_delta_snapshot",
            Map.get(metadata, :counters_since_delta_snapshot, %{})
          )

        _other ->
          %{}
      end

    step_update = metadata_value(metadata, :step_update, %{})

    max_supersteps = Config.get([:execution, :delta_max_supersteps_since_snapshot], 5_000)

    Enum.reduce(graph.channels, {previous, []}, fn {key, channel}, {counters, snapshots} ->
      if match?(%BeamWeaver.Graph.Channels.DeltaChannel{}, channel) do
        channel_key = to_string(key)

        {updates, supersteps} =
          counter_tuple(Map.get(counters, channel_key, Map.get(counters, key, {0, 0})))

        update_count = if map_has_key?(step_update, key), do: updates + 1, else: updates
        superstep_count = supersteps + 1

        if update_count >= channel.snapshot_frequency or superstep_count >= max_supersteps do
          {Map.put(counters, channel_key, [0, 0]), [key | snapshots]}
        else
          {Map.put(counters, channel_key, [update_count, superstep_count]), snapshots}
        end
      else
        {counters, snapshots}
      end
    end)
  end

  defp counter_tuple([updates, supersteps]), do: {updates, supersteps}
  defp counter_tuple({updates, supersteps}), do: {updates, supersteps}
  defp counter_tuple(_counter), do: {0, 0}

  defp map_has_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Map.has_key?(map, to_string(key))
  end

  defp map_has_key?(_map, _key), do: false
end
