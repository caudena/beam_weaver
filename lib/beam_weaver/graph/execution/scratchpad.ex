defmodule BeamWeaver.Graph.Execution.Scratchpad do
  @moduledoc false

  alias BeamWeaver.Graph.Interrupt
  alias BeamWeaver.Graph.Resume

  @process_key {__MODULE__, :current}

  defstruct [
    :task_id,
    :node,
    :step,
    :first_state,
    resume_values: [],
    consumed_resume_values: [],
    interrupt_counter: 0
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          node: String.t(),
          step: non_neg_integer(),
          first_state: term(),
          resume_values: list(),
          consumed_resume_values: list(),
          interrupt_counter: non_neg_integer()
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

  @doc "The scratchpad of the node this process runs, or `nil`."
  @spec current() :: t() | nil
  def current, do: Process.get(@process_key)

  @spec with(t(), (-> term())) :: term()
  def with(%__MODULE__{} = scratchpad, fun) when is_function(fun, 0) do
    Process.put(@process_key, scratchpad)

    try do
      fun.()
    after
      Process.delete(@process_key)
    end
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
        payload =
          :erlang.term_to_binary({scratchpad.task_id, scratchpad.node, scratchpad.step, scratchpad.interrupt_counter})

        interrupt = %Interrupt{
          id: "interrupt_" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower),
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

  defp consume_resume(scratchpad, rest, resume) do
    Process.put(@process_key, %{
      scratchpad
      | resume_values: rest,
        consumed_resume_values: scratchpad.consumed_resume_values ++ [resume],
        interrupt_counter: scratchpad.interrupt_counter + 1
    })
  end
end
