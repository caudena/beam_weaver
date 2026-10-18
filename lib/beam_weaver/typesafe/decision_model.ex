defmodule BeamWeaver.TypeSafe.DecisionModel do
  @moduledoc """
  Jev decision model. Evaluate `state` and named `questions` with
  `BeamWeaver.Core.DecisionModel.invoke/3` or
  `BeamWeaver.Core.DecisionModel.batch/3`.
  """

  use BeamWeaver.Provider.RedactedInspect

  @behaviour BeamWeaver.Core.DecisionModel

  alias BeamWeaver.Core.{DecisionModel, Error}
  alias BeamWeaver.Models.{ProfileRegistry, UsageCost}
  alias BeamWeaver.TypeSafe.{Client, Input, Question}

  defstruct [:client, :profile, model: "jev-latest"]
  @type t :: %__MODULE__{}

  def new(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    model = Keyword.get(opts, :model, "jev-latest")
    {:ok, profile} = ProfileRegistry.fetch(:typesafe, model)

    %__MODULE__{
      model: model,
      profile: Keyword.get(opts, :profile, profile),
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
    do: checked(Question.choice(instructions: instructions, criteria: options))

  @impl BeamWeaver.Core.DecisionModel
  def yes_no_question(_model, instructions), do: checked(Question.noul(instructions: instructions))

  defp checked(question) do
    with {:ok, _input} <- Input.normalize(%{state: "", questions: %{"question" => question}}), do: {:ok, question}
  end

  @impl true
  def evaluate(%__MODULE__{} = model, input, opts) do
    with :ok <- DecisionModel.check_options(opts, [:model, :max_bytes, :max_items, :max_depth], "Jev"),
         :ok <- valid_model(Keyword.get(opts, :model, model.model)),
         {:ok, input} <- Input.normalize(input, opts) do
      body = Map.put(input, "model", Keyword.get(opts, :model, model.model))

      DecisionModel.traced("typesafe", "TypeSafe.#{body["model"]}", body, opts, fn ->
        started = System.monotonic_time(:millisecond)

        with {:ok, response} <- Client.evaluate(model.client, body, opts) do
          {:ok,
           %{response | latency_ms: System.monotonic_time(:millisecond) - started, metadata: %{cost: cost(response)}}}
        end
      end)
    end
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
