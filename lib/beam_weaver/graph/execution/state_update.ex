defmodule BeamWeaver.Graph.Execution.StateUpdate do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelState
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.Replay
  alias BeamWeaver.Graph.Execution.Runner
  alias BeamWeaver.Graph.Execution.Snapshot
  alias BeamWeaver.Graph.Execution.SubgraphRouter

  @spec get_state(map(), map()) :: {:ok, map()} | :error
  def get_state(%{checkpointer: nil}, _config), do: :error

  def get_state(%{checkpointer: checkpointer} = compiled, config) do
    case SubgraphRouter.namespace_delegate(compiled, config) do
      %{__struct__: _module} = delegate ->
        get_state(delegate, config)

      nil ->
        config = SubgraphRouter.checkpoint_config(compiled, config)

        case CheckpointIO.get_tuple(checkpointer, config) do
          nil ->
            :error

          tuple ->
            {:ok, Snapshot.from_tuple(compiled, tuple, apply_pending?: Snapshot.latest_state?(config))}
        end
    end
  end

  @spec get_state_history(map(), map(), keyword()) :: [map()]
  def get_state_history(%{checkpointer: nil}, _config, _opts), do: []

  def get_state_history(%{checkpointer: checkpointer} = compiled, config, opts) do
    case SubgraphRouter.namespace_delegate(compiled, config) do
      %{__struct__: _module} = delegate ->
        get_state_history(delegate, config, opts)

      nil ->
        config = SubgraphRouter.checkpoint_config(compiled, config)

        checkpointer
        |> CheckpointIO.list(config, opts)
        |> Enum.map(&Snapshot.from_tuple(compiled, &1, apply_pending?: false))
    end
  end

  @spec update_state(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def update_state(%{checkpointer: nil}, _config, _values, _opts) do
    {:error, Error.new(:missing_checkpointer, "update_state requires a checkpointer")}
  end

  def update_state(%{} = compiled, config, values, opts) when is_map(values) do
    case SubgraphRouter.namespace_delegate(compiled, config) do
      %{__struct__: _module} = delegate ->
        update_state(delegate, config, values, opts)

      nil ->
        config = SubgraphRouter.checkpoint_config(compiled, config)
        do_update_state(compiled, config, values, opts)
    end
  end

  @spec bulk_update_state(map(), map(), [[map()]], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def bulk_update_state(%{checkpointer: nil}, _config, _supersteps, _opts) do
    {:error, Error.new(:missing_checkpointer, "bulk_update_state requires a checkpointer")}
  end

  def bulk_update_state(%{} = compiled, config, supersteps, opts)
      when is_list(supersteps) do
    case SubgraphRouter.namespace_delegate(compiled, config) do
      %{__struct__: _module} = delegate ->
        bulk_update_state(delegate, config, supersteps, opts)

      nil ->
        config = SubgraphRouter.checkpoint_config(compiled, config)
        do_bulk_update_state(compiled, config, supersteps, opts)
    end
  end

  defp do_update_state(%{} = compiled, config, values, opts) do
    {current_config, current, current_versions, versions_seen, snapshot} =
      case get_state(compiled, config) do
        {:ok, snapshot} ->
          {snapshot.config, snapshot.values, snapshot.channel_versions, snapshot.versions_seen, snapshot}

        :error ->
          {config, %{}, %{}, %{}, nil}
      end

    with :ok <- validate_update(compiled.graph, values),
         {:ok, as_node} <- update_as_node(compiled.graph, snapshot, opts) do
      updated = ChannelState.merge_update(current, values, compiled.graph)
      updated_channels = Execution.updated_channels(values)

      channel_versions =
        Execution.next_channel_versions(
          compiled.checkpointer,
          current_versions,
          updated_channels,
          compiled.graph
        )

      {next_names, next_tasks} =
        if pending_interrupt?(snapshot) do
          {Map.get(snapshot, :next, []), Map.get(snapshot, :next_tasks, [])}
        else
          next = next_after_update(compiled.graph, as_node)
          {Replay.ready_names(next), Replay.checkpoint_next_records(next, compiled.graph)}
        end

      case CheckpointIO.write_checkpoint(compiled, current_config, updated, %{
             source: "update",
             step: Keyword.get(opts, :step, 0),
             as_node: as_node,
             next: next_names,
             next_tasks: next_tasks,
             tasks: [],
             interrupts: Map.get(snapshot || %{}, :interrupts, []),
             channel_versions: channel_versions,
             versions_seen: versions_seen,
             updated_channels: updated_channels,
             step_update: values
           }) do
        {:ok, updated_config} ->
          with :ok <- copy_pending_writes(compiled, updated_config, snapshot) do
            maybe_resume_after_update(compiled, updated_config, opts)
          end

        {:error, %Error{}} = error ->
          error
      end
    end
  end

  defp next_after_update(_graph, nil), do: []

  defp next_after_update(graph, as_node) do
    node = to_string(as_node)

    cond do
      Map.has_key?(graph.edges, node) ->
        Map.get(graph.edges, node, [])

      MapSet.member?(graph.finish_points, node) ->
        []

      true ->
        []
    end
  end

  defp update_as_node(graph, snapshot, opts) do
    if Keyword.has_key?(opts, :as_node) do
      {:ok, Keyword.get(opts, :as_node)}
    else
      candidates =
        snapshot
        |> last_finished_task_nodes()
        |> Enum.filter(&Map.has_key?(graph.edges, &1))
        |> Enum.uniq()

      case candidates do
        [node] ->
          {:ok, node}

        [] ->
          {:ok, nil}

        nodes ->
          {:error, Error.new(:ambiguous_state_update, "could not infer as_node", %{nodes: nodes})}
      end
    end
  end

  defp last_finished_task_nodes(nil), do: []

  defp last_finished_task_nodes(snapshot) do
    snapshot
    |> Map.get(:tasks, [])
    |> Enum.filter(&(Map.get(&1, :kind) == :finish or Map.get(&1, "kind") == "finish"))
    |> Enum.map(&(Map.get(&1, :node) || Map.get(&1, "node")))
    |> Enum.reject(&is_nil/1)
  end

  defp validate_update(graph, values) do
    managed_keys = MapSet.new(Map.keys(graph.managed || %{}), &to_string/1)

    case Enum.find(Map.keys(values), &(to_string(&1) in managed_keys)) do
      nil ->
        :ok

      key ->
        {:error, Error.new(:invalid_update, "managed graph values are read-only", %{key: key})}
    end
  end

  defp maybe_resume_after_update(compiled, updated_config, opts) do
    if Keyword.has_key?(opts, :resume) do
      resume = Keyword.fetch!(opts, :resume)

      case Runner.execute(
             compiled,
             %{},
             Keyword.put(opts, :config, updated_config) |> Keyword.put(:resume, resume)
           ) do
        {:ok, result, _events} ->
          {:ok, result}

        {:interrupted, interrupt, _events} ->
          resume_once_more(compiled, interrupt, resume, opts)

        {:error, error, _events} ->
          {:error, error}

        {:parent_command, command, _events} ->
          BeamWeaver.Graph.Execution.CommandRouter.parent_command_error(command)
      end
    else
      {:ok, updated_config}
    end
  end

  defp resume_once_more(compiled, interrupt, resume, opts) do
    config = Map.get(interrupt, :config, Keyword.get(opts, :config, %{}))

    targeted_resume =
      case Map.get(interrupt, :id) do
        nil -> resume
        id -> %{id => resume}
      end

    case Runner.execute(
           compiled,
           %{},
           Keyword.put(opts, :config, config) |> Keyword.put(:resume, targeted_resume)
         ) do
      {:ok, result, _events} ->
        {:ok, result}

      {:interrupted, interrupt, _events} ->
        {:interrupted, interrupt}

      {:error, error, _events} ->
        {:error, error}

      {:parent_command, command, _events} ->
        BeamWeaver.Graph.Execution.CommandRouter.parent_command_error(command)
    end
  end

  defp copy_pending_writes(_compiled, _config, nil), do: :ok

  defp copy_pending_writes(%{checkpointer: checkpointer}, config, snapshot) do
    snapshot
    |> Map.get(:pending_writes, [])
    |> Enum.group_by(
      fn
        {task_id, _channel, _value, path} -> {task_id, path || ""}
        {task_id, _channel, _value} -> {task_id, ""}
      end,
      fn
        {_task_id, channel, value, _path} -> {channel, value}
        {_task_id, channel, value} -> {channel, value}
      end
    )
    |> Enum.reduce_while(:ok, fn {{task_id, path}, writes}, :ok ->
      case CheckpointIO.put_writes(checkpointer, config, writes, task_id, path) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp pending_interrupt?(nil), do: false

  defp pending_interrupt?(snapshot) do
    snapshot
    |> Map.get(:pending_writes, [])
    |> Enum.any?(fn
      {_task_id, "__interrupt__", _value} -> true
      {_task_id, "__interrupt__", _value, _path} -> true
      _other -> false
    end)
  end

  defp do_bulk_update_state(%{} = compiled, config, supersteps, opts) do
    cond do
      supersteps == [] ->
        {:error, Error.new(:invalid_update, "bulk update requires at least one superstep")}

      Enum.any?(supersteps, &(&1 == [])) ->
        {:error, Error.new(:invalid_update, "bulk update supersteps cannot be empty")}

      true ->
        reduce_bulk_update_state(compiled, config, supersteps, opts)
    end
  end

  defp reduce_bulk_update_state(%{} = compiled, config, supersteps, opts) do
    {initial_config, initial_values, initial_versions, initial_seen} =
      case get_state(compiled, config) do
        {:ok, snapshot} ->
          {snapshot.config, snapshot.values, snapshot.channel_versions, snapshot.versions_seen}

        :error ->
          {config, %{}, %{}, %{}}
      end

    start_step = Keyword.get(opts, :step, 0)

    supersteps
    |> Enum.with_index(start_step)
    |> Enum.reduce_while(
      {:ok, initial_config, initial_values, initial_versions, initial_seen},
      fn {updates, step}, {:ok, current_config, current_values, current_versions, versions_seen} ->
        case bulk_update_superstep(
               compiled,
               current_config,
               current_values,
               current_versions,
               versions_seen,
               updates,
               step,
               opts
             ) do
          {:ok, next_config, next_values, next_versions} ->
            {:cont, {:ok, next_config, next_values, next_versions, versions_seen}}

          {:error, %Error{}} = error ->
            {:halt, error}
        end
      end
    )
    |> case do
      {:ok, final_config, _values, _versions, _seen} -> {:ok, final_config}
      {:error, %Error{}} = error -> error
    end
  end

  defp bulk_update_superstep(
         compiled,
         config,
         values,
         current_versions,
         versions_seen,
         updates,
         step,
         opts
       )
       when is_list(updates) do
    updated_channels =
      updates
      |> Enum.flat_map(&Execution.updated_channels/1)
      |> Execution.normalize_channels()

    channel_versions =
      Execution.next_channel_versions(
        compiled.checkpointer,
        current_versions,
        updated_channels,
        compiled.graph
      )

    with {:ok, step_update, next_values} <-
           ChannelState.merge_step_updates(values, updates, compiled.graph),
         {:ok, next_config} <-
           CheckpointIO.write_checkpoint(compiled, config, next_values, %{
             source: "update",
             step: step,
             as_node: Keyword.get(opts, :as_node),
             next: [],
             tasks: [],
             interrupts: [],
             channel_versions: channel_versions,
             versions_seen: versions_seen,
             updated_channels: updated_channels,
             step_update: step_update
           }) do
      {:ok, next_config, next_values, channel_versions}
    end
  end

  defp bulk_update_superstep(
         _compiled,
         _config,
         _values,
         _versions,
         _seen,
         _updates,
         _step,
         _opts
       ) do
    {:error, Error.new(:invalid_update, "bulk update supersteps must contain update maps")}
  end
end
