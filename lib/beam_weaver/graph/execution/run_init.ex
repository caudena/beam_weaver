defmodule BeamWeaver.Graph.Execution.RunInit do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelMerge
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.Replay
  alias BeamWeaver.Graph.Execution.Resume, as: RunResume
  alias BeamWeaver.Graph.Execution.Route
  alias BeamWeaver.Graph.Execution.Run
  alias BeamWeaver.Graph.Execution.RunOptions
  alias BeamWeaver.Graph.Execution.StoppedStep
  alias BeamWeaver.Graph.Execution.SubgraphRouter
  alias BeamWeaver.Graph.Execution.TaskCollector
  alias BeamWeaver.Graph.ServerInfo

  @spec build(map(), map(), RunOptions.t(), term()) :: {:ok, Run.t()} | {:error, Error.t()}
  def build(compiled, input, %RunOptions{} = options, resume) do
    with {:ok, restored} <- Replay.restore_checkpoint_state(compiled, options.config) do
      {input, restored, continue_task?} = subgraph_thread(options.subgraph_thread, compiled, input, restored)
      build_from_restored(compiled, input, options, resume, restored, continue_task?)
    end
  end

  # A subgraph whose parent task runs again, on a retry or when the parent
  # continues the step it stopped in, continues the run it left, which holds
  # the state it was given then: it takes only what changed in its input
  # since. A task's first run starts the subgraph afresh, even when its
  # namespace holds an earlier run of the same task, as when the parent
  # replays an earlier checkpoint.
  defp subgraph_thread({:continue, changes}, compiled, input, restored) do
    if own_run?(compiled, restored),
      do: {changes, restored, true},
      else: {input, restored, false}
  end

  defp subgraph_thread(:fresh, _compiled, input, %{checkpoint?: true}),
    do: {input, Replay.empty_checkpoint_state(), false}

  defp subgraph_thread(_thread, _compiled, input, restored), do: {input, restored, false}

  # A subgraph's namespace holds its task's own run, except with
  # `checkpointer: true`, where one namespace serves every call: there only
  # a run that stopped partway is the task's own, a finished one belongs to
  # an earlier call.
  defp own_run?(_compiled, %{checkpoint?: false}), do: false

  defp own_run?(%{checkpoint_scope: :shared}, restored),
    do: restored.next != [] or restored.pending_writes != []

  defp own_run?(_compiled, _restored), do: true

  defp build_from_restored(compiled, input, %RunOptions{} = options, resume, restored, continue_task?) do
    restored = maybe_clear_pending_writes(restored, options)
    options = %{options | config: merge_pending_checkpoint_maps(options.config, restored)}

    explicit_checkpoint_continue? =
      Replay.continue_from_checkpoint?(options.config, input)

    continue? =
      options.continue_from_checkpoint? or explicit_checkpoint_continue? or
        continue_task? or
        Replay.continue_latest_checkpoint?(options.config, input, options.resume_requested?, restored)

    replay? = Replay.replay_pending?(restored) or continue?

    fork_from_checkpoint? =
      (explicit_checkpoint_continue? or options.continue_from_checkpoint?) and
        not options.resume_requested?

    flags = {replay?, continue?, fork_from_checkpoint?}

    if replay? and not fork_from_checkpoint? and not continue_task? and
         keep_stopped_step?(compiled, input, options.command_goto, restored, options.config) do
      with {:ok, config} <- update_stopped_step(compiled, input, options.command_goto, restored, options.config),
           {:ok, restored} <- Replay.restore_checkpoint_state(compiled, config) do
        start(compiled, %{}, %{options | config: config, command_goto: nil}, resume, restored, flags)
      end
    else
      start(compiled, input, options, resume, restored, flags)
    end
  end

  defp start(compiled, input, %RunOptions{} = options, resume, restored, {replay?, continue?, fork_from_checkpoint?}) do
    with {:ok, restored_values} <-
           ChannelMerge.apply_pending_writes(
             restored.values,
             restored.pending_writes,
             compiled.graph
           ),
         {:ok, initial_state} <-
           ChannelMerge.merge_update_result(run_values(restored_values, replay?), input, compiled.graph) do
      input_updated_channels =
        if replay? do
          Execution.updated_channels(input)
        else
          (Execution.updated_channels(input) ++ Execution.pending_channels(restored.pending_writes))
          |> Execution.normalize_channels()
        end

      input_channel_versions =
        Execution.next_channel_versions(
          compiled.checkpointer,
          restored.channel_versions,
          input_updated_channels,
          compiled.graph
        )

      initial_ready =
        compiled
        |> Replay.initial_ready(options.config, restored, replay?)
        |> CommandRouter.add_command_goto_tasks(options.command_goto)

      initial_step = Replay.initial_step(restored, replay?)

      task_trigger_versions = if replay?, do: restored.channel_versions, else: input_channel_versions

      with {:ok, continued_from} <-
             continued_from(compiled, options.config, restored, replay? and not fork_from_checkpoint?),
           {:ok, run_config} <-
             if(fork_from_checkpoint?,
               do:
                 write_fork_checkpoint(
                   compiled,
                   options.config,
                   restored,
                   initial_state,
                   initial_ready,
                   {input, input_updated_channels},
                   options
                 ),
               else: {:ok, options.config}
             ),
           {:ok, config, known_checkpoint} <-
             CheckpointIO.maybe_write_input_checkpoint(
               compiled,
               run_config,
               initial_state,
               replay?,
               %{
                 source: "input",
                 step: -1,
                 run_id: options.run_id,
                 next: Replay.ready_names(initial_ready),
                 next_tasks: Replay.checkpoint_next_records(initial_ready, compiled.graph),
                 tasks: [],
                 interrupts: [],
                 channel_versions: input_channel_versions,
                 versions_seen: restored.versions_seen,
                 updated_channels: input_updated_channels,
                 step_update: input
               },
               Map.get(restored, :known_checkpoint)
             ) do
        # When a run continues a checkpoint, a resume value that no pending
        # interrupt claims goes only to the tasks of its first step, the ones
        # the thread stopped before. A later interrupt still pauses the run.
        resume =
          if replay? do
            task_ids = Replay.task_ids(compiled, config, initial_step, task_trigger_versions, initial_ready)
            RunResume.for_tasks(resume, task_ids)
          else
            resume
          end

        {:ok,
         %Run{
           compiled: compiled,
           state: initial_state,
           ready: initial_ready,
           config: config,
           known_checkpoint: known_checkpoint,
           context: options.context,
           model_opts: options.model_opts,
           stream_modes: options.stream_modes,
           step: initial_step,
           recursion_limit: options.recursion_limit,
           run_id: options.run_id,
           channel_versions: input_channel_versions,
           versions_seen: restored.versions_seen,
           task_trigger_versions: task_trigger_versions,
           replay_pending_writes: if(replay?, do: restored.pending_writes, else: []),
           replay_routes: if(replay?, do: Route.from_writes(restored.pending_writes), else: []),
           replayed_channels:
             if(replay?,
               do: Execution.normalize_channels(StoppedStep.channels(restored) ++ input_updated_channels),
               else: []
             ),
           step_timeout: options.step_timeout,
           run_timeout: options.run_timeout,
           run_deadline: TaskCollector.deadline(options.run_timeout),
           trace_context: BeamWeaver.Tracing.capture_context(),
           task_supervisor: options.task_supervisor,
           stream_sink: options.stream_sink,
           server_info: ServerInfo.from_configurable(BeamWeaver.Checkpoint.configurable(options.config)),
           resume: resume,
           skip_interrupt_before?: options.resume_requested? or continue?,
           continued_from: continued_from
         }}
      end
    end
  end

  # A run that continues a step the thread stopped in, at a pause, a failure
  # or a breakpoint, with new input, such as a `Command`'s update, or with a
  # `Command`'s `goto`, saves the input and the `goto`'s tasks into that step
  # first, as `update_state/4` saves an update there, so they stay when the
  # step stops again. A run that continues a step stopped partway on an
  # earlier checkpoint than the thread's latest does the same with no input:
  # what the step writes then goes to a checkpoint of its own, and the branch
  # that already went on from that checkpoint doesn't see it.
  defp keep_stopped_step?(compiled, input, goto, restored, config) do
    stopped? = Replay.replay_pending?(restored)

    ((input != %{} or goto not in [nil, []]) and (stopped? or restored.next != [])) or
      (stopped? and not latest_checkpoint?(compiled, config, restored))
  end

  # The run goes on from the new checkpoint, with the rest of its config.
  defp update_stopped_step(compiled, input, goto, restored, config) do
    stopped = Execution.at_checkpoint(config, Execution.checkpoint_id(restored.checkpoint_config))

    with {:ok, updated} <- StoppedStep.save(compiled, stopped, restored, {:update, input}, nil, goto) do
      configurable = Map.merge(Checkpoint.configurable(config), Checkpoint.configurable(updated))
      {:ok, config |> Map.delete(:configurable) |> Map.put("configurable", configurable)}
    end
  end

  defp latest_checkpoint?(compiled, config, restored) do
    config = SubgraphRouter.checkpoint_config(compiled, config)

    is_nil(Execution.checkpoint_id(config)) or
      case Checkpoint.get_tuple(
             compiled.checkpointer,
             Execution.at_checkpoint(%{"configurable" => Checkpoint.configurable(config)}, nil)
           ) do
        %{config: latest} -> Execution.checkpoint_id(latest) == Execution.checkpoint_id(restored.checkpoint_config)
        nil -> true
      end
  end

  # In a step that a run continues, the state the step's tasks started from:
  # the checkpoint's own state, or, after an update made while the step was
  # stopped, the state of the checkpoint the step started from, when the
  # thread still has it. A replay that forks the checkpoint runs the step's
  # tasks afresh instead.
  defp continued_from(_compiled, _config, _restored, false), do: {:ok, nil}
  defp continued_from(_compiled, _config, %{step_start: nil} = restored, true), do: {:ok, restored.values}

  defp continued_from(compiled, config, restored, true) do
    step_start = Execution.at_checkpoint(%{"configurable" => Checkpoint.configurable(config)}, restored.step_start)

    case Replay.restore_checkpoint_state(compiled, step_start) do
      {:ok, %{checkpoint?: true, values: values}} -> {:ok, values}
      {:ok, _missing} -> {:ok, restored.values}
      {:error, %Error{}} = error -> error
    end
  end

  # The state a run starts from. `max_runs:` counts the times one run takes a
  # guarded edge: a run that continues the thread's checkpoint (`replay?`),
  # after an interrupt, a failure or an update, is the same run and keeps its
  # counts; a new run starts at zero.
  defp run_values(values, true), do: values
  defp run_values(values, false), do: Map.delete(values, :__edge_runs__)

  # The fork is a copy of the checkpoint it continues, with the writes of the
  # tasks that finished in a stopped step and the run's input, such as a
  # `Command`'s update, in its state. Their routes move along, so the step
  # still routes from those tasks when it completes, also when it stops again
  # first. The step keeps its number, so its tasks keep their ids.
  defp write_fork_checkpoint(
         compiled,
         config,
         restored,
         state,
         initial_ready,
         {input, input_updated_channels},
         %RunOptions{} = options
       ) do
    metadata = %{
      source: "fork",
      step: restored.step,
      run_id: options.run_id,
      next: Replay.ready_names(initial_ready),
      next_tasks: Replay.checkpoint_next_records(initial_ready, compiled.graph),
      tasks: [],
      interrupts: [],
      channel_versions: restored.channel_versions,
      versions_seen: restored.versions_seen,
      updated_channels: input_updated_channels,
      step_update: input
    }

    with {:ok, config, _known_checkpoint} <-
           CheckpointIO.write_checkpoint(compiled, config, state, metadata, Map.get(restored, :known_checkpoint)),
         :ok <-
           CheckpointIO.put_task_writes(
             compiled.checkpointer,
             config,
             CheckpointIO.pending_writes_on(restored, [Route.channel()])
           ) do
      {:ok, config}
    end
  end

  defp maybe_clear_pending_writes(restored, %RunOptions{clear_pending_writes?: true}) do
    %{restored | pending_writes: [], pending_write_paths: []}
  end

  defp maybe_clear_pending_writes(restored, _options), do: restored

  defp merge_pending_checkpoint_maps(config, %{pending_writes: pending_writes}) do
    checkpoint_map =
      pending_writes
      |> List.wrap()
      |> Enum.reduce(%{}, fn
        {_task_id, "__interrupt__", %{config: child_config}}, acc ->
          merge_child_checkpoint_map(acc, child_config)

        {_task_id, "__interrupt__", %{config: child_config}, _path}, acc ->
          merge_child_checkpoint_map(acc, child_config)

        _other, acc ->
          acc
      end)

    if map_size(checkpoint_map) > 0 do
      configurable = Map.get(config, "configurable") || %{}
      existing = Map.get(configurable, "checkpoint_map") || %{}
      configurable = Map.put(configurable, "checkpoint_map", Map.merge(checkpoint_map, existing))
      Map.put(config, "configurable", configurable)
    else
      config
    end
  end

  defp merge_child_checkpoint_map(acc, child_config) do
    case get_in(child_config, ["configurable", "checkpoint_map"]) do
      map when is_map(map) -> Map.merge(acc, map)
      _other -> acc
    end
  end
end
