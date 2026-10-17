defmodule BeamWeaver.Graph.Execution.Scratchpad do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool.Schema, as: ToolSchema
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

  @spec interrupt(term(), keyword()) :: term() | no_return()
  def interrupt(value, opts \\ []) do
    opts = Keyword.validate!(opts, [:response_schema])

    case Process.get(@process_key) do
      %__MODULE__{} = scratchpad ->
        answer_or_pause(scratchpad, value, response_schema(opts[:response_schema]))

      _missing ->
        raise RuntimeError, "BeamWeaver.Graph.interrupt/2 can only be called inside a graph node"
    end
  end

  defp answer_or_pause(%__MODULE__{resume_values: [resume | rest]} = scratchpad, _value, schema) do
    answer = resume |> resume_value() |> check_answer(schema, scratchpad)
    consume_resume(scratchpad, rest, resume)
    answer
  end

  defp answer_or_pause(%__MODULE__{} = scratchpad, value, schema) do
    interrupt = %Interrupt{
      id: interrupt_id(scratchpad),
      value: value,
      response_schema: schema,
      task_id: scratchpad.task_id,
      node: scratchpad.node,
      step: scratchpad.step,
      resumes: scratchpad.consumed_resume_values
    }

    Process.put(@process_key, %{scratchpad | interrupt_counter: scratchpad.interrupt_counter + 1})
    throw({:beam_weaver_graph_interrupt, interrupt})
  end

  defp resume_value(%Resume{null?: true}), do: nil
  defp resume_value(%Resume{value: value}), do: value
  defp resume_value(resume), do: resume

  defp interrupt_id(scratchpad) do
    payload =
      :erlang.term_to_binary({scratchpad.task_id, scratchpad.node, scratchpad.step, scratchpad.interrupt_counter})

    "interrupt_" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  defp response_schema(nil), do: nil
  defp response_schema(schema), do: BeamWeaver.Schema.json_schema!(schema)

  # An answer that doesn't match the schema fails the node, which stays
  # paused at this interrupt: the run returns an `:invalid_resume` error and
  # the next resume answers again. Retrying the node can't change the answer.
  defp check_answer(answer, nil, _scratchpad), do: answer

  defp check_answer(answer, schema, scratchpad) do
    case ToolSchema.normalize_value(schema, answer) do
      {:ok, answer} ->
        answer

      {:error, %Error{details: details}} ->
        details = Map.merge(details, %{interrupt_id: interrupt_id(scratchpad), node: scratchpad.node, retryable: false})
        error = Error.new(:invalid_resume, "resume value doesn't match the interrupt's response_schema", details)
        throw({:beam_weaver_graph_error, error})
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
