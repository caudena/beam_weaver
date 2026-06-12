defmodule BeamWeaver.Graph.Execution.NodeInvoker do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.Namespace
  alias BeamWeaver.Graph.Execution.NodeOutput
  alias BeamWeaver.Graph.Execution.SubgraphRouter
  alias BeamWeaver.Graph.NodeSpec

  @compiled BeamWeaver.Graph.Compiled

  @spec invoke(term(), map(), map()) ::
          {:ok, term()}
          | {:error, Error.t()}
          | {:interrupted, term()}
          | {:parent_command, Command.t()}
  def invoke(%NodeSpec{} = spec, state, runtime) do
    safe_call(fn ->
      with {:ok, input} <- project_input(spec, state, runtime),
           {:ok, output} <- call_node(spec.fun, input, runtime) do
        case output do
          %Command{graph: graph} = command when graph in [:parent, "parent", "__parent__"] ->
            command

          {:error, %Error{}} = error ->
            error

          output ->
            with {:ok, projected} <- project_output(spec, output, state, runtime) do
              %NodeOutput{raw: output, projected: projected}
            end
        end
      end
    end)
  end

  def invoke(fun, state, runtime) do
    safe_call(fn ->
      case call_node(fun, state, runtime) do
        {:ok, value} -> value
        other -> other
      end
    end)
  end

  defp call_node(fun, state, _runtime) when is_function(fun, 1), do: {:ok, fun.(state)}
  defp call_node(fun, state, runtime) when is_function(fun, 2), do: {:ok, fun.(state, runtime)}

  defp call_node(module, state, runtime) when is_atom(module) do
    if function_exported?(module, :invoke, 2) do
      {:ok, module.invoke(state, runtime)}
    else
      maybe_call_agent(module, state, runtime)
    end
  end

  defp call_node(%{__struct__: @compiled} = compiled, state, runtime) do
    compiled = SubgraphRouter.inherit_runtime_adapters(compiled, runtime)

    opts =
      [
        config: SubgraphRouter.config(runtime, compiled),
        context: runtime.context
      ]
      |> maybe_continue_subgraph_checkpoint()
      |> maybe_collect_subgraph_stream(runtime)
      |> maybe_put_subgraph_recursion_limit(runtime)
      |> maybe_put_subgraph_resume(runtime)

    case BeamWeaver.Graph.Execution.Runner.execute(compiled, state, opts) do
      {:ok, value, events} ->
        forward_subgraph_events(events, runtime)
        {:ok, value}

      {:parent_command, command, events} ->
        forward_subgraph_events(events, runtime)
        {:ok, SubgraphRouter.resolve_command(command, compiled, runtime)}

      {:interrupted, interrupt, events} ->
        forward_subgraph_events(events, runtime)
        throw({:beam_weaver_graph_interrupt, interrupt})

      {:error, %Error{} = error, events} ->
        forward_subgraph_events(events, runtime)
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

  defp call_node(_fun, _state, _runtime) do
    {:error, Error.new(:invalid_node, "node must be a function with arity 1 or 2 or a module")}
  end

  defp maybe_call_agent(module, state, runtime) do
    cond do
      function_exported?(module, :compiled_graph, 0) ->
        call_node(module.compiled_graph(), state, runtime)

      function_exported?(module, :compile, 1) ->
        case module.compile([]) do
          {:ok, compiled} -> call_node(compiled, state, runtime)
          compiled -> call_node(compiled, state, runtime)
        end

      true ->
        {:error, Error.new(:invalid_node, "node module must implement invoke/2", %{module: module})}
    end
  end

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

  defp maybe_put_subgraph_resume(opts, %{scratchpad: %{resume_values: [_first | _rest] = values}}) do
    Keyword.put(opts, :resume, subgraph_resume(values))
  end

  defp maybe_put_subgraph_resume(opts, _runtime), do: opts
  defp subgraph_resume([single]), do: single
  defp subgraph_resume(values), do: values

  defp maybe_collect_subgraph_stream(opts, %{
         stream_sink: sink,
         graph_name: graph_name,
         task_id: task_id
       })
       when not is_nil(sink) do
    child_sink =
      BeamWeaver.Stream.Sink.child(sink,
        name: graph_name,
        namespace: sink.namespace ++ ["#{graph_name}:#{task_id}"]
      )

    opts
    |> Keyword.put(:collect_stream?, true)
    |> Keyword.put(:stream_mode, :events)
    |> Keyword.put(:stream_sink, child_sink)
  end

  defp maybe_collect_subgraph_stream(opts, %{collect_stream?: true}) do
    opts
    |> Keyword.put(:collect_stream?, true)
    |> Keyword.put(:stream_mode, :events)
  end

  defp maybe_collect_subgraph_stream(opts, _runtime), do: opts

  defp forward_subgraph_events(events, %{stream_sink: sink}) when not is_nil(sink) do
    Enum.each(events, fn event -> BeamWeaver.Stream.Sink.emit(sink, event) end)
  end

  defp forward_subgraph_events(events, %{collect_stream?: true, stream_writer: writer})
       when is_list(events) and is_function(writer, 1) do
    Enum.each(events, fn event -> writer.(event) end)
  end

  defp forward_subgraph_events(_events, _runtime), do: :ok

  defp maybe_put_subgraph_recursion_limit(opts, %{recursion_limit: limit})
       when is_integer(limit) do
    Keyword.put(opts, :recursion_limit, max(limit, 0))
  end

  defp maybe_put_subgraph_recursion_limit(opts, _runtime), do: opts

  defp safe_call(fun) do
    case fun.() do
      {:ok, %Command{graph: graph} = command} when graph in [:parent, "parent", "__parent__"] ->
        {:parent_command, command}

      {:ok, {:error, %Error{} = error}} ->
        {:error, error}

      {:ok, value} ->
        {:ok, value}

      %Command{graph: graph} = command when graph in [:parent, "parent", "__parent__"] ->
        {:parent_command, command}

      {:error, %Error{} = error} ->
        {:error, error}

      value ->
        {:ok, value}
    end
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

    kind, reason ->
      {:error,
       Error.new(:node_exit, "node exited before returning", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end
end
