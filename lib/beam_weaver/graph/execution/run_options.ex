defmodule BeamWeaver.Graph.Execution.RunOptions do
  @moduledoc false

  alias BeamWeaver.Core.ID
  alias BeamWeaver.Graph.Execution.Options
  alias BeamWeaver.Graph.Execution.Stream
  alias BeamWeaver.Tracing.Options, as: TraceOptions

  defstruct [
    :config,
    :trace,
    :context,
    :model_opts,
    :stream_modes,
    :collect_stream?,
    :failure_policy,
    :step_timeout,
    :run_timeout,
    :recursion_limit,
    :run_id,
    :task_supervisor,
    :stream_sink,
    :continue_from_checkpoint?,
    :command_goto,
    :resume_fetch,
    :resume_requested?,
    :clear_pending_writes?
  ]

  @type t :: %__MODULE__{}

  @spec from(map(), keyword()) :: t()
  def from(compiled, opts) do
    run_timeout = Options.normalize_timeout(Keyword.get(opts, :run_timeout, compiled.run_timeout))
    trace = Keyword.get(opts, :trace)

    config =
      opts
      |> Keyword.get(:config, %{})
      |> Options.normalize_config()
      |> TraceOptions.put_thread_id_config(trace)

    %__MODULE__{
      config: config,
      trace: trace,
      context: Keyword.get(opts, :context),
      model_opts: Keyword.get(opts, :model_opts, []),
      stream_modes: Stream.normalize_modes(Keyword.get(opts, :stream_mode, :updates)),
      collect_stream?: Keyword.get(opts, :collect_stream?, false),
      failure_policy: Options.normalize_failure_policy(Keyword.get(opts, :failure_policy, compiled.failure_policy)),
      step_timeout: Options.normalize_timeout(Keyword.get(opts, :step_timeout, compiled.step_timeout)),
      run_timeout: run_timeout,
      recursion_limit: Keyword.get(opts, :recursion_limit, 25),
      run_id: new_run_id(),
      task_supervisor: Keyword.get(opts, :task_supervisor),
      stream_sink: Keyword.get(opts, :stream_sink),
      continue_from_checkpoint?: Keyword.get(opts, :continue_from_checkpoint?, false),
      command_goto: Keyword.get(opts, :command_goto),
      resume_fetch: Keyword.fetch(opts, :resume),
      resume_requested?: Keyword.has_key?(opts, :resume),
      clear_pending_writes?: Keyword.get(opts, :clear_pending_writes?, false)
    }
  end

  defp new_run_id do
    ID.uuidv7()
  end
end
