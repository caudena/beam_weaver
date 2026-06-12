defmodule BeamWeaver.Tracing.Context do
  @moduledoc """
  Process-local trace context.
  """

  alias BeamWeaver.Tracing.Run

  @key {__MODULE__, :current}

  @enforce_keys [:run_id, :trace_id]
  defstruct [:run_id, :trace_id, tags: [], metadata: %{}]

  @type t :: %__MODULE__{
          run_id: Run.id(),
          trace_id: Run.id(),
          tags: [String.t()],
          metadata: map()
        }

  @doc """
  Returns the current process-local trace context.
  """
  @spec current() :: t() | nil
  def current do
    Process.get(@key)
  end

  @doc """
  Stores the current process-local trace context.
  """
  @spec put(t()) :: :ok
  def put(%__MODULE__{} = context) do
    Process.put(@key, context)
    :ok
  end

  @doc """
  Clears the current process-local trace context.
  """
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @doc """
  Runs `fun` with `context` installed, restoring the previous context afterwards.
  """
  @spec attach(t() | nil, (-> term())) :: term()
  def attach(context, fun) when is_function(fun, 0) do
    previous = current()

    try do
      if context, do: put(context), else: clear()
      fun.()
    after
      if previous, do: put(previous), else: clear()
    end
  end

  @doc """
  Builds context from a run.
  """
  @spec from_run(Run.t()) :: t()
  def from_run(%Run{} = run) do
    %__MODULE__{
      run_id: run.id,
      trace_id: run.trace_id,
      tags: run.tags,
      metadata: run.context_metadata || run.metadata
    }
  end
end
