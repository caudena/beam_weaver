defmodule BeamWeaver.Graph.Execution.RunInit do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelState
  alias BeamWeaver.Graph.Execution.CheckpointIO
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.Replay
  alias BeamWeaver.Graph.Execution.Run
  alias BeamWeaver.Graph.Execution.RunOptions
  alias BeamWeaver.Graph.Execution.TaskCollector
  alias BeamWeaver.Graph.ServerInfo

  @spec build(map(), map(), RunOptions.t(), term()) :: {:ok, Run.t()} | {:error, Error.t()}
  def build(compiled, input, %RunOptions{} = options, resume) do
    with {:ok, restored} <- Replay.restore_checkpoint_state(compiled, options.config) do
      build_from_restored(compiled, input, options, resume, restored)
    end
  end

  defp build_from_restored(compiled, input, %RunOptions{} = options, resume, restored) do
    restored = maybe_clear_pending_writes(restored, options)
    options = %{options | config: merge_pending_checkpoint_maps(options.config, restored)}

    explicit_checkpoint_continue? =
      Replay.continue_from_checkpoint?(options.config, input, restored)

    replay? =
      Replay.replay_pending?(restored) or
        options.continue_from_checkpoint? or
        explicit_checkpoint_continue?

    with {:ok, restored_values} <-
           ChannelState.apply_pending_writes(
             restored.values,
             restored.pending_writes,
             compiled.graph
           ),
         {:ok, initial_state} <- ChannelState.merge_update_result(restored_values, input, compiled.graph) do
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

      task_trigger_versions =
        Replay.task_trigger_versions(restored, input_channel_versions, replay?)

      fork_from_checkpoint? =
        (explicit_checkpoint_continue? or options.continue_from_checkpoint?) and
          not options.resume_requested?

      with {:ok, run_config} <-
             maybe_write_fork_checkpoint(
               compiled,
               options.config,
               restored,
               initial_state,
               initial_ready,
               fork_from_checkpoint?,
               options
             ),
           {:ok, config} <-
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
               }
             ) do
        {:ok,
         %Run{
           compiled: compiled,
           state: initial_state,
           ready: initial_ready,
           config: config,
           context: options.context,
           stream_modes: options.stream_modes,
           events: [],
           step: initial_step,
           recursion_limit: options.recursion_limit,
           run_id: options.run_id,
           channel_versions: input_channel_versions,
           versions_seen: restored.versions_seen,
           task_trigger_versions: task_trigger_versions,
           replay_pending_writes: if(replay?, do: restored.pending_writes, else: []),
           replay_input_updated_channels: if(replay?, do: input_updated_channels, else: []),
           failure_policy: options.failure_policy,
           step_timeout: options.step_timeout,
           run_timeout: options.run_timeout,
           run_deadline: TaskCollector.run_deadline(options.run_timeout),
           trace_context: BeamWeaver.Tracing.capture_context(),
           parent_pid: self(),
           task_supervisor: options.task_supervisor,
           stream_sink: options.stream_sink,
           collect_stream?: options.collect_stream?,
           server_info: ServerInfo.from_configurable(BeamWeaver.Checkpoint.configurable(options.config)),
           resume: resume,
           skip_interrupt_before?: options.resume_requested? or options.continue_from_checkpoint?
         }}
      end
    end
  end

  defp maybe_write_fork_checkpoint(
         compiled,
         config,
         restored,
         state,
         initial_ready,
         true,
         %RunOptions{} = options
       ) do
    CheckpointIO.write_checkpoint(compiled, config, state, %{
      source: "fork",
      step: restored.step,
      run_id: options.run_id,
      next: Replay.ready_names(initial_ready),
      next_tasks: Replay.checkpoint_next_records(initial_ready, compiled.graph),
      tasks: Map.get(restored, :tasks, []),
      interrupts: Map.get(restored, :interrupts, []),
      channel_versions: restored.channel_versions,
      versions_seen: restored.versions_seen,
      updated_channels: [],
      step_update: %{}
    })
  end

  defp maybe_write_fork_checkpoint(
         _compiled,
         config,
         _restored,
         _state,
         _ready,
         _continue?,
         _opts
       ),
       do: {:ok, config}

  defp maybe_clear_pending_writes(restored, %RunOptions{clear_pending_writes?: true}) do
    restored
    |> Map.put(:pending_writes, [])
    |> Map.put(:pending_write_paths, [])
    |> Map.put(:pending_write_records, [])
    |> Map.put(:interrupts, [])
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
