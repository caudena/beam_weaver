defmodule BeamWeaver.Graph.Execution.StepTransition do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelMerge
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.Halt
  alias BeamWeaver.Graph.Execution.Route
  alias BeamWeaver.Graph.Execution.Run
  alias BeamWeaver.Graph.Execution.Scheduler
  alias BeamWeaver.Graph.Execution.StepOutcome
  alias BeamWeaver.Graph.Execution.Stream
  alias BeamWeaver.Graph.Execution.TaskCollector
  alias BeamWeaver.Graph.Execution.TaskExecutor

  @spec advance(Run.t()) ::
          {:continue, Run.t()}
          | {:halt, {:interrupted, map()} | {:parent_command, term()} | {:error, Error.t()}}
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
        {:halt, {:interrupted, interrupt}}
    end
  end

  defp complete_step(run, ready, %StepOutcome{} = outcome) do
    compiled = run.compiled

    # A step that continues one that stopped partway also routes from the
    # tasks that had finished then.
    routes = run.replay_routes ++ outcome.routes
    completed = Enum.map(run.replay_routes, & &1.node) ++ CheckpointIO.ready_names(ready)
    routing_state = Route.put_outputs(outcome.state, run.replay_routes, compiled.graph)

    case Scheduler.prepare_next_tasks(compiled.plan || compiled.graph, routes, routing_state) do
      {:ok, schedule} -> schedule_next_step(run, ready, outcome, completed, routing_state, schedule)
      {:error, %Error{} = error} -> {:halt, {:error, error}}
    end
  end

  defp schedule_next_step(run, ready, outcome, completed, routing_state, schedule) do
    compiled = run.compiled

    case ChannelMerge.merge_step_updates(routing_state, schedule.updates, compiled.graph) do
      {:ok, schedule_step_update, scheduled_state} ->
        public_step_update =
          outcome.step_update
          |> Map.merge(schedule_step_update)
          |> Scheduler.hide_node_outputs()

        updated_channels =
          (Execution.updated_channels(public_step_update) ++
             schedule.channels ++
             Execution.pending_channels(run.replay_pending_writes) ++
             run.replay_input_updated_channels)
          |> Execution.normalize_channels()
          |> Enum.reject(&Scheduler.node_outputs_channel?/1)

        next_ready =
          Scheduler.add_channel_tasks(
            compiled.plan || compiled.graph,
            schedule.ready,
            updated_channels
          )

        versions_seen = Execution.mark_versions_seen(run.versions_seen, completed, run.channel_versions)

        channel_versions =
          Execution.next_channel_versions(
            compiled.checkpointer,
            run.channel_versions,
            updated_channels,
            compiled.graph
          )

        Stream.emit_tasks(run, outcome.events)
        Stream.emit_step(run, ready, public_step_update, scheduled_state)

        metadata = %{
          source: "loop",
          step: run.step,
          run_id: run.run_id,
          nodes: completed,
          next: CheckpointIO.ready_names(next_ready),
          next_tasks: CheckpointIO.checkpoint_next_records(next_ready, compiled.graph),
          tasks: CheckpointIO.checkpoint_task_records(outcome.events),
          interrupts: [],
          channel_versions: channel_versions,
          versions_seen: versions_seen,
          updated_channels: updated_channels,
          step_update: public_step_update
        }

        case CheckpointIO.maybe_write_checkpoint(compiled, run.config, scheduled_state, metadata, run.known_checkpoint) do
          {:ok, config, known_checkpoint} ->
            Stream.emit_checkpoint(run, config, scheduled_state)

            case interrupted_after(%{run | state: scheduled_state}, completed) do
              nil ->
                {:continue,
                 %{
                   run
                   | state: scheduled_state,
                     ready: next_ready,
                     config: config,
                     known_checkpoint: known_checkpoint,
                     channel_versions: channel_versions,
                     versions_seen: versions_seen,
                     task_trigger_versions: channel_versions,
                     replay_pending_writes: [],
                     replay_routes: [],
                     replay_input_updated_channels: [],
                     skip_interrupt_before?: false,
                     continued_from: nil,
                     step: run.step + 1
                 }}

              interrupt ->
                {:halt, {:interrupted, interrupt}}
            end

          {:error, %Error{} = error} ->
            {:halt, {:error, error}}
        end

      {:error, %Error{} = error} ->
        {:halt, {:error, error}}
    end
  end

  defp halt_with_pending(run, %Halt{} = halt) do
    Stream.emit_tasks(run, halt.events)

    case CheckpointIO.persist_pending_writes(run, halt.pending_writes) do
      :ok -> {:halt, {halt.reason, halt.payload}}
      {:error, %Error{} = persist_error} -> {:halt, {:error, persist_error}}
    end
  end

  defp interrupted_before(%{skip_interrupt_before?: true}, _ready), do: nil
  defp interrupted_before(_run, []), do: nil

  defp interrupted_before(run, ready),
    do: TaskCollector.interrupt_for(run.compiled.interrupt_before, ready, run, :before)

  defp interrupted_after(run, ready),
    do: TaskCollector.interrupt_for(run.compiled.interrupt_after, ready, run, :after)
end
