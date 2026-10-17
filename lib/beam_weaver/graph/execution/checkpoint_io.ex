defmodule BeamWeaver.Graph.Execution.CheckpointIO do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelCheckpoint
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.Route

  defp put(checkpointer, config, checkpoint, metadata, channel_versions) do
    case Checkpoint.put(checkpointer, config, checkpoint, metadata, channel_versions) do
      {:ok, config} ->
        {:ok, config}

      {:error, reason} ->
        {:error, Error.new(:checkpoint_error, "checkpoint write failed", %{reason: inspect(reason)})}
    end
  end

  defp put_writes(checkpointer, config, writes, task_id, path) do
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

  # What a run knows of the checkpoint its config names, from writing or
  # reading it: that config and the delta snapshot counters in the
  # checkpoint's metadata, as the saver returns them. Writing the next
  # checkpoint then doesn't read this one back.
  @type known_checkpoint :: {map(), map()} | nil

  @spec known_checkpoint(map(), map() | nil) :: known_checkpoint()
  def known_checkpoint(config, tuple), do: {config, tuple_counters(tuple)}

  @spec maybe_write_input_checkpoint(map(), map(), map(), boolean(), map(), known_checkpoint()) ::
          {:ok, map(), known_checkpoint()} | {:error, Error.t()}
  def maybe_write_input_checkpoint(%{checkpointer: nil}, config, _state, true, _metadata, _parent),
    do: {:ok, config, nil}

  def maybe_write_input_checkpoint(
        %{checkpointer: checkpointer},
        config,
        _state,
        true,
        _metadata,
        _parent
      ) do
    case Checkpoint.get_tuple(checkpointer, config) do
      %{config: checkpoint_config} = tuple ->
        config = merge_checkpoint_map(checkpoint_config, config)
        {:ok, config, known_checkpoint(config, tuple)}

      _missing ->
        {:ok, config, nil}
    end
  end

  def maybe_write_input_checkpoint(compiled, config, state, false, metadata, parent) do
    metadata = %{metadata | next: metadata.next || compiled.graph.entry_points}
    write_checkpoint(compiled, config, state, metadata, parent)
  end

  @spec write_checkpoint(map(), map(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def write_checkpoint(compiled, config, state, metadata) do
    with {:ok, config, _written} <- write_checkpoint(compiled, config, state, metadata, nil) do
      {:ok, config}
    end
  end

  # Writes the checkpoint that follows the one `config` names, and returns
  # what is known of the new one. `parent` is what is known of the one
  # `config` names; when it is about another checkpoint, the saver is read.
  @spec write_checkpoint(map(), map(), map(), map(), known_checkpoint()) ::
          {:ok, map(), known_checkpoint()} | {:error, Error.t()}
  def write_checkpoint(%{checkpointer: nil}, config, _state, _metadata, _parent), do: {:ok, config, nil}

  def write_checkpoint(%{checkpointer: checkpointer} = compiled, config, state, metadata, parent) do
    updated_channels = Map.get(metadata, :updated_channels, Map.keys(state))
    channel_versions = Map.get(metadata, :channel_versions, %{})
    versions_seen = Map.get(metadata, :versions_seen, %{})
    parent_counters = parent_counters(checkpointer, config, parent)
    step_update = Map.get(metadata, :step_update, %{})
    persisted_step_update = ChannelLookup.persisted_update(compiled.graph, step_update)
    persisted_updated_channels = persisted_updated_channels(compiled.graph, updated_channels)
    {step_start, metadata} = Map.pop(metadata, :step_start)

    metadata = Map.merge(metadata, %{step_update: persisted_step_update, updated_channels: persisted_updated_channels})

    {counters, snapshot_channels} = delta_snapshot_state(compiled.graph, parent_counters, metadata)

    channel_values =
      compiled.graph
      |> ChannelCheckpoint.checkpoint_channel_values(state)
      |> Map.merge(ChannelCheckpoint.checkpoint_snapshot_values(compiled.graph, state, snapshot_channels))

    channel_deltas = ChannelCheckpoint.checkpoint_channel_deltas(compiled.graph, persisted_step_update)
    metadata = Map.put(metadata, :counters_since_delta_snapshot, counters)

    checkpoint = %{
      "v" => 1,
      "channel_values" => channel_values,
      "channel_deltas" => channel_deltas,
      "channel_versions" => channel_versions,
      "versions_seen" => versions_seen,
      "updated_channels" => Execution.normalize_channels(persisted_updated_channels),
      "next" => Map.get(metadata, :next, []),
      "next_tasks" => Map.get(metadata, :next_tasks, []),
      "tasks" => Map.get(metadata, :tasks, []),
      "interrupts" => Map.get(metadata, :interrupts, [])
    }

    checkpoint = if step_start, do: Map.put(checkpoint, "step_start", step_start), else: checkpoint

    with {:ok, written_config} <- put(checkpointer, config, checkpoint, metadata, channel_versions) do
      {:ok, written_config, written_checkpoint(written_config, config, counters)}
    end
  end

  defp parent_counters(_checkpointer, config, {config, counters}), do: counters

  defp parent_counters(checkpointer, config, _parent),
    do: checkpointer |> Checkpoint.get_tuple(config) |> tuple_counters()

  defp tuple_counters(%{metadata: metadata}) do
    Map.get(
      metadata,
      "counters_since_delta_snapshot",
      Map.get(metadata, :counters_since_delta_snapshot, %{})
    )
  end

  defp tuple_counters(_tuple), do: %{}

  # The saver gives back counters as the graph writes them, a pair of counts
  # per channel name, unless the config's own metadata sets them.
  defp written_checkpoint(written_config, config, counters) do
    if plain_counters?(counters) and not config_counters?(config),
      do: {written_config, counters},
      else: nil
  end

  defp plain_counters?(counters) when is_map(counters) do
    Enum.all?(counters, fn
      {channel, [updates, supersteps]} when is_binary(channel) and is_integer(updates) and is_integer(supersteps) ->
        not String.contains?(channel, <<0>>)

      _other ->
        false
    end)
  end

  defp plain_counters?(_counters), do: false

  defp config_counters?(config) when is_map(config) do
    case Map.get(config, :metadata, Map.get(config, "metadata")) do
      metadata when is_map(metadata) -> Map.has_key?(metadata, "counters_since_delta_snapshot")
      metadata when is_list(metadata) -> metadata |> Map.new() |> Map.has_key?("counters_since_delta_snapshot")
      _other -> false
    end
  end

  defp config_counters?(_config), do: true

  @spec persist_pending_writes(map(), list()) :: :ok | {:error, Error.t()}
  def persist_pending_writes(_run, []), do: :ok
  def persist_pending_writes(%{compiled: %{checkpointer: nil}}, _pending_writes), do: :ok

  def persist_pending_writes(run, pending_writes) do
    graph = run.compiled.graph

    pending_writes
    |> Enum.filter(&persisted_pending_write?(graph, &1.channel))
    |> Enum.group_by(&{&1.task_id, &1.path || ""}, &{&1.channel, persisted_value(graph, &1.value)})
    |> Enum.reduce_while(:ok, fn {{task_id, path}, writes}, :ok ->
      writes = keep_pending_interrupt(writes, task_id, run.replay_pending_writes)

      case put_writes(run.compiled.checkpointer, run.config, writes, task_id, path) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  # Saves writes of a stopped step, `{task_id, channel, value, path}`, on the
  # checkpoint that `config` names, under the tasks they belong to.
  @spec put_task_writes(struct() | nil, map(), list()) :: :ok | {:error, Error.t()}
  def put_task_writes(checkpointer, config, writes) do
    writes
    |> Enum.group_by(
      fn {task_id, _channel, _value, path} -> {task_id, path || ""} end,
      fn {_task_id, channel, value, _path} -> {channel, value} end
    )
    |> Enum.reduce_while(:ok, fn {{task_id, path}, task_writes}, :ok ->
      case put_writes(checkpointer, config, task_writes, task_id, path) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  # The pending writes of a restored checkpoint on `channels`, each with its
  # task's path: `{task_id, channel, value, path}`.
  @spec pending_writes_on(map(), [String.t()]) :: [{String.t(), String.t(), term(), String.t()}]
  def pending_writes_on(%{pending_writes: writes} = restored, channels) do
    paths =
      restored
      |> Map.get(:pending_write_paths)
      |> List.wrap()
      |> Map.new(fn {task_id, channel, path} -> {{task_id, channel}, path} end)

    for {task_id, channel, value, path} <- Enum.map(writes, &with_path(&1, paths)),
        channel in channels,
        do: {task_id, channel, value, path || ""}
  end

  # A write saved without its task's path gets it from the paths saved apart.
  defp with_path({task_id, channel, value}, paths),
    do: {task_id, channel, value, Map.get(paths, {task_id, channel}, "")}

  defp with_path(write, _paths), do: write

  defp persisted_value(graph, %Route{} = route), do: Route.encode(route, graph)
  defp persisted_value(_graph, value), do: value

  # A resumed task that fails stays paused at the interrupt it was resumed
  # from: that interrupt is saved in place of the error, which the run
  # returns. The error write would otherwise replace the interrupt, and the
  # next resume would find no pause to answer. A task saves one write while
  # it hasn't finished, so its next save, a new pause included, replaces it;
  # an error kept next to the interrupt would stay behind.
  defp keep_pending_interrupt(writes, task_id, replay_pending_writes) do
    failed? = Enum.any?(writes, &match?({"__error__", _value}, &1))
    interrupted? = Enum.any?(writes, &match?({"__interrupt__", _value}, &1))

    with true <- failed? and not interrupted?,
         {:ok, interrupt} <- pending_interrupt(replay_pending_writes, task_id) do
      [{"__interrupt__", interrupt} | Enum.reject(writes, &match?({"__error__", _value}, &1))]
    else
      _none -> writes
    end
  end

  defp pending_interrupt(pending_writes, task_id) do
    Enum.find_value(pending_writes || [], :error, fn
      {^task_id, "__interrupt__", interrupt} -> {:ok, interrupt}
      {^task_id, "__interrupt__", interrupt, _path} -> {:ok, interrupt}
      _other -> nil
    end)
  end

  # Errors, interrupts and routes are always saved; other writes when their
  # channel is saved in checkpoints.
  defp persisted_pending_write?(_graph, channel)
       when channel in ["__interrupt__", "__error__", "__route__"],
       do: true

  defp persisted_pending_write?(graph, channel),
    do: ChannelLookup.persisted_update(graph, %{channel => true}) != %{}

  defp persisted_updated_channels(graph, updated_channels) do
    updated_channels
    |> List.wrap()
    |> Map.new(&{&1, true})
    |> then(&ChannelLookup.persisted_update(graph, &1))
    |> Map.keys()
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

  defp delta_snapshot_state(graph, previous, metadata) do
    step_update = Map.get(metadata, :step_update, %{})

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
