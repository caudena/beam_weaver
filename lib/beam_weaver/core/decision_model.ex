defmodule BeamWeaver.Core.DecisionModel do
  @moduledoc """
  Models that evaluate state against typed questions instead of generating text.

  Inputs contain `:state` and `:questions`. Implementations also implement
  `BeamWeaver.Runnable`, so `Runnable.invoke/3`, `Runnable.batch/3` and
  `Runnable.sequence/2` take them. `Runnable.stream/3` yields one completed
  result, not token deltas.

  Each provider has its own questions and answers, such as
  `BeamWeaver.TypeSafe.Question` and `BeamWeaver.OpenAI.Decisions.Question`.
  A model that implements `c:choice_question/3` and `c:yes_no_question/2`
  also answers `choose/4` and `probability/4`, which middleware such as
  `BeamWeaver.Agent.Middleware.TypeSafeModelRouter` and
  `BeamWeaver.Agent.Middleware.AutoMode` ask any decision model with.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.{Runnable, Tracing}

  @callback evaluate(struct(), map(), keyword()) :: {:ok, struct()} | {:error, Error.t()}
  @callback decision_model?(struct()) :: boolean()

  @doc """
  The model's question asking which of `options`, names mapped to
  descriptions of when each applies, fits the state, checked as the model
  would check it when asked.
  """
  @callback choice_question(struct(), instructions :: term(), options :: %{String.t() => term()}) ::
              {:ok, term()} | {:error, Error.t()}

  @doc "The model's question asking how likely it is that `instructions` holds for the state, checked."
  @callback yes_no_question(struct(), instructions :: term()) :: {:ok, term()} | {:error, Error.t()}

  @optional_callbacks choice_question: 3, yes_no_question: 2

  @spec model?(term()) :: boolean()
  def model?(%module{} = model) do
    Code.ensure_loaded?(module) and function_exported?(module, :decision_model?, 1) and
      module.decision_model?(model)
  end

  def model?(_model), do: false

  @spec invoke(term(), map(), keyword()) :: {:ok, struct()} | {:error, Error.t()}
  def invoke(model, input, opts \\ []) do
    if model?(model) do
      model.__struct__.evaluate(model, input, opts)
    else
      {:error, Error.new(:unsupported_feature, "model does not support typed decisions")}
    end
  end

  def batch(model, inputs, opts \\ []), do: Runnable.batch(model, inputs, opts)

  @doc """
  Builds `model`'s question asking which of `options`, names mapped to
  descriptions of when each applies, fits the state. Ask it with `choose/4`.
  """
  @spec choice_question(term(), term(), %{String.t() => term()}) :: {:ok, term()} | {:error, Error.t()}
  def choice_question(model, instructions, options), do: question(model, :choice_question, [instructions, options])

  @doc """
  Builds `model`'s question asking how likely it is that `instructions` holds
  for the state. Ask it with `probability/4`.
  """
  @spec yes_no_question(term(), term()) :: {:ok, term()} | {:error, Error.t()}
  def yes_no_question(model, instructions), do: question(model, :yes_no_question, [instructions])

  @doc """
  Asks `model` a question from `choice_question/3` about `state`. Returns the
  answer, with its `choice`, `confidence` and `probabilities`, and the whole
  response, or `{:refused, response}` when the model declines to answer.
  """
  @spec choose(term(), term(), term(), keyword()) ::
          {:ok, struct(), struct()} | {:refused, struct()} | {:error, Error.t()}
  def choose(model, state, question, opts \\ []) do
    with {:ok, response} <- invoke(model, %{state: state, questions: %{"choice" => question}}, opts) do
      case Map.get(response.answers, "choice") do
        %{choice: _, confidence: _, probabilities: _} = answer -> {:ok, answer, response}
        _refusal -> {:refused, response}
      end
    end
  end

  @doc """
  Asks `model` a question from `yes_no_question/2` about `state`. Returns the
  probability, from 0 to 1, and the whole response, or `{:refused, response}`
  when the model declines to answer.
  """
  @spec probability(term(), term(), term(), keyword()) ::
          {:ok, number(), struct()} | {:refused, struct()} | {:error, Error.t()}
  def probability(model, state, question, opts \\ []) do
    with {:ok, response} <- invoke(model, %{state: state, questions: %{"probability" => question}}, opts) do
      case Map.get(response.answers, "probability") do
        # OpenAI's predicate answers and TypeSafe's noul answers.
        %{probability: probability} -> {:ok, probability, response}
        %{noul: probability} -> {:ok, probability, response}
        _refusal -> {:refused, response}
      end
    end
  end

  # Options any call to a decision model may carry: the request's own, and
  # those of the runnable and tracing layers around it.
  @call_options [
    :timeout,
    :headers,
    :transport_opts,
    :trace?,
    :trace,
    :exporter,
    :exporter_opts,
    :tags,
    :metadata,
    :run_name,
    :run_id,
    :config,
    :configurable,
    :context,
    :max_concurrency,
    :recursion_limit,
    :opts,
    :callbacks,
    :cache,
    :rate_limiter,
    :task_supervisor
  ]

  # Fails for an option neither a decision model call nor this provider's
  # model (`provider_options`) takes.
  @doc false
  def check_options(opts, provider_options, name) do
    case Keyword.keys(opts) -- (@call_options ++ provider_options) do
      [] ->
        :ok

      unsupported ->
        {:error,
         Error.new(:unsupported_feature, "#{name} does not support these invocation options", %{options: unsupported})}
    end
  end

  # Runs `request`, the provider call that answers `body`, as a traced model
  # run when tracing is on.
  @doc false
  def traced(provider, run_name, body, opts, request) do
    if Keyword.get(opts, :trace?, Keyword.get(opts, :trace, true)) != false and
         (Tracing.capture_context() != nil or Tracing.exporter_configured?() or Keyword.has_key?(opts, :exporter)) do
      exporter = Keyword.take(opts, [:exporter, :exporter_opts])

      metadata =
        opts
        |> Runnable.Config.inheritable_metadata()
        |> Map.merge(%{provider: provider, model: body["model"], model_kind: "decision"})

      Tracing.Runner.run(
        Keyword.get(opts, :run_name) || run_name,
        [
          kind: :model,
          inputs: Map.take(body, ["state", "input", "questions"]),
          metadata: metadata,
          tags: Keyword.get(opts, :tags, [])
        ],
        exporter,
        request,
        fn run, result ->
          case result do
            {:ok, response} ->
              Tracing.finish_run(
                run,
                exporter ++
                  [
                    outputs: response,
                    usage: response.usage,
                    metadata: %{
                      model: response.model,
                      request_id: response.request_id,
                      cost: response.metadata.cost,
                      latency_ms: response.latency_ms
                    }
                  ]
              )

            {:error, error} ->
              Tracing.fail_run(run, error, exporter)
          end

          result
        end
      )
    else
      request.()
    end
  end

  defp question(%module{} = model, callback, args) do
    cond do
      not model?(model) ->
        {:error, Error.new(:unsupported_feature, "model does not support typed decisions", %{question: callback})}

      function_exported?(module, callback, length(args) + 1) ->
        apply(module, callback, [model | args])

      # A wrapper, such as a cached or rate-limited model, asks the model it
      # wraps for the question, and is still the one invoked.
      model?(Map.get(model, :model)) ->
        question(model.model, callback, args)

      true ->
        {:error,
         Error.new(:unsupported_feature, "decision model can't build this question", %{
           model: module,
           question: callback
         })}
    end
  end

  defp question(_model, callback, _args),
    do: {:error, Error.new(:unsupported_feature, "model does not support typed decisions", %{question: callback})}
end
