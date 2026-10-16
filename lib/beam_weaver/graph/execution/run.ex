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
    :replay_input_updated_channels,
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
    replay_routes: []
  ]

  @type t :: %__MODULE__{}
end
