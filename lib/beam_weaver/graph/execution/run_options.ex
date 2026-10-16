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
    :clear_pending_writes?,
    :subgraph_thread
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
      stream_modes: stream_modes(opts),
      step_timeout: Options.normalize_timeout(Keyword.get(opts, :step_timeout, compiled.step_timeout)),
      run_timeout: run_timeout,
      recursion_limit: Keyword.get(opts, :recursion_limit, 25),
      run_id: Keyword.get_lazy(opts, :run_id, &ID.uuidv7/0),
      task_supervisor: Keyword.get(opts, :task_supervisor),
      stream_sink: Keyword.get(opts, :stream_sink),
      continue_from_checkpoint?: Keyword.get(opts, :continue_from_checkpoint?, false),
      command_goto: Keyword.get(opts, :command_goto),
      resume_fetch: Keyword.fetch(opts, :resume),
      resume_requested?: Keyword.has_key?(opts, :resume),
      clear_pending_writes?: Keyword.get(opts, :clear_pending_writes?, false),
      subgraph_thread: Keyword.get(opts, :subgraph_thread)
    }
  end

  # Only a run with a stream sink sends events; `stream_events/3` has already
  # checked the modes it passes.
  defp stream_modes(opts) do
    case Stream.normalize_modes(Keyword.get(opts, :stream_mode, :events)) do
      {:ok, modes} -> modes
      {:error, _error} -> MapSet.new([:events])
    end
  end
end
