defmodule BeamWeaver.Graph.Execution.StepTransition do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelState
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.Halt
  alias BeamWeaver.Graph.Execution.Run
  alias BeamWeaver.Graph.Execution.Scheduler
  alias BeamWeaver.Graph.Execution.StepOutcome
  alias BeamWeaver.Graph.Execution.Stream
  alias BeamWeaver.Graph.Execution.TaskCollector
  alias BeamWeaver.Graph.Execution.TaskExecutor
  alias BeamWeaver.Graph.Send

  @spec advance(Run.t()) ::
          {:continue, Run.t()}
          | {:halt,
             {:interrupted, map(), list()}
             | {:parent_command, term(), list()}
             | {:error, Error.t(), list()}}
  def advance(%Run{ready: ready, compiled: compiled} = run) do
    case interrupted_before(run, ready) do
      nil ->
        run = Map.put(run, :step_deadline, TaskCollector.step_deadline(run.step_timeout))
        tasks = TaskExecutor.run_step_tasks(run)

        case TaskCollector.collect_tasks(tasks, run, compiled.graph) do
          {:ok, %StepOutcome{} = outcome} ->
            complete_step(run, ready, outcome)

          {:halt, %Halt{} = halt} ->
            halt_with_pending(run, halt)
        end

      interrupt ->
        {:halt, {:interrupted, interrupt, run.events}}
    end
  end

  defp complete_step(run, ready, %StepOutcome{} = outcome) do
    compiled = run.compiled

    schedule =
      Scheduler.prepare_next_tasks(
        compiled.plan || compiled.graph,
        ready,
        outcome.state,
        outcome.next,
        outcome.sends,
        &route_condition/2
      )

    case ChannelState.merge_step_updates(outcome.state, schedule.updates, compiled.graph) do
      {:ok, schedule_step_update, scheduled_state} ->
        public_step_update =
          outcome.step_update
          |> Map.merge(schedule_step_update)
          |> hide_ephemeral_internal_update()

        updated_channels =
          (Execution.updated_channels(public_step_update) ++
             schedule.channels ++
             Execution.pending_channels(run.replay_pending_writes) ++
             run.replay_input_updated_channels)
          |> Execution.normalize_channels()
          |> Enum.reject(&ephemeral_internal_channel?/1)

        next_ready =
          Scheduler.add_channel_tasks(
            compiled.plan || compiled.graph,
            schedule.ready,
            updated_channels
          )

        versions_seen =
          Execution.mark_versions_seen(
            run.versions_seen,
            CheckpointIO.ready_names(ready),
            run.channel_versions
          )

        channel_versions =
          Execution.next_channel_versions(
            compiled.checkpointer,
            run.channel_versions,
            updated_channels,
            compiled.graph
          )

        events =
          run.events
          |> Stream.add_events(outcome.events, run)
          |> Stream.add_step_events(run, ready, public_step_update, scheduled_state)

        case CheckpointIO.maybe_write_checkpoint(compiled, run.config, scheduled_state, %{
               source: "loop",
               step: run.step,
               run_id: run.run_id,
               nodes: ready,
               next: CheckpointIO.ready_names(next_ready),
               next_tasks: CheckpointIO.checkpoint_next_records(next_ready, compiled.graph),
               tasks: CheckpointIO.checkpoint_task_records(outcome.events),
               interrupts: [],
               channel_versions: channel_versions,
               versions_seen: versions_seen,
               updated_channels: updated_channels,
               step_update: public_step_update
             }) do
          {:ok, config} ->
            checkpoint_events = Stream.checkpoint_events(run, config, scheduled_state)
            events = Stream.add_events(events, checkpoint_events, run)

            case interrupted_after(%{run | state: scheduled_state, events: events}, ready) do
              nil ->
                {:continue,
                 %{
                   run
                   | state: scheduled_state,
                     ready: next_ready,
                     events: events,
                     config: config,
                     channel_versions: channel_versions,
                     versions_seen: versions_seen,
                     task_trigger_versions: channel_versions,
                     replay_pending_writes: [],
                     replay_input_updated_channels: [],
                     skip_interrupt_before?: false,
                     step: run.step + 1
                 }}

              interrupt ->
                {:halt, {:interrupted, interrupt, events}}
            end

          {:error, %Error{} = error} ->
            {:halt, {:error, error, events}}
        end

      {:error, %Error{} = error} ->
        {:halt, {:error, error, run.events}}
    end
  end

  defp halt_with_pending(run, %Halt{} = halt) do
    events = Stream.add_events(run.events, halt.events, run)

    case CheckpointIO.persist_pending_writes(run, halt.pending_writes) do
      :ok -> {:halt, {halt.reason, halt.payload, events}}
      {:error, %Error{} = persist_error} -> {:halt, {:error, persist_error, events}}
    end
  end

  defp interrupted_before(%{skip_interrupt_before?: true}, _ready), do: nil

  defp interrupted_before(run, ready),
    do: TaskCollector.interrupt_for(run.compiled.interrupt_before, ready, run, :before)

  defp interrupted_after(run, ready),
    do: TaskCollector.interrupt_for(run.compiled.interrupt_after, ready, run, :after)

  defp route_condition(spec, state) do
    result =
      case :erlang.fun_info(spec.router, :arity) do
        {:arity, 1} -> spec.router.(state)
        {:arity, 2} -> spec.router.(state, spec.path_map)
      end

    result
    |> List.wrap()
    |> Enum.map(fn
      %Send{} = send -> send
      route -> Map.get(spec.path_map, route, to_string(route))
    end)
    |> Enum.reject(&(&1 == "__end__"))
  end

  defp hide_ephemeral_internal_update(update) do
    update
    |> Map.delete(:__node_outputs__)
    |> Map.delete("__node_outputs__")
  end

  defp ephemeral_internal_channel?(channel), do: to_string(channel) == "__node_outputs__"
end
