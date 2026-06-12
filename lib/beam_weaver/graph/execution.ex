defmodule BeamWeaver.Graph.Execution do
  @moduledoc """
  Small graph execution runtime helpers shared by the graph executor.

  This module is intentionally narrow for now: it owns version bookkeeping and
  deterministic task IDs while the existing executor is migrated toward a full
  channel-triggered graph scheduler.
  """

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Graph.Execution.ChannelVersion
  alias BeamWeaver.Graph.Execution.Step
  alias BeamWeaver.Graph.Execution.Task, as: ExecutionTask

  @type checkpoint_state :: %{
          values: map(),
          channel_versions: map(),
          versions_seen: map(),
          pending_writes: list(),
          pending_write_paths: list(),
          next: list(),
          step: integer()
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
      step: -1
    }

  def checkpoint_state(%{checkpoint: checkpoint} = tuple) when is_map(checkpoint) do
    %{
      values: get_checkpoint_map(checkpoint, "channel_values"),
      channel_versions: normalize_versions(get_checkpoint_map(checkpoint, "channel_versions")),
      versions_seen: normalize_versions_seen(get_checkpoint_map(checkpoint, "versions_seen")),
      pending_writes: Map.get(tuple, :pending_writes, []),
      pending_write_paths: Map.get(tuple, :pending_write_paths, []),
      next: checkpoint_next(checkpoint),
      step: checkpoint_step(tuple)
    }
  end

  @spec pending_channels(list()) :: [String.t()]
  def pending_channels(pending_writes) when is_list(pending_writes) do
    pending_writes
    |> Enum.flat_map(fn
      {_task_id, channel, _value} ->
        if Step.reserved_channel?(channel), do: [], else: [channel]

      {_task_id, channel, _value, _path} ->
        if Step.reserved_channel?(channel), do: [], else: [channel]

      _other ->
        []
    end)
    |> normalize_channels()
  end

  def pending_channels(_pending_writes), do: []

  @spec pending_task_ids(list()) :: [String.t()]
  def pending_task_ids(pending_writes) when is_list(pending_writes) do
    pending_writes
    |> Enum.reject(fn
      {_task_id, channel, _value} -> Step.reserved_channel?(channel)
      {_task_id, channel, _value, _path} -> Step.reserved_channel?(channel)
      _other -> true
    end)
    |> Enum.map(fn
      {task_id, _channel, _value} -> task_id
      {task_id, _channel, _value, _path} -> task_id
    end)
    |> Enum.uniq()
  end

  def pending_task_ids(_pending_writes), do: []

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

  @spec next_channel_versions(struct() | nil, map(), Enumerable.t()) :: map()
  def next_channel_versions(checkpointer, previous_versions, updated_channels),
    do: ChannelVersion.bump(checkpointer, previous_versions, updated_channels)

  @spec next_channel_versions(struct() | nil, map(), Enumerable.t(), map()) :: map()
  def next_channel_versions(checkpointer, previous_versions, updated_channels, graph),
    do: ChannelVersion.bump(checkpointer, previous_versions, updated_channels, graph)

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
        path,
        normalize_versions(trigger_versions)
      })

    "task_" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

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

  defp checkpoint_next(checkpoint) do
    case Map.get(checkpoint, "next_tasks", Map.get(checkpoint, :next_tasks, [])) do
      [_first | _rest] = next_tasks ->
        Enum.map(next_tasks, &decode_next_task/1)

      _empty ->
        Map.get(checkpoint, "next", Map.get(checkpoint, :next, []))
        |> List.wrap()
        |> Enum.map(&to_string/1)
    end
  end

  defp decode_next_task(%{"node" => node, "update" => update, "timeout" => timeout}),
    do: %{"node" => to_string(node), "update" => update || %{}, "timeout" => timeout}

  defp decode_next_task(%{node: node, update: update, timeout: timeout}),
    do: %{node: to_string(node), update: update || %{}, timeout: timeout}

  defp decode_next_task(%{"node" => node, "update" => update}),
    do: {to_string(node), update || %{}}

  defp decode_next_task(%{node: node, update: update}), do: {to_string(node), update || %{}}
  defp decode_next_task(%{"node" => node}), do: to_string(node)
  defp decode_next_task(%{node: node}), do: to_string(node)
  defp decode_next_task(node), do: to_string(node)

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
