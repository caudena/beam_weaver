defmodule BeamWeaver.Graph.Execution.SubgraphRouter do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.Namespace
  alias BeamWeaver.MapShape

  @compiled BeamWeaver.Graph.Compiled

  @spec inherit_runtime_adapters(map(), map()) :: map()
  def inherit_runtime_adapters(compiled, runtime) do
    %{
      compiled
      | checkpointer: inherited_checkpointer(compiled, runtime.checkpointer),
        store: compiled.store || runtime.store
    }
  end

  @spec config(map(), map() | :task) :: map()
  def config(runtime, compiled_or_mode) do
    configurable = Checkpoint.configurable(runtime.config)
    parent_ns = Map.get(configurable, "checkpoint_ns", "")
    task_id = runtime.scratchpad && runtime.scratchpad.task_id
    child_ns = child_namespace(parent_ns, runtime.node, task_id, compiled_or_mode)
    %{"configurable" => child_configurable(configurable, parent_ns, child_ns)}
  end

  @spec child_configurable(map(), String.t(), String.t()) :: map()
  def child_configurable(configurable, parent_ns, child_ns) do
    checkpoint_map =
      configurable
      |> Map.get("checkpoint_map", %{})
      |> Namespace.recast_checkpoint_map()
      |> MapShape.put_present(Namespace.recast(parent_ns), Map.get(configurable, "checkpoint_id"))

    configurable
    |> Map.put("checkpoint_ns", child_ns)
    |> Map.put("checkpoint_map", checkpoint_map)
    |> Map.delete("checkpoint_id")
    |> MapShape.put_present("checkpoint_id", Map.get(checkpoint_map, child_ns))
  end

  @spec namespace_delegate(map(), map()) :: map() | nil
  def namespace_delegate(compiled, config) do
    namespace =
      config
      |> Checkpoint.configurable()
      |> Map.get("checkpoint_ns", "")

    case Namespace.recast(namespace) |> Namespace.normalize() do
      [] -> nil
      path -> find_subgraph(compiled, path)
    end
  end

  @spec checkpoint_config(map(), map()) :: map()
  def checkpoint_config(compiled, config) do
    if Map.get(compiled, :checkpoint_scope, :inherit) == :shared do
      configurable = Checkpoint.configurable(config)
      namespace = Map.get(configurable, "checkpoint_ns", "")
      recast = Namespace.recast(namespace)

      if recast != namespace do
        Map.put(config, "configurable", Map.put(configurable, "checkpoint_ns", recast))
      else
        config
      end
    else
      config
    end
  end

  @spec rebase_time_travel_config(map(), map()) :: map()
  def rebase_time_travel_config(compiled, config) do
    configurable = Checkpoint.configurable(config)
    namespace = Map.get(configurable, "checkpoint_ns", "")
    checkpoint_map = Map.get(configurable, "checkpoint_map", %{})
    root_checkpoint_id = Map.get(checkpoint_map, "")

    cond do
      namespace in [nil, ""] ->
        config

      is_nil(root_checkpoint_id) ->
        config

      not namespace_targets_subgraph?(compiled, namespace) ->
        config

      true ->
        %{
          "configurable" =>
            configurable
            |> Map.put("checkpoint_ns", "")
            |> Map.put("checkpoint_id", root_checkpoint_id)
            |> Map.put("checkpoint_map", checkpoint_map)
            |> Map.put("checkpoint_target_ns", Namespace.recast(namespace))
        }
    end
  end

  @spec resolve_command(Command.t(), map(), map()) :: Command.t() | no_return()
  def resolve_command(%Command{graph: graph} = command, _compiled, _runtime)
      when graph in [:parent, "parent", "__parent__"] do
    %{command | graph: nil}
  end

  def resolve_command(%Command{} = command, compiled, runtime) do
    if targets_subgraph?(command, compiled, runtime) do
      %{command | graph: nil}
    else
      throw({:beam_weaver_graph_parent_command, command})
    end
  end

  defp targets_subgraph?(%Command{graph: graph}, compiled, runtime) do
    CommandRouter.command_target?(graph, subgraph_identifiers(compiled, runtime))
  end

  defp subgraph_identifiers(compiled, runtime) do
    namespace =
      runtime
      |> config(:task)
      |> Checkpoint.configurable()
      |> Map.get("checkpoint_ns", "")

    [compiled.name, runtime.node, namespace, Namespace.recast(namespace)]
  end

  defp find_subgraph(compiled, [node | rest]) do
    case Map.get(compiled.graph.nodes, to_string(node)) do
      %{fun: %{__struct__: @compiled} = child} ->
        child = inherit_runtime_adapters(child, compiled)

        case rest do
          [] -> child
          _rest -> find_subgraph(child, rest)
        end

      _missing ->
        nil
    end
  end

  defp inherited_checkpointer(compiled, parent_checkpointer) do
    case Map.get(compiled, :checkpoint_scope, :inherit) do
      :disabled -> nil
      :local -> compiled.checkpointer
      _inherit_or_shared -> compiled.checkpointer || parent_checkpointer
    end
  end

  defp child_namespace(parent_ns, node, task_id, :task) do
    Namespace.child(parent_ns, node, task_id) |> Namespace.serialize()
  end

  defp child_namespace(parent_ns, node, task_id, compiled) do
    case Map.get(compiled, :checkpoint_scope, :inherit) do
      :shared -> Namespace.child(parent_ns, node, nil) |> Namespace.serialize()
      _other -> child_namespace(parent_ns, node, task_id, :task)
    end
  end

  defp namespace_targets_subgraph?(compiled, namespace) do
    case Namespace.recast(namespace) |> Namespace.normalize() do
      [_node | _rest] = path -> not is_nil(find_subgraph(compiled, path))
      [] -> false
    end
  end
end
