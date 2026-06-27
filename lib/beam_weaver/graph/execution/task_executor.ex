defmodule BeamWeaver.Graph.Execution.TaskExecutor do
  @moduledoc """
  graph execution task preparation and node execution.

  This module owns the boundary where pure graph execution task descriptions become
  supervised BEAM tasks.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.Cache
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.ExecutableTask
  alias BeamWeaver.Graph.Execution.NodeInvoker
  alias BeamWeaver.Graph.Execution.NodeOutput
  alias BeamWeaver.Graph.Execution.Retry
  alias BeamWeaver.Graph.Execution.Scratchpad
  alias BeamWeaver.Graph.Execution.Stream
  alias BeamWeaver.Graph.Execution.TaskLauncher
  alias BeamWeaver.Graph.Execution.TaskPlanner
  alias BeamWeaver.Graph.Execution.TaskResult
  alias BeamWeaver.Graph.Execution.TaskRun
  alias BeamWeaver.Graph.Execution.Telemetry
  alias BeamWeaver.Tracing

  @spec run_step_tasks(map()) :: [ExecutableTask.t()]
  def run_step_tasks(%{ready: ready} = run) do
    Enum.map(ready, fn ready_entry ->
      plan = TaskPlanner.prepare(run, ready_entry)
      prepared = plan.prepared
      task_run = TaskRun.new(run, plan)

      %ExecutableTask{
        id: prepared.id,
        node: prepared.node,
        path: prepared.path,
        step: prepared.step,
        timeout: outer_task_timeout(plan),
        started_at: plan.started_at,
        prepared: prepared,
        task: start_node_task(task_run)
      }
    end)
  end

  @doc false
  @spec normalize_task_timeout(term()) :: non_neg_integer() | :infinity
  defdelegate normalize_task_timeout(timeout), to: TaskPlanner

  defp start_node_task(%TaskRun{} = task_run) do
    TaskLauncher.start(task_run.run, fn -> execute_node(task_run) end)
  end

  defp outer_task_timeout(%{timeout: :infinity}), do: :infinity

  defp outer_task_timeout(%{timeout: timeout, spec: spec})
       when is_integer(timeout) and timeout > 0 do
    timeout * final_attempt(spec) + retry_delay_budget(spec) + 50
  end

  defp outer_task_timeout(_plan), do: :infinity

  defp execute_node(%TaskRun{} = task_run) do
    run = task_run.run
    spec = task_run.spec
    prepared = task_run.prepared

    Telemetry.execute(:node_start, %{system_time: System.system_time()}, %{
      graph: run.compiled.name,
      node: spec.name,
      step: run.step
    })

    started =
      Stream.task_event(:start, spec.name, task_run.state, run.step, prepared.id, prepared.path)

    cache_key = Cache.key(spec, %{compiled: run.compiled, state: task_run.state})

    first_attempt_time = System.system_time(:millisecond)

    result =
      if prepared.kind == :error_handler do
        run_error_handler_task(task_run, first_attempt_time)
      else
        case Cache.lookup(run.compiled.cache, cache_key) do
          {:hit, cached} ->
            Telemetry.execute(:cache_hit, %{count: 1}, %{
              graph: run.compiled.name,
              node: spec.name,
              step: run.step
            })

            {:ok, {:cached, cached}}

          {:error, %Error{} = error} ->
            {:error, error}

          :miss ->
            Telemetry.execute(:cache_miss, %{count: 1}, %{
              graph: run.compiled.name,
              node: spec.name,
              step: run.step
            })

            Retry.run(spec.retry_policy || spec.retry, fn attempt ->
              runtime = runtime_attempt(task_run.runtime, attempt, first_attempt_time)

              Scratchpad.with(task_run.scratchpad, fn ->
                invoke_attempt(task_run, runtime)
              end)
            end)
        end
        |> maybe_handle_node_error(task_run, first_attempt_time)
      end

    case result do
      {:ok, {:cached, %NodeOutput{projected: %Command{} = command} = output}} ->
        finish_command_task(task_run, cache_key, command, output, [
          started,
          Stream.task_event(:cache_hit, spec.name, command, run.step, prepared.id, prepared.path)
        ])

      {:ok, {:cached, %Command{} = command}} ->
        finish_command_task(task_run, cache_key, command, command, [
          started,
          Stream.task_event(:cache_hit, spec.name, command, run.step, prepared.id, prepared.path)
        ])

      {:ok, {:cached, value}} ->
        finish_successful_task(task_run, cache_key, value, [
          started,
          Stream.task_event(:cache_hit, spec.name, value, run.step, prepared.id, prepared.path)
        ])

      {:ok, %NodeOutput{projected: %Command{} = command} = output} ->
        finish_command_task(task_run, cache_key, command, output, [started])

      {:ok, %Command{} = command} ->
        finish_command_task(task_run, cache_key, command, command, [started])

      {:ok, value} ->
        finish_successful_task(task_run, cache_key, value, [started])

      {:error, %Error{} = error} ->
        emit_error_telemetry(error, task_run)
        failed = Stream.task_event(:error, spec.name, error, run.step, prepared.id, prepared.path)

        {:error, error, [started, failed]}

      {:interrupted, interrupt} ->
        interrupted =
          Stream.task_event(
            :interrupt,
            spec.name,
            interrupt,
            run.step,
            prepared.id,
            prepared.path
          )

        {:ok,
         TaskResult.interrupted(
           prepared.id,
           spec.name,
           prepared.path,
           run.step,
           interrupt,
           [started, interrupted]
         )}

      {:parent_command, command} ->
        parent_command_event =
          Stream.task_event(
            :parent_command,
            spec.name,
            command,
            run.step,
            prepared.id,
            prepared.path
          )

        {:ok,
         TaskResult.parent_command(
           prepared.id,
           spec.name,
           prepared.path,
           run.step,
           command,
           [started, parent_command_event]
         )}
    end
  end

  defp finish_command_task(%TaskRun{} = task_run, cache_key, %Command{} = command, value, events) do
    run = task_run.run
    spec = task_run.spec
    prepared = task_run.prepared

    case CommandRouter.scope(command, run) do
      {:current, command} ->
        value =
          case value do
            %NodeOutput{} = output -> %{output | projected: command}
            _other -> command
          end

        finish_successful_task(task_run, cache_key, value, events)

      {:parent, command} ->
        parent_command_event =
          Stream.task_event(
            :parent_command,
            spec.name,
            command,
            run.step,
            prepared.id,
            prepared.path
          )

        {:ok,
         TaskResult.parent_command(
           prepared.id,
           spec.name,
           prepared.path,
           run.step,
           command,
           events ++ [parent_command_event]
         )}
    end
  end

  defp runtime_attempt(runtime, attempt, first_attempt_time) do
    execution =
      runtime.execution
      |> Map.new()
      |> Map.put(:node_attempt, attempt)
      |> Map.put(:node_first_attempt_time, first_attempt_time)

    %{runtime | execution: execution}
  end

  defp invoke_attempt(%TaskRun{timeout: :infinity} = task_run, runtime) do
    NodeInvoker.invoke(task_run.spec, task_run.state, runtime)
  end

  defp invoke_attempt(%TaskRun{timeout: timeout} = task_run, runtime)
       when is_integer(timeout) and timeout > 0 do
    trace_context = Tracing.capture_context()

    task =
      Task.async(fn ->
        Tracing.attach_context(trace_context, fn ->
          Scratchpad.with(task_run.scratchpad, fn ->
            NodeInvoker.invoke(task_run.spec, task_run.state, runtime)
          end)
        end)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error,
         Error.new(:node_exit, "node task exited before returning", %{
           node: task_run.spec.name,
           step: task_run.run.step,
           root_cause: reason,
           reason: inspect(reason)
         })}

      nil ->
        {:error, node_timeout_error(task_run)}
    end
  end

  defp invoke_attempt(%TaskRun{} = task_run, runtime) do
    NodeInvoker.invoke(task_run.spec, task_run.state, runtime)
  end

  defp node_timeout_error(%TaskRun{} = task_run) do
    Error.new(:node_timeout, "node timed out", %{
      node: task_run.spec.name,
      step: task_run.run.step,
      timeout: task_run.timeout,
      node_timeout: task_run.timeout,
      step_timeout: task_run.run.step_timeout,
      run_timeout: task_run.run.run_timeout
    })
  end

  defp emit_error_telemetry(%Error{} = error, %TaskRun{} = task_run) do
    event =
      case error.type do
        :node_exit -> :node_exit
        :node_timeout -> :node_timeout
        _other -> :node_failure
      end

    Telemetry.execute(event, %{count: 1}, %{
      graph: task_run.run.compiled.name,
      node: task_run.spec.name,
      step: task_run.run.step,
      error: error
    })
  end

  defp run_error_handler_task(
         %TaskRun{spec: %{error_handler: handler}, error: %Error{} = error} = task_run,
         first_attempt_time
       )
       when not is_nil(handler) do
    attempt = final_attempt(task_run.spec)
    runtime = runtime_attempt(task_run.runtime, attempt, first_attempt_time)

    normalize_error_handler_result(
      call_error_handler(handler, error, task_run.state, runtime),
      error
    )
  end

  defp run_error_handler_task(%TaskRun{error: %Error{} = error}, _first_attempt_time),
    do: {:error, error}

  defp run_error_handler_task(%TaskRun{} = task_run, _first_attempt_time) do
    {:error,
     Error.new(:node_error_handler_invalid, "checkpointed error handler task has no error", %{
       node: task_run.spec.name
     })}
  end

  defp maybe_handle_node_error(
         {:error, %Error{} = error},
         %TaskRun{spec: %{error_handler: handler}} = task_run,
         first_attempt_time
       )
       when not is_nil(handler) do
    attempt = final_attempt(task_run.spec)
    runtime = runtime_attempt(task_run.runtime, attempt, first_attempt_time)

    normalize_error_handler_result(
      call_error_handler(handler, error, task_run.state, runtime),
      error
    )
  end

  defp maybe_handle_node_error(result, _task_run, _first_attempt_time), do: result

  defp normalize_error_handler_result(result, original_error) do
    case result do
      {:ok, %Command{} = command} ->
        {:ok, command}

      {:ok, {:error, %Error{} = handled_error}} ->
        {:error, handled_error}

      {:ok, {:ok, value}} ->
        {:ok, value}

      {:ok, value} ->
        {:ok, value}

      {:error, %Error{} = handler_error} ->
        {:error, remember_handled_error(handler_error, original_error)}
    end
  end

  defp remember_handled_error(%Error{} = handler_error, %Error{} = original_error) do
    put_in(handler_error.details[:handled_error], original_error)
  end

  defp final_attempt(%{retry_policy: %BeamWeaver.RetryPolicy{max_attempts: attempts}}),
    do: attempts

  defp final_attempt(%{retry: retries}) when is_integer(retries), do: retries + 1
  defp final_attempt(_spec), do: 1

  defp retry_delay_budget(%{retry_policy: %BeamWeaver.RetryPolicy{} = policy}) do
    1..max(policy.max_attempts - 1, 0)//1
    |> Enum.map(&BeamWeaver.RetryPolicy.delay(policy, &1))
    |> Enum.sum()
  end

  defp retry_delay_budget(_spec), do: 0

  defp call_error_handler(handler, error, state, runtime) when is_function(handler, 3) do
    {:ok, handler.(error, state, runtime)}
  rescue
    exception -> error_handler_exception(exception)
  end

  defp call_error_handler(handler, error, state, runtime) when is_function(handler, 2) do
    {:ok, handler.(error, %{state: state, runtime: runtime})}
  rescue
    exception -> error_handler_exception(exception)
  end

  defp call_error_handler(handler, error, _state, _runtime) when is_function(handler, 1) do
    {:ok, handler.(error)}
  rescue
    exception -> error_handler_exception(exception)
  end

  defp call_error_handler(handler, _error, _state, _runtime) do
    {:error,
     Error.new(:node_error_handler_invalid, "node error handler must be a function", %{
       handler: inspect(handler)
     })}
  end

  defp error_handler_exception(exception) do
    {:error,
     Error.new(:node_error_handler_failed, Exception.message(exception), %{
       exception: inspect(exception.__struct__)
     })}
  end

  defp finish_successful_task(%TaskRun{} = task_run, cache_key, value, started_events) do
    run = task_run.run
    spec = task_run.spec
    prepared = task_run.prepared

    Telemetry.execute(:node_stop, %{system_time: System.system_time()}, %{
      graph: run.compiled.name,
      node: spec.name,
      step: run.step
    })

    {projected, raw_output} = unwrap_node_output(value)

    normalized =
      projected
      |> CommandRouter.normalize_node_result()
      |> capture_node_output(spec.name, raw_output)

    updates = Map.get(normalized, :updates, update_list(normalized.update))

    case managed_write_error(updates, run.compiled.graph.managed) do
      nil ->
        case Cache.put(run.compiled.cache, cache_key, value) do
          :ok ->
            finished =
              Stream.task_event(
                :finish,
                spec.name,
                normalized.update,
                run.step,
                prepared.id,
                prepared.path
              )

            {:ok,
             TaskResult.ok(
               prepared.id,
               spec.name,
               prepared.path,
               run.step,
               normalized,
               started_events ++ [finished]
             )}

          {:error, %Error{} = error} ->
            failed = Stream.task_event(:error, spec.name, error, run.step, prepared.id, prepared.path)
            {:error, error, started_events ++ [failed]}
        end

      %Error{} = error ->
        failed =
          Stream.task_event(:error, spec.name, error, run.step, prepared.id, prepared.path)

        {:error, error, started_events ++ [failed]}
    end
  end

  defp managed_write_error(_updates, managed) when managed in [%{}, nil], do: nil

  defp managed_write_error(updates, managed) when is_list(updates) do
    Enum.find_value(updates, &managed_write_error(&1, managed))
  end

  defp managed_write_error(update, managed) do
    managed_keys = MapSet.new(Map.keys(managed), &to_string/1)

    written =
      update
      |> Map.keys()
      |> Enum.find(&(to_string(&1) in managed_keys))

    if written do
      Error.new(:invalid_update, "managed graph values are read-only", %{key: written})
    end
  end

  defp update_list(update) when update == %{}, do: []
  defp update_list(update) when is_map(update), do: [update]
  defp update_list(_update), do: []

  defp unwrap_node_output(%NodeOutput{projected: projected, raw: raw}), do: {projected, raw}
  defp unwrap_node_output(value), do: {value, :__beam_weaver_no_raw_output__}

  defp capture_node_output(normalized, _node, :__beam_weaver_no_raw_output__), do: normalized

  defp capture_node_output(normalized, node, raw_output) do
    updates = Map.get(normalized, :updates, update_list(normalized.update))

    Map.put(
      normalized,
      :updates,
      updates ++ [%{__node_outputs__: %{node => routable_output(raw_output)}}]
    )
  end

  defp routable_output(%Command{} = command), do: CommandRouter.command_update(command)
  defp routable_output(value), do: value
end
