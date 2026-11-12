defmodule BeamWeaver.TypeSafe.DecisionModel do
  @moduledoc ~S"""
  Jev evaluation of state against named typed questions.

  Invoke through BeamWeaver.Core.DecisionModel with state and questions. Results
  contain string-keyed typed answers, served/requested model identity and usage.
  Question validation happens before HTTP execution. Confidence and probability
  require calibration; neither establishes correctness on its own.
  Use the [TypeSafe guide](providers/typesafe.md) for a real request and routing
  behavior, including explicit acceptance/fallback checks.
  """

  use BeamWeaver.Provider.RedactedInspect

  @behaviour BeamWeaver.Core.DecisionModel

  alias BeamWeaver.Core.{DecisionModel, Error}
  alias BeamWeaver.Models.{ProfileRegistry, UsageCost}
  alias BeamWeaver.TypeSafe.{Client, Input, Question}

  defstruct [:client, :profile, model: "jev-latest", images: false, long_context: false]
  @type t :: %__MODULE__{}

  def new(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    model = Keyword.get(opts, :model, "jev-latest")
    profile = Keyword.get_lazy(opts, :profile, fn -> elem(ProfileRegistry.fetch(:typesafe, model), 1) end)
    images = Keyword.get(opts, :images, false)
    long_context = Keyword.get(opts, :long_context, false)

    %__MODULE__{
      model: model,
      profile: enabled_profile(profile, images, long_context),
      images: images,
      long_context: long_context,
      client: Keyword.get_lazy(opts, :client, fn -> Client.new(opts) end)
    }
  end

  defp enabled_profile(profile, images, long_context) do
    profile = if images == true, do: %{profile | image_inputs: true}, else: profile

    case {long_context, profile.extra[:long_context_tokens]} do
      {true, tokens} when is_integer(tokens) ->
        %{
          profile
          | max_input_tokens: tokens,
            extra: Map.put(profile.extra, :state_plus_longest_question_tokens, tokens)
        }

      _ ->
        profile
    end
  end

  @impl true
  def decision_model?(_model), do: true
  def model_id(model), do: model.model
  def profile(model), do: model.profile

  def invoke(model, input, opts \\ []), do: DecisionModel.invoke(model, input, opts)

  @impl BeamWeaver.Core.DecisionModel
  def choice_question(model, instructions, options),
    do: checked(model, Question.choice(instructions: instructions, criteria: options))

  @impl BeamWeaver.Core.DecisionModel
  def yes_no_question(model, instructions), do: checked(model, Question.noul(instructions: instructions))

  defp checked(model, question) do
    input = %{state: "", questions: %{"question" => question}}
    with {:ok, _input} <- Input.normalize(input, images: model.images), do: {:ok, question}
  end

  @impl true
  def evaluate(%__MODULE__{} = model, input, opts) do
    id = Keyword.get(opts, :model, model.model)

    with :ok <-
           DecisionModel.check_options(
             opts,
             [:model, :max_bytes, :max_items, :max_depth, :images, :long_context],
             "Jev"
           ),
         :ok <- valid_model(id),
         opts =
           opts
           |> Keyword.put(:model, id)
           |> Keyword.put_new(:images, model.images)
           |> Keyword.put_new(:long_context, model.long_context),
         :ok <- validate_flags(opts),
         {:ok, input} <- Input.normalize(input, opts) do
      body = Map.put(input, "model", id)

      DecisionModel.traced("typesafe", "TypeSafe.#{body["model"]}", body, opts, fn ->
        started = System.monotonic_time(:millisecond)

        with {:ok, response} <- Client.evaluate(model.client, body, opts) do
          {:ok,
           %{response | latency_ms: System.monotonic_time(:millisecond) - started, metadata: %{cost: cost(response)}}}
        end
      end)
    end
  end

  defp validate_flags(opts) do
    if is_boolean(opts[:images]) and is_boolean(opts[:long_context]),
      do: :ok,
      else: {:error, Error.new(:invalid_decision_input, "Jev images and long_context options must be boolean")}
  end

  defp valid_model("jev-" <> suffix) when suffix != "", do: :ok
  defp valid_model(_), do: {:error, Error.new(:invalid_model, "TypeSafe model must be a non-empty jev- identifier")}

  defp cost(response) do
    case ProfileRegistry.fetch(:typesafe, response.model) do
      {:ok, profile} -> UsageCost.calculate(profile, response.usage)
      _ -> nil
    end
  end
end
