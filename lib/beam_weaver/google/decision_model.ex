defmodule BeamWeaver.Google.DecisionModel do
  @moduledoc """
  Gemini Decision 1 on the Gemini Developer API. Invoke it with state and
  named questions from `BeamWeaver.Google.Decisions.Question`. The response
  includes typed answers, input token usage and estimated cost.
  """

  use BeamWeaver.Provider.RedactedInspect

  @behaviour BeamWeaver.Core.DecisionModel

  alias BeamWeaver.Core.{DecisionModel, Error}
  alias BeamWeaver.Google.Client
  alias BeamWeaver.Google.Decisions.{Decoder, Input, Question}
  alias BeamWeaver.Models.{ProfileRegistry, UsageCost}

  @model "gemini-decision-1"

  defstruct [:client, :profile, model: @model]
  @type t :: %__MODULE__{}

  def new(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    model = Keyword.get(opts, :model, @model)

    %__MODULE__{
      model: model,
      profile: Keyword.get_lazy(opts, :profile, fn -> elem(ProfileRegistry.fetch(:google, model), 1) end),
      client: Keyword.get_lazy(opts, :client, fn -> Client.new(opts) end)
    }
  end

  @impl true
  def decision_model?(_model), do: true
  def model_id(model), do: model.model
  def profile(model), do: model.profile

  def invoke(model, input, opts \\ []), do: DecisionModel.invoke(model, input, opts)

  @impl true
  def choice_question(_model, instructions, options),
    do: Input.checked(Question.choice(instructions: instructions, criteria: options))

  @impl true
  def yes_no_question(_model, instructions), do: Input.checked(Question.noul(instructions: instructions))

  @impl true
  def evaluate(%__MODULE__{model: @model} = model, input, opts) do
    with :ok <- DecisionModel.check_options(opts, [], "Gemini Decisions"),
         {:ok, body} <- Input.request(input) do
      body = Map.put(body, "model", model.model)

      DecisionModel.traced("google", "Google.#{model.model}", body, opts, fn ->
        started = System.monotonic_time(:millisecond)

        with {:ok, raw} <- Client.decisions(model.client, body, opts),
             {:ok, response} <- Decoder.decode(raw, model.model) do
          {:ok,
           %{
             response
             | latency_ms: System.monotonic_time(:millisecond) - started,
               metadata: %{cost: UsageCost.calculate(model.profile, response.usage)}
           }}
        end
      end)
    end
  end

  def evaluate(model, _input, _opts),
    do: {:error, Error.new(:unsupported_model, "Gemini Decisions requires #{@model}", %{model: model.model})}
end
