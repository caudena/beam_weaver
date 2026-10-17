defmodule BeamWeaver.Graph.Execution do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.Task, as: ExecutionTask
  alias BeamWeaver.Graph.Execution.TaskRequest

  @reserved_channels [
    "__error__",
    "__error_source_node__",
    "__interrupt__",
    "__no_writes__",
    "__push__",
    "__resume__",
    "__return__",
    "__route__"
  ]

  # `step_start` is the id of the checkpoint whose state the tasks of a stopped
  # step started from, when that isn't this checkpoint's own state: after
  # `update_state/4` on a paused or failed thread, the new checkpoint holds
  # the state with the update.
  @type checkpoint_state :: %{
          values: map(),
          channel_versions: map(),
          versions_seen: map(),
          pending_writes: list(),
          pending_write_paths: list(),
          next: [TaskRequest.t()],
          step: integer(),
          step_start: String.t() | nil
        }

  @spec checkpoint_state(map() | nil) :: checkpoint_state()
  def checkpoint_state(nil),
    do: %{
      values: %{},
      channel_versions: %{},
      versions_seen: %{},
      pending_writes: [],
      pending_write_paths: [],
      next: [],
      step: -1,
      step_start: nil
    }

  def checkpoint_state(%{checkpoint: checkpoint} = tuple) when is_map(checkpoint) do
    %{
      values: checkpoint_values(checkpoint),
      channel_versions: normalize_versions(get_checkpoint_map(checkpoint, "channel_versions")),
      versions_seen: normalize_versions_seen(get_checkpoint_map(checkpoint, "versions_seen")),
      pending_writes: Map.get(tuple, :pending_writes, []),
      pending_write_paths: Map.get(tuple, :pending_write_paths, []),
      next: checkpoint_next(checkpoint),
      step: checkpoint_step(tuple),
      step_start: Map.get(checkpoint, "step_start")
    }
  end

  @spec checkpoint_id(map()) :: String.t() | nil
  def checkpoint_id(config), do: config |> Checkpoint.configurable() |> Map.get("checkpoint_id")

  # `config` naming the checkpoint `checkpoint_id`, or the thread's latest
  # with `nil`.
  @spec at_checkpoint(map(), String.t() | nil) :: map()
  def at_checkpoint(config, checkpoint_id) do
    configurable = config |> Checkpoint.configurable() |> Map.delete("checkpoint_id")
    configurable = if checkpoint_id, do: Map.put(configurable, "checkpoint_id", checkpoint_id), else: configurable
    config |> Map.delete(:configurable) |> Map.put("configurable", configurable)
  end

  # The state a checkpoint saved. Checkpoints saved as JSON before map keys
  # kept their types list the state's atom keys in "atom_channels".
  @spec checkpoint_values(map()) :: map()
  def checkpoint_values(checkpoint) when is_map(checkpoint) do
    checkpoint
    |> get_checkpoint_map("channel_values")
    |> ChannelLookup.restore_atom_keys(Map.get(checkpoint, "atom_channels"))
  end

  # A join's channel is left out: replayed arrivals don't fire the join on their
  # own, the step merge does once every upstream node has arrived.
  @spec pending_channels(list()) :: [String.t()]
  def pending_channels(pending_writes) when is_list(pending_writes) do
    for(
      write when tuple_size(write) in [3, 4] <- pending_writes,
      channel = to_string(elem(write, 1)),
      not (reserved_channel?(channel) or String.starts_with?(channel, "__barrier__:")),
      do: channel
    )
    |> normalize_channels()
  end

  def pending_channels(_pending_writes), do: []

  @spec reserved_channel?(term()) :: boolean()
  def reserved_channel?(channel), do: to_string(channel) in @reserved_channels

  # The tasks that finished in a step that stopped partway: those with a write
  # other than an error or an interrupt. A finished task always has its route.
  @spec finished_task_ids(list()) :: [String.t()]
  def finished_task_ids(pending_writes) when is_list(pending_writes) do
    for(
      write when tuple_size(write) in [3, 4] and elem(write, 1) not in ["__error__", "__interrupt__"] <- pending_writes,
      do: elem(write, 0)
    )
    |> Enum.uniq()
  end

  def finished_task_ids(_pending_writes), do: []

  @spec updated_channels(map() | nil) :: [String.t()]
  def updated_channels(update) when is_map(update) do
    update
    |> Map.keys()
    |> normalize_channels()
  end

  def updated_channels(_update), do: []

  @spec normalize_channels(Enumerable.t()) :: [String.t()]
  def normalize_channels(channels) do
    channels
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec next_channel_versions(struct() | nil, map(), Enumerable.t(), map()) :: map()
  def next_channel_versions(nil, previous_versions, _updated_channels, _graph),
    do: normalize_versions(previous_versions)

  def next_channel_versions(checkpointer, previous_versions, updated_channels, graph) do
    updated_channels
    |> normalize_channels()
    |> Enum.reduce(normalize_versions(previous_versions), fn channel, versions ->
      channel_struct = ChannelLookup.channel_for(graph, channel)
      current = Map.get(versions, channel, if(channel_struct, do: Channel.null_version(channel_struct)))
      Map.put(versions, channel, Checkpoint.next_version(checkpointer, current, channel_struct || channel))
    end)
  end

  @spec mark_versions_seen(map(), Enumerable.t(), map()) :: map()
  def mark_versions_seen(versions_seen, nodes, channel_versions) do
    channel_versions = normalize_versions(channel_versions)

    Enum.reduce(nodes, normalize_versions_seen(versions_seen), fn node, seen ->
      Map.put(seen, to_string(node), channel_versions)
    end)
  end

  @spec task_id(String.t(), map(), non_neg_integer(), String.t(), term(), map()) :: String.t()
  def task_id(graph_name, config, step, node, path, trigger_versions) do
    namespace =
      config
      |> Checkpoint.configurable()
      |> Map.get("checkpoint_ns", "")

    payload =
      :erlang.term_to_binary({
        graph_name,
        namespace,
        step,
        to_string(node),
        id_term(path),
        normalize_versions(trigger_versions)
      })

    "task_" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  # A task's path with map keys as strings at any depth, as checkpoints saved
  # as JSON before map keys kept their types give it back. Hashing this form
  # gives a `Send` task restored from such a checkpoint the id it had when it
  # was scheduled, so its pending writes and the answer to its interrupt still
  # find it.
  defp id_term(%module{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {field, value} -> {field, id_term(value)} end)
    |> Map.put(:__struct__, module)
  end

  defp id_term(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {id_key(key), id_term(value)} end)

  defp id_term([head | tail]), do: [id_term(head) | id_term(tail)]
  defp id_term(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> id_term() |> List.to_tuple()
  defp id_term(value), do: value

  defp id_key(key) when is_atom(key), do: Atom.to_string(key)
  defp id_key(key) when is_number(key), do: to_string(key)
  defp id_key(key), do: key

  @spec prepare_task(
          String.t(),
          map(),
          non_neg_integer(),
          String.t(),
          term(),
          term(),
          map(),
          :pull | :push | :send
        ) :: ExecutionTask.t()
  def prepare_task(graph_name, config, step, node, input, raw_path, trigger_versions, kind) do
    %ExecutionTask{
      id: task_id(graph_name, config, step, node, raw_path, trigger_versions),
      node: to_string(node),
      path: task_path(raw_path),
      raw_path: raw_path,
      step: step,
      input: input,
      trigger_versions: normalize_versions(trigger_versions),
      kind: kind
    }
  end

  @spec task_path(term()) :: String.t()
  def task_path({node, update, timeout}) do
    encode_task_path(%{
      "node" => to_string(node),
      "update" => normalize_path_value(update),
      "timeout" => normalize_path_value(timeout)
    })
  end

  def task_path({node, update}) do
    encode_task_path(%{
      "node" => to_string(node),
      "update" => normalize_path_value(update)
    })
  end

  # A `Send` like an earlier one of its step, told apart by `repeat`.
  def task_path({node, update, timeout, repeat}) do
    path = %{"node" => to_string(node), "update" => normalize_path_value(update), "repeat" => repeat}

    encode_task_path(if timeout, do: Map.put(path, "timeout", normalize_path_value(timeout)), else: path)
  end

  def task_path(path) when is_binary(path), do: path

  def task_path(path), do: encode_task_path(normalize_path_value(path))

  defp encode_task_path(path) do
    case BeamWeaver.JSON.encode(path) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(path)
    end
  end

  defp normalize_path_value(%{__struct__: _module} = value), do: inspect(value)

  defp normalize_path_value(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), normalize_path_value(value)} end)
  end

  defp normalize_path_value(value) when is_list(value),
    do: Enum.map(value, &normalize_path_value/1)

  defp normalize_path_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> normalize_path_value()
  end

  defp normalize_path_value(value) when is_atom(value), do: to_string(value)
  defp normalize_path_value(value), do: value

  defp get_checkpoint_map(checkpoint, key) do
    BeamWeaver.MapAccess.get(checkpoint, key, %{}) || %{}
  end

  defp checkpoint_step(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "step", Map.get(metadata, :step, -1)) do
      step when is_integer(step) -> step
      _other -> -1
    end
  end

  defp checkpoint_step(_tuple), do: -1

  # The tasks a checkpoint says run next, as requests.
  defp checkpoint_next(checkpoint) do
    case Map.get(checkpoint, "next_tasks", Map.get(checkpoint, :next_tasks, [])) do
      [_first | _rest] = next_tasks ->
        Enum.map(next_tasks, &TaskRequest.from_checkpoint/1)

      _empty ->
        Map.get(checkpoint, "next", Map.get(checkpoint, :next, []))
        |> List.wrap()
        |> Enum.map(&TaskRequest.from_checkpoint/1)
    end
  end

  defp normalize_versions(versions) when is_map(versions) do
    Map.new(versions, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_versions(_versions), do: %{}

  defp normalize_versions_seen(versions_seen) when is_map(versions_seen) do
    Map.new(versions_seen, fn {node, versions} ->
      {to_string(node), normalize_versions(versions)}
    end)
  end

  defp normalize_versions_seen(_versions_seen), do: %{}
end
