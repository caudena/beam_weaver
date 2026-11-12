defmodule BeamWeaver.OpenAI.DecisionModel do
  @moduledoc """
  OpenAI's Decisions API: ask `gpt-6-luna` typed questions
  about some state, with `BeamWeaver.Core.DecisionModel.invoke/3` or
  `BeamWeaver.Core.DecisionModel.batch/3`. Create one with
  `BeamWeaver.Models.init_decision_model("openai:gpt-6-luna")`.

  The input has `state` and `questions`, a map of names to
  `BeamWeaver.OpenAI.Decisions.Question` values; the response is a
  `BeamWeaver.OpenAI.Decisions.Response` with an answer for each name.

  State can be text, user messages, or JSON-compatible data. Use
  `{:input_json, data}` to send a JSON object or array of objects as native
  structured evidence. Other structured state goes as JSON text with images
  interleaved where they appear. Images are data URLs or HTTP(S) URLs, at
  most 128 in a request across state and questions.

  The API doesn't bill output tokens, so `metadata.cost` counts input only.
  """

  use BeamWeaver.Provider.RedactedInspect

  @behaviour BeamWeaver.Core.DecisionModel

  alias BeamWeaver.Core.DecisionModel
  alias BeamWeaver.Models.{ProfileRegistry, UsageCost}
  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.OpenAI.Decisions.{Decoder, Input, Question}
  alias BeamWeaver.Provider.Options

  @request_options [:prompt_cache_key, :prompt_cache_options, :safety_identifier]

  defstruct [:client, :profile, :prompt_cache_key, :prompt_cache_options, :safety_identifier, model: "gpt-6-luna"]
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
      prompt_cache_key: Keyword.get(opts, :prompt_cache_key),
      prompt_cache_options: Keyword.get(opts, :prompt_cache_options),
      safety_identifier: Keyword.get(opts, :safety_identifier),
      profile: Keyword.get_lazy(opts, :profile, fn -> elem(ProfileRegistry.fetch(:openai, model), 1) end),
      client: Keyword.get_lazy(opts, :client, fn -> Client.new(opts) end)
    }
  end

  @impl true
  def decision_model?(_model), do: true
  def model_id(model), do: model.model
  def profile(model), do: model.profile

  def invoke(model, input, opts \\ []), do: DecisionModel.invoke(model, input, opts)

  @impl BeamWeaver.Core.DecisionModel
  def choice_question(_model, instructions, options),
    do: Input.checked(Question.choice(instructions: instructions, choices: options))

  @impl BeamWeaver.Core.DecisionModel
  def yes_no_question(_model, instructions), do: Input.checked(Question.predicate(instructions: instructions))

  @impl true
  def evaluate(%__MODULE__{} = model, input, opts) do
    with :ok <- DecisionModel.check_options(opts, @request_options, "OpenAI Decisions"),
         {:ok, body} <- Input.request(input) do
      body =
        Enum.reduce(@request_options, Map.put(body, "model", model.model), fn field, request ->
          value = Options.option(model, opts, field)
          Options.put_optional(request, Atom.to_string(field), Options.normalize_value(value))
        end)

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
