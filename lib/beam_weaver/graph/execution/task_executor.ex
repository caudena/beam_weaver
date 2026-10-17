defmodule BeamWeaver.Graph.Execution.TaskExecutor do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.RetryPolicy
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.Cache
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.ExecutableTask
  alias BeamWeaver.Graph.Execution.NodeInvoker
  alias BeamWeaver.Graph.Execution.NodeOutput
  alias BeamWeaver.Graph.Execution.Scratchpad
  alias BeamWeaver.Graph.Execution.Stream
  alias BeamWeaver.Graph.Execution.TaskPlanner
  alias BeamWeaver.Graph.Execution.TaskResult
  alias BeamWeaver.Graph.Execution.TaskRun
  alias BeamWeaver.Graph.Execution.Telemetry
  alias BeamWeaver.Tracing

  @spec run_step_tasks(map()) :: [ExecutableTask.t()]
  def run_step_tasks(%{ready: ready} = run) do
    Enum.map(ready, fn ready_entry ->
      case TaskPlanner.prepare(run, ready_entry) do
        {:ok, plan} -> start_task(run, plan)
        {:error, %Error{} = error, prepared} -> failed_task(run, prepared, error)
      end
    end)
  end

  defp start_task(run, plan) do
    prepared = plan.prepared

    %ExecutableTask{
      id: prepared.id,
      node: prepared.node,
      path: prepared.path,
      step: prepared.step,
      timeout: plan.timeout,
      deadline: task_deadline(plan),
      prepared: prepared,
      task: start_node_task(TaskRun.new(run, plan))
    }
  end

  # A task that can't start fails as a node that returns an error does,
  # without running the node, its retries or its error handler: the step's
  # other tasks finish and the run returns the error.
  defp failed_task(run, prepared, error) do
    Telemetry.execute(:node_failure, %{count: 1}, %{
      graph: run.compiled.name,
      node: prepared.node,
      step: run.step,
      error: error
    })

    failed = Stream.task_event(:error, prepared.node, error, run.step, prepared.id, prepared.path)

    %ExecutableTask{
      id: prepared.id,
      node: prepared.node,
      path: prepared.path,
      step: prepared.step,
      timeout: :infinity,
      deadline: :infinity,
      prepared: prepared,
      task: Task.completed({:error, error, [failed]})
    }
  end

  defp start_node_task(%TaskRun{} = task_run) do
    Tracing.async(fn -> execute_node(task_run) end,
      context: Map.get(task_run.run, :trace_context),
      supervisor: task_run.run.task_supervisor
    )
  end

  # The awaiter's backstop for the whole task: every attempt's node timeout plus
  # the retry delays between them, with slack so the per-attempt timeout in
  # `invoke_attempt/2` normally fires first. Either way the task fails with the
  # same `:node_timeout` error.
  defp task_deadline(%{timeout: timeout, spec: spec, started_at: started_at})
       when is_integer(timeout) and timeout > 0 do
    started_at + timeout * spec.retry_policy.max_attempts + retry_delay_budget(spec.retry_policy) + 50
  end

  defp task_deadline(_plan), do: :infinity

  defp execute_node(%TaskRun{} = task_run) do
    run = task_run.run
    spec = task_run.spec
    prepared = task_run.prepared

    started_at =
      Telemetry.start(:node_start, %{graph: run.compiled.name, node: spec.name, step: run.step})

    task_run = %{task_run | started_at: started_at}

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

            RetryPolicy.run(
              retry_policy(spec.retry_policy),
              fn attempt ->
                runtime = runtime_attempt(task_run.runtime, attempt, first_attempt_time)
                Scratchpad.with(task_run.scratchpad, fn -> invoke_attempt(task_run, runtime) end)
              end,
              on_retry: &Telemetry.execute(:retry, %{count: 1}, %{error: &2, attempt: &1})
            )
        end
        |> maybe_handle_node_error(task_run, first_attempt_time)
      end

    case result do
      {:ok, {:cached, value}} ->
        hit = Stream.task_event(:cache_hit, spec.name, command_of(value) || value, run.step, prepared.id, prepared.path)
        finish_task(task_run, nil, value, [started, hit])

      {:ok, {:fallback, value}} ->
        finish_task(task_run, nil, value, [started])

      {:ok, value} ->
        finish_task(task_run, cache_key, value, [started])

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
        parent_command_result(task_run, command, [started])
    end
  end

  defp finish_task(task_run, cache_key, value, events) do
    case command_of(value) do
      nil -> finish_successful_task(task_run, cache_key, value, events)
      command -> finish_command_task(task_run, cache_key, command, value, events)
    end
  end

  defp command_of(%NodeOutput{projected: %Command{} = command}), do: command
  defp command_of(%Command{} = command), do: command
  defp command_of(_value), do: nil

  defp finish_command_task(%TaskRun{} = task_run, cache_key, %Command{} = command, value, events) do
    case CommandRouter.scope(command, task_run.run) do
      {:current, command} ->
        value =
          case value do
            %NodeOutput{} = output -> %{output | projected: command}
            _other -> command
          end

        finish_successful_task(task_run, cache_key, value, events)

      {:parent, command} ->
        parent_command_result(task_run, command, events)
    end
  end

  defp parent_command_result(%TaskRun{run: run, spec: spec, prepared: prepared}, command, events) do
    event = Stream.task_event(:parent_command, spec.name, command, run.step, prepared.id, prepared.path)
    {:ok, TaskResult.parent_command(prepared.id, spec.name, prepared.path, run.step, command, events ++ [event])}
  end

  defp runtime_attempt(runtime, attempt, first_attempt_time) do
    execution =
      runtime.execution
      |> Map.new()
      |> Map.put(:node_attempt, attempt)
      |> Map.put(:node_first_attempt_time, first_attempt_time)

    %{runtime | execution: execution}
  end

  defp invoke_attempt(%TaskRun{timeout: timeout} = task_run, runtime)
       when is_integer(timeout) and timeout > 0 do
    task =
      Tracing.async(fn ->
        Scratchpad.with(task_run.scratchpad, fn ->
          NodeInvoker.invoke(task_run.spec, task_run.state, runtime, task_run.run.compiled.graph)
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
    NodeInvoker.invoke(task_run.spec, task_run.state, runtime, task_run.run.compiled.graph)
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

  defp run_error_handler_task(%TaskRun{error: %Error{} = error} = task_run, first_attempt_time),
    do: maybe_handle_node_error({:error, error}, task_run, first_attempt_time)

  defp run_error_handler_task(%TaskRun{} = task_run, _first_attempt_time) do
    {:error,
     Error.new(:node_error_handler_invalid, "checkpointed error handler task has no error", %{
       node: task_run.spec.name
     })}
  end

  # An answer that doesn't match its interrupt's `response_schema` is the same
  # on every attempt, so it is never retried, whatever the policy.
  defp retry_policy(%RetryPolicy{} = policy),
    do: %{policy | retry_on: &(not match?(%Error{type: :invalid_resume}, &1) and RetryPolicy.retry?(policy, &1))}

  # An answer that doesn't match its interrupt's `response_schema` waits for
  # another answer: a fallback would take the interrupt's place.
  defp maybe_handle_node_error({:error, %Error{type: :invalid_resume}} = result, _task_run, _first_attempt_time),
    do: result

  defp maybe_handle_node_error(
         {:error, %Error{} = error},
         %TaskRun{spec: %{error_handler: handler}} = task_run,
         first_attempt_time
       )
       when not is_nil(handler) do
    runtime = runtime_attempt(task_run.runtime, task_run.spec.retry_policy.max_attempts, first_attempt_time)

    # A fallback isn't the node's result, so it isn't cached.
    with {:ok, value} <-
           handler
           |> call_error_handler(error, task_run.state, runtime)
           |> normalize_error_handler_result(error, task_run.spec.name),
         do: {:ok, {:fallback, value}}
  end

  defp maybe_handle_node_error(result, _task_run, _first_attempt_time), do: result

  defp normalize_error_handler_result(result, original_error, node) do
    case result do
      {:ok, %Command{} = command} ->
        {:ok, command}

      {:ok, {:error, %Error{} = handled_error}} ->
        {:error, handled_error}

      {:ok, {:error, reason}} ->
        {:error, NodeInvoker.node_error(node, reason)}

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

  defp retry_delay_budget(%RetryPolicy{} = policy) do
    1..max(policy.max_attempts - 1, 0)//1
    |> Enum.map(&RetryPolicy.delay(policy, &1))
    |> Enum.sum()
  end

  defp call_error_handler(handler, error, state, runtime) do
    cond do
      is_function(handler, 3) ->
        {:ok, handler.(error, state, runtime)}

      is_function(handler, 2) ->
        {:ok, handler.(error, %{state: state, runtime: runtime})}

      is_function(handler, 1) ->
        {:ok, handler.(error)}

      true ->
        {:error,
         Error.new(:node_error_handler_invalid, "node error handler must be a function", %{
           handler: inspect(handler)
         })}
    end
  rescue
    exception ->
      {:error,
       Error.new(:node_error_handler_failed, Exception.message(exception), %{
         exception: inspect(exception.__struct__)
       })}
  end

  defp finish_successful_task(%TaskRun{} = task_run, cache_key, value, started_events) do
    run = task_run.run
    spec = task_run.spec
    prepared = task_run.prepared

    Telemetry.stop(:node_stop, task_run.started_at, %{
      graph: run.compiled.name,
      node: spec.name,
      step: run.step
    })

    {projected, raw_output} = unwrap_node_output(value)

    normalized =
      projected
      |> CommandRouter.normalize_node_result()
      |> capture_node_output(spec.name, raw_output)

    case managed_write_error(normalized.updates, run.compiled.graph.managed) do
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

  defp unwrap_node_output(%NodeOutput{projected: projected, raw: raw}), do: {projected, raw}
  defp unwrap_node_output(value), do: {value, :__beam_weaver_no_raw_output__}

  defp capture_node_output(normalized, _node, :__beam_weaver_no_raw_output__), do: normalized

  defp capture_node_output(normalized, node, raw_output) do
    %{normalized | updates: normalized.updates ++ [%{__node_outputs__: %{node => routable_output(raw_output)}}]}
  end

  defp routable_output(%Command{} = command), do: CommandRouter.command_update(command)
  defp routable_output(value), do: value
end
