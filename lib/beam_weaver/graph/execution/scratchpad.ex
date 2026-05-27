defmodule BeamWeaver.Graph.Execution.Scratchpad do
  @moduledoc """
  Per-task graph execution scratchpad.

  LangGraph uses a scratchpad to track resume values, interrupt counters, call
  counters, and subgraph counters. In BeamWeaver this is an immutable struct
  stored in the executing process dictionary only for the lifetime of one node
  invocation, so `BeamWeaver.Graph.interrupt/1` can be called without passing a
  runtime argument through every user function.
  """

  alias BeamWeaver.Graph.Interrupt
  alias BeamWeaver.Graph.Resume

  @process_key {__MODULE__, :current}

  defstruct [
    :task_id,
    :node,
    :step,
    resume_values: [],
    consumed_resume_values: [],
    interrupt_counter: 0,
    call_counter: 0,
    subgraph_counter: 0
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          node: String.t(),
          step: non_neg_integer(),
          resume_values: list(),
          consumed_resume_values: list(),
          interrupt_counter: non_neg_integer(),
          call_counter: non_neg_integer(),
          subgraph_counter: non_neg_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      task_id: Keyword.fetch!(opts, :task_id),
      node: Keyword.fetch!(opts, :node),
      step: Keyword.fetch!(opts, :step),
      resume_values: List.wrap(Keyword.get(opts, :resume_values, []))
    }
  end

  @spec install(t()) :: :ok
  def install(%__MODULE__{} = scratchpad) do
    Process.put(@process_key, scratchpad)
    :ok
  end

  @spec clear() :: :ok
  def clear do
    Process.delete(@process_key)
    :ok
  end

  @spec with(t(), (-> term())) :: term()
  def with(%__MODULE__{} = scratchpad, fun) when is_function(fun, 0) do
    install(scratchpad)

    try do
      fun.()
    after
      clear()
    end
  end

  @spec next_call() :: non_neg_integer()
  def next_call do
    next_counter(:call_counter)
  end

  @spec next_subgraph() :: non_neg_integer()
  def next_subgraph do
    next_counter(:subgraph_counter)
  end

  @spec interrupt(term()) :: term() | no_return()
  def interrupt(value) do
    case Process.get(@process_key) do
      %__MODULE__{resume_values: [%Resume{null?: true} | rest]} = scratchpad ->
        consume_resume(scratchpad, rest, %Resume{null?: true})
        nil

      %__MODULE__{resume_values: [%Resume{value: resume} | rest]} = scratchpad ->
        consume_resume(scratchpad, rest, %Resume{value: resume})
        resume

      %__MODULE__{resume_values: [resume | rest]} = scratchpad ->
        consume_resume(scratchpad, rest, resume)
        resume

      %__MODULE__{} = scratchpad ->
        id = interrupt_id(scratchpad, scratchpad.interrupt_counter)

        interrupt = %Interrupt{
          id: id,
          value: value,
          task_id: scratchpad.task_id,
          node: scratchpad.node,
          step: scratchpad.step,
          resumes: scratchpad.consumed_resume_values
        }

        Process.put(@process_key, %{
          scratchpad
          | interrupt_counter: scratchpad.interrupt_counter + 1
        })

        throw({:beam_weaver_graph_interrupt, interrupt})

      _missing ->
        raise RuntimeError, "BeamWeaver.Graph.interrupt/1 can only be called inside a graph node"
    end
  end

  @spec interrupt_id(t(), non_neg_integer()) :: String.t()
  def interrupt_id(%__MODULE__{} = scratchpad, counter) do
    payload =
      :erlang.term_to_binary({scratchpad.task_id, scratchpad.node, scratchpad.step, counter})

    "interrupt_" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  defp next_counter(field) do
    case Process.get(@process_key) do
      %__MODULE__{} = scratchpad ->
        value = Map.fetch!(scratchpad, field)
        Process.put(@process_key, Map.put(scratchpad, field, value + 1))
        value

      _missing ->
        raise RuntimeError,
              "graph execution scratchpad counters can only be used inside a graph node"
    end
  end

  defp consume_resume(scratchpad, rest, resume) do
    Process.put(@process_key, %{
      scratchpad
      | resume_values: rest,
        consumed_resume_values: scratchpad.consumed_resume_values ++ [resume],
        interrupt_counter: scratchpad.interrupt_counter + 1
    })
  end
end
