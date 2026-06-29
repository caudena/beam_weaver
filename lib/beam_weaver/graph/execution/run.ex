defmodule BeamWeaver.Graph.Execution.Run do
  @moduledoc """
  Immutable graph execution run state.

  The executor still owns orchestration, but this struct makes the runtime
  state explicit and keeps future graph execution transitions from becoming another
  mutable loop object.
  """

  defstruct [
    :compiled,
    :state,
    :ready,
    :config,
    :context,
    :model_opts,
    :stream_modes,
    :events,
    :step,
    :recursion_limit,
    :run_id,
    :channel_versions,
    :versions_seen,
    :task_trigger_versions,
    :replay_pending_writes,
    :replay_input_updated_channels,
    :failure_policy,
    :step_timeout,
    :run_timeout,
    :run_deadline,
    :step_deadline,
    :trace_context,
    :parent_pid,
    :task_supervisor,
    :stream_sink,
    :collect_stream?,
    :server_info,
    :resume,
    :skip_interrupt_before?
  ]

  @type t :: %__MODULE__{}
end
