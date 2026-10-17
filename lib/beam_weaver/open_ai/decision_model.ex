defmodule BeamWeaver.OpenAI.DecisionModel do
  @moduledoc """
  OpenAI's Decisions API, in public beta: ask `gpt-6-luna` typed questions
  about some state, through `BeamWeaver.Core.DecisionModel` or
  `BeamWeaver.Runnable`. Create one with
  `BeamWeaver.Models.init_decision_model("openai:gpt-6-luna")`.

  The input has `state` and `questions`, a map of names to
  `BeamWeaver.OpenAI.Decisions.Question` values; the response is a
  `BeamWeaver.OpenAI.Decisions.Response` with an answer for each name.

  `state` is a string, a user message, a list of user messages, or other
  data such as a conversation or a map. Strings and user messages, with text
  and images, go to the API as they are. Anything else goes as JSON text,
  with the images of the messages in it placed where they appear. Messages
  in it take text and images only, so convert other content to text first.
  Images are data URLs or HTTP(S) URLs, at most 128 in a request.

  The API doesn't bill output tokens, so `metadata.cost` counts input only.
  """

  use BeamWeaver.Provider.RedactedInspect

  @behaviour BeamWeaver.Core.DecisionModel
  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.DecisionModel
  alias BeamWeaver.Models.{ProfileRegistry, UsageCost}
  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.OpenAI.Decisions.{Decoder, Input, Question}

  defstruct [:client, :profile, model: "gpt-6-luna"]
  @type t :: %__MODULE__{}

  @doc """
  Builds the model from keyword options: `:model`, and the connection
  options of `BeamWeaver.OpenAI.Client.new/1` such as `:api_key`,
  `:base_url`, `:organization`, `:project` and `:timeout`.
  """
  def new(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    model = Keyword.get(opts, :model, "gpt-6-luna")

    %__MODULE__{
      model: model,
      profile: Keyword.get_lazy(opts, :profile, fn -> elem(ProfileRegistry.fetch(:openai, model), 1) end),
      client: Keyword.get_lazy(opts, :client, fn -> Client.new(opts) end)
    }
  end

  @impl true
  def decision_model?(_model), do: true
  def model_id(model), do: model.model
  def profile(model), do: model.profile

  @impl true
  def invoke(model, input, opts \\ []), do: DecisionModel.invoke(model, input, opts)

  @impl BeamWeaver.Core.DecisionModel
  def choice_question(_model, instructions, options),
    do: Input.checked(Question.choice(instructions: instructions, choices: options))

  @impl BeamWeaver.Core.DecisionModel
  def yes_no_question(_model, instructions), do: Input.checked(Question.predicate(instructions: instructions))

  @impl true
  def evaluate(%__MODULE__{} = model, input, opts) do
    with :ok <- DecisionModel.check_options(opts, [], "OpenAI Decisions"),
         {:ok, body} <- Input.request(input) do
      body = Map.put(body, "model", model.model)

      DecisionModel.traced("openai", "OpenAI.#{model.model}", body, opts, fn ->
        started = System.monotonic_time(:millisecond)

        with {:ok, raw} <- Client.post_json(model.client, Client.endpoint(model.client, "decisions"), body, opts),
             {:ok, response} <- Decoder.decode(raw) do
          {:ok,
           %{
             response
             | requested_model: model.model,
               latency_ms: System.monotonic_time(:millisecond) - started,
               metadata: %{cost: cost(model.profile, response.usage)}
           }}
        end
      end)
    end
  end

  defp cost(profile, usage), do: UsageCost.calculate(profile, %{usage | output_tokens: 0})
end
