defmodule BeamWeaver.Graph.Execution.NodeInvoker do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled.Runtime, as: CompiledRuntime
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.Namespace
  alias BeamWeaver.Graph.Execution.NodeOutput
  alias BeamWeaver.Graph.Execution.SubgraphRouter
  alias BeamWeaver.Graph.NodeSpec
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Graph.StateGraph
  alias BeamWeaver.MapAccess

  @compiled BeamWeaver.Graph.Compiled

  defmodule SubgraphResult do
    @moduledoc false

    # A subgraph that ran as a node: the state it received and its final output.
    defstruct [:input, :output]
  end

  @spec invoke(NodeSpec.t(), map(), map(), StateGraph.t()) ::
          {:ok, term()}
          | {:error, Error.t()}
          | {:interrupted, term()}
          | {:parent_command, Command.t()}
  def invoke(%NodeSpec{} = spec, state, runtime, graph) do
    safe_call(fn ->
      with {:ok, input} <- project_input(spec, subgraph_state(spec, state, graph), runtime),
           {:ok, runtime} <- project_first_input(spec, runtime, graph),
           {:ok, output} <- call_node(spec.fun, input, runtime) do
        case output do
          %Command{graph: target} = command when target in [:parent, "parent", "__parent__"] ->
            {:parent_command, command}

          {:error, %Error{}} = error ->
            error

          {:error, reason} ->
            {:error, node_error(spec.name, reason)}

          %SubgraphResult{} = result ->
            with {:ok, projected} <- project_subgraph_output(spec, result, state, runtime, graph) do
              {:ok, %NodeOutput{raw: result.output, projected: projected}}
            end

          output ->
            with {:ok, projected} <- project_output(spec, output, state, runtime) do
              {:ok, %NodeOutput{raw: output, projected: projected}}
            end
        end
      end
    end)
  end

  # A subgraph, or a graph or agent module run as one, is a graph of its own:
  # without an `input:` projection it gets the parent's public state, never the
  # parent's private, managed or internal keys.
  defp subgraph_state(%NodeSpec{input: nil, fun: fun}, state, %StateGraph{} = graph) do
    if subgraph_node?(fun), do: ChannelLookup.public_state(graph, state), else: state
  end

  defp subgraph_state(_spec, state, _graph), do: state

  defp subgraph_node?(%{__struct__: @compiled}), do: true
  defp subgraph_node?(module) when is_atom(module), do: BeamWeaver.Behaviour.implemented_by?(module, BeamWeaver.Graph)
  defp subgraph_node?(_fun), do: false

  @spec node_error(String.t() | nil, term()) :: Error.t()
  def node_error(node, reason) when is_binary(reason),
    do: Error.new(:node_error, reason, %{node: node})

  def node_error(node, reason),
    do: Error.new(:node_error, "node returned an error", %{node: node, reason: inspect(reason)})

  defp call_node(fun, state, _runtime) when is_function(fun, 1), do: {:ok, fun.(state)}
  defp call_node(fun, state, runtime) when is_function(fun, 2), do: {:ok, fun.(state, runtime)}

  defp call_node(module, state, runtime) when is_atom(module) do
    cond do
      BeamWeaver.Behaviour.implemented_by?(module, BeamWeaver.Graph) ->
        with {:ok, compiled} <- module.compiled_graph([]), do: call_node(compiled, state, runtime)

      BeamWeaver.Behaviour.exported?(module, :invoke, 2) ->
        {:ok, module.invoke(state, runtime)}

      true ->
        {:error, Error.new(:invalid_node, "node module must implement invoke/2", %{module: module})}
    end
  end

  defp call_node(%{__struct__: @compiled} = compiled, state, runtime) do
    compiled = SubgraphRouter.inherit_runtime_adapters(compiled, runtime)

    opts =
      [
        config: SubgraphRouter.config(runtime, compiled),
        context: runtime.context,
        model_opts: runtime.model_opts || []
      ]
      |> maybe_continue_subgraph_checkpoint()
      |> maybe_collect_subgraph_stream(runtime)
      |> maybe_put_subgraph_recursion_limit(runtime)
      |> maybe_put_subgraph_resume(runtime)

    {received, input} = subgraph_input(compiled, state, runtime, opts)
    opts = put_subgraph_thread(opts, compiled, runtime, received)

    case BeamWeaver.Graph.Execution.Runner.execute(compiled, input, opts) do
      {:ok, value} ->
        {:ok, subgraph_result(compiled, received, value)}

      {:parent_command, command} ->
        {:ok, SubgraphRouter.resolve_command(command, compiled, runtime)}

      {:interrupted, interrupt} ->
        throw({:beam_weaver_graph_interrupt, interrupt})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp call_node(%{__struct__: module} = node, state, runtime) do
    cond do
      function_exported?(module, :invoke, 3) ->
        {:ok, module.invoke(node, state, runtime)}

      function_exported?(module, :invoke, 2) ->
        {:ok, module.invoke(node, state)}

      true ->
        {:error,
         Error.new(:invalid_node, "node struct must implement invoke/2 or invoke/3", %{
           module: module
         })}
    end
  end

  # The state a subgraph received (its `input_schema` keys of the node's
  # state) and the input it runs with. A subgraph that resumes, or continues
  # from a checkpoint, already holds what it received when it started: it runs
  # with no input, and its update is what it changed since it started, so the
  # writes made meanwhile beside it, by an update or by the caller's command,
  # stay. Without a checkpointer it has nothing to continue, and runs again on
  # what it started with.
  defp subgraph_input(compiled, state, runtime, opts) do
    received = CompiledRuntime.graph_input(compiled, state)

    cond do
      not continues_own_run?(opts) ->
        {received, received}

      is_nil(compiled.checkpointer) ->
        started = started_with(compiled, runtime, received)
        {started, started}

      true ->
        {started_with(compiled, runtime, received), %{}}
    end
  end

  defp continues_own_run?(opts),
    do: Keyword.has_key?(opts, :resume) or Keyword.get(opts, :continue_from_checkpoint?, false)

  # What the task received when its step first ran, when it continues one.
  defp started_with(compiled, %{scratchpad: %{first_state: first}}, _received) when not is_nil(first),
    do: CompiledRuntime.graph_input(compiled, first)

  defp started_with(_compiled, _runtime, received), do: received

  # The subgraph's final state, cut to its `output_schema` keys, with what it
  # received; `invoke/4` turns it into the node's update.
  defp subgraph_result(compiled, received, output),
    do: %SubgraphResult{input: received, output: CompiledRuntime.graph_output(compiled, output)}

  defp maybe_continue_subgraph_checkpoint(opts) do
    config = Keyword.fetch!(opts, :config)
    configurable = BeamWeaver.Checkpoint.configurable(config)
    checkpoint_id = Map.get(configurable, "checkpoint_id")

    if is_binary(checkpoint_id) do
      opts
      |> Keyword.put(:continue_from_checkpoint?, true)
      |> maybe_clear_ancestor_pending_writes(configurable)
    else
      opts
    end
  end

  defp maybe_clear_ancestor_pending_writes(opts, configurable) do
    namespace = configurable |> Map.get("checkpoint_ns", "") |> Namespace.recast()
    target = configurable |> Map.get("checkpoint_target_ns") |> Namespace.recast()

    if target in ["", namespace],
      do: opts,
      else: Keyword.put(opts, :clear_pending_writes?, true)
  end

  defp project_input(%NodeSpec{input: nil}, state, _runtime), do: {:ok, state}

  defp project_input(%NodeSpec{input: keys}, state, _runtime) when is_list(keys) do
    {:ok,
     Map.new(keys, fn key ->
       {key, Map.get(state, key, Map.get(state, to_string(key)))}
     end)}
  end

  defp project_input(%NodeSpec{input: fun}, state, _runtime) when is_function(fun, 1),
    do: {:ok, fun.(state)}

  defp project_input(%NodeSpec{input: fun}, state, runtime) when is_function(fun, 2),
    do: {:ok, fun.(state, runtime)}

  defp project_input(%NodeSpec{input: input}, _state, _runtime) do
    {:error,
     Error.new(:invalid_node_input_projection, "node input projection is invalid", %{
       input: inspect(input)
     })}
  end

  # Without `output:`, a subgraph returns the keys it changed. An `output:`
  # projection receives the subgraph's whole final state instead.
  defp project_subgraph_output(%NodeSpec{output: nil}, result, _state, _runtime, graph),
    do: {:ok, subgraph_update(result, graph)}

  defp project_subgraph_output(spec, %SubgraphResult{output: output}, state, runtime, _graph),
    do: project_output(spec, output, state, runtime)

  defp project_output(%NodeSpec{output: nil}, output, _state, _runtime), do: {:ok, output}

  defp project_output(%NodeSpec{output: key}, %Command{} = command, _state, _runtime)
       when is_atom(key) or is_binary(key) do
    {:ok, %{command | update: %{key => command.update || %{}}}}
  end

  defp project_output(%NodeSpec{output: key}, output, _state, _runtime)
       when is_atom(key) or is_binary(key),
       do: {:ok, %{key => output}}

  defp project_output(
         %NodeSpec{output: [_first | _rest] = path},
         %Command{} = command,
         _state,
         _runtime
       ) do
    {:ok, %{command | update: put_path_update(path, command.update || %{})}}
  end

  defp project_output(%NodeSpec{output: [_first | _rest] = path}, output, _state, _runtime),
    do: {:ok, put_path_update(path, output)}

  defp project_output(%NodeSpec{output: fun}, output, _state, _runtime) when is_function(fun, 1),
    do: {:ok, fun.(output)}

  defp project_output(%NodeSpec{output: fun}, output, state, runtime) when is_function(fun, 3),
    do: {:ok, fun.(output, state, runtime)}

  defp project_output(%NodeSpec{output: output}, _value, _state, _runtime) do
    {:error,
     Error.new(:invalid_node_output_projection, "node output projection is invalid", %{
       output: inspect(output)
     })}
  end

  defp put_path_update([key], value), do: %{key => value}
  defp put_path_update([key | rest], value), do: %{key => put_path_update(rest, value)}

  # The update a subgraph's run makes to the graph that runs it: the output keys
  # whose value differs from what the subgraph received. A key with a reducer
  # gets only what the subgraph added (the new end of a list, the new or changed
  # entries of a map), so the reducer doesn't apply what the subgraph received
  # a second time; any other change replaces the reducer's value.
  defp subgraph_update(%SubgraphResult{input: received, output: output}, graph)
       when is_map(output) do
    Enum.reduce(output, %{}, fn {key, value}, update ->
      case MapAccess.fetch(received, key) do
        {:ok, ^value} ->
          update

        {:ok, before} ->
          Map.put(update, key, changed_value(ChannelLookup.channel_for(graph, key), before, value))

        :error ->
          Map.put(update, key, value)
      end
    end)
  end

  defp subgraph_update(%SubgraphResult{output: output}, _graph), do: output

  defp changed_value(%BinaryOperatorAggregate{}, before, value)
       when is_list(before) and is_list(value) do
    if List.starts_with?(value, before),
      do: Enum.drop(value, length(before)),
      else: Overwrite.new(value)
  end

  defp changed_value(%BinaryOperatorAggregate{}, before, value)
       when is_map(before) and is_map(value) and not is_struct(before) and not is_struct(value) do
    if Enum.all?(Map.keys(before), &Map.has_key?(value, &1)),
      do: Map.reject(value, fn {key, kept} -> Map.fetch(before, key) == {:ok, kept} end),
      else: Overwrite.new(value)
  end

  defp changed_value(%BinaryOperatorAggregate{}, _before, value), do: Overwrite.new(value)
  defp changed_value(%DeltaChannel{}, _before, value), do: Overwrite.new(value)
  defp changed_value(_channel, _before, value), do: value

  # What a subgraph run does with what its namespace already holds (see
  # `RunInit`). A resumed subgraph, or one replayed from a checkpoint, takes
  # its own path. When its task runs again, on a retry or because the parent
  # continues the step it stopped in, the subgraph continues its own run with
  # the changes to its input since the task first ran. A task's first run
  # starts it afresh, unless it keeps one thread across calls
  # (`checkpointer: true`), where the call adds to that thread.
  defp put_subgraph_thread(opts, compiled, runtime, received) do
    cond do
      continues_own_run?(opts) ->
        opts

      rerun?(runtime) ->
        Keyword.put(opts, :subgraph_thread, {:continue, input_changes(compiled, runtime, received)})

      compiled.checkpoint_scope == :shared ->
        opts

      true ->
        Keyword.put(opts, :subgraph_thread, :fresh)
    end
  end

  defp rerun?(%{scratchpad: %{first_state: first}}) when not is_nil(first), do: true
  defp rerun?(%{execution: %{node_attempt: attempt}}) when is_integer(attempt), do: attempt > 1
  defp rerun?(_runtime), do: false

  # Nothing changes between the attempts of a retry. In a step that the
  # parent continues, the state may have changed since the task first ran:
  # the writes of the tasks that finished in it, and the caller's new input.
  defp input_changes(compiled, %{scratchpad: %{first_state: first}}, received) when not is_nil(first) do
    subgraph_update(
      %SubgraphResult{input: CompiledRuntime.graph_input(compiled, first), output: received},
      compiled.graph
    )
  end

  defp input_changes(_compiled, _runtime, _received), do: %{}

  # The input of a task that continues a stopped step, as it was when the
  # step first ran, cut the way the node's input is.
  defp project_first_input(spec, %{scratchpad: %{first_state: first} = scratchpad} = runtime, graph)
       when not is_nil(first) do
    with {:ok, input} <- project_input(spec, subgraph_state(spec, first, graph), runtime),
         do: {:ok, %{runtime | scratchpad: %{scratchpad | first_state: input}}}
  end

  defp project_first_input(_spec, runtime, _graph), do: {:ok, runtime}

  defp maybe_put_subgraph_resume(opts, %{scratchpad: %{resume_values: [single]}}),
    do: Keyword.put(opts, :resume, single)

  defp maybe_put_subgraph_resume(opts, %{scratchpad: %{resume_values: [_first | _rest] = values}}),
    do: Keyword.put(opts, :resume, values)

  defp maybe_put_subgraph_resume(opts, _runtime), do: opts

  # The subgraph sends its events to the parent's stream as it runs.
  defp maybe_collect_subgraph_stream(opts, %{
         stream_sink: sink,
         stream_modes: stream_modes,
         graph_name: graph_name,
         task_id: task_id
       })
       when not is_nil(sink) do
    child_sink =
      BeamWeaver.Stream.Sink.child(sink, namespace: sink.namespace ++ ["#{graph_name}:#{task_id}"])

    opts
    |> Keyword.put(:stream_mode, stream_modes)
    |> Keyword.put(:stream_sink, child_sink)
  end

  defp maybe_collect_subgraph_stream(opts, _runtime), do: opts

  defp maybe_put_subgraph_recursion_limit(opts, %{recursion_limit: limit})
       when is_integer(limit) do
    Keyword.put(opts, :recursion_limit, max(limit, 0))
  end

  defp maybe_put_subgraph_recursion_limit(opts, _runtime), do: opts

  defp safe_call(fun) do
    fun.()
  rescue
    exception ->
      {:error,
       Error.new(:node_exception, Exception.message(exception), %{
         exception: inspect(exception.__struct__)
       })}
  catch
    :throw, {:beam_weaver_graph_interrupt, interrupt} ->
      {:interrupted, interrupt}

    :throw, {:beam_weaver_graph_parent_command, command} ->
      {:parent_command, command}

    :throw, {:beam_weaver_graph_error, %Error{} = error} ->
      {:error, error}

    kind, reason ->
      {:error,
       Error.new(:node_exit, "node exited before returning", %{
         kind: kind,
         root_cause: reason,
         reason: inspect(reason)
       })}
  end
end
