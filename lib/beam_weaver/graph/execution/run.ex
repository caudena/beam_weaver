defmodule BeamWeaver.Graph.Execution.Run do
  @moduledoc false

  defstruct [
    :compiled,
    :state,
    :ready,
    :config,
    :context,
    :model_opts,
    :stream_modes,
    :step,
    :recursion_limit,
    :run_id,
    :channel_versions,
    :versions_seen,
    :task_trigger_versions,
    :replay_pending_writes,
    :step_timeout,
    :run_timeout,
    :run_deadline,
    :step_deadline,
    :trace_context,
    :task_supervisor,
    :stream_sink,
    :server_info,
    :resume,
    :skip_interrupt_before?,
    :continued_from,
    # The checkpoint `config` names, as `CheckpointIO.known_checkpoint()`.
    :known_checkpoint,
    # The channels written for the run's first step before it ran: by the
    # tasks that finished in a step that stopped partway, by updates made
    # while it was stopped, and by the run's input.
    replayed_channels: [],
    replay_routes: []
  ]

  @type t :: %__MODULE__{}
end
