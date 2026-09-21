defmodule BeamWeaver.TypeSafe.DecisionModel do
  @moduledoc """
  Jev decision model. Evaluate `state` and named `questions` through
  `BeamWeaver.Core.DecisionModel` or `BeamWeaver.Runnable`.
  """
  @behaviour BeamWeaver.Core.DecisionModel
  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.{ProfileRegistry, UsageCost}
  alias BeamWeaver.Tracing
  alias BeamWeaver.TypeSafe.{Client, Input}

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

  @impl true
  def invoke(model, input, opts \\ []), do: BeamWeaver.Core.DecisionModel.invoke(model, input, opts)

  @impl true
  def evaluate(%__MODULE__{} = model, input, opts) do
    with :ok <- supported_options(opts),
         :ok <- valid_model(Keyword.get(opts, :model, model.model)),
         {:ok, input} <- Input.normalize(input, opts) do
      body = Map.put(input, "model", Keyword.get(opts, :model, model.model))

      trace(model, body, opts, fn ->
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

  defp supported_options(opts) do
    unsupported =
      Keyword.keys(opts) --
        [
          :model,
          :timeout,
          :headers,
          :transport_opts,
          :max_bytes,
          :max_items,
          :max_depth,
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

    if unsupported == [],
      do: :ok,
      else:
        {:error,
         Error.new(:unsupported_feature, "Jev does not support these invocation options", %{options: unsupported})}
  end

  defp trace(_model, body, opts, fun) do
    if Keyword.get(opts, :trace?, Keyword.get(opts, :trace, true)) != false and
         (Tracing.capture_context() != nil or Tracing.exporter_configured?() or Keyword.has_key?(opts, :exporter)) do
      exporter = Keyword.take(opts, [:exporter, :exporter_opts])

      metadata =
        BeamWeaver.Runnable.Config.inheritable_metadata(opts)
        |> Map.merge(%{provider: "typesafe", model: body["model"], model_kind: "decision"})

      BeamWeaver.Tracing.Runner.run(
        Keyword.get(opts, :run_name) || "TypeSafe.#{body["model"]}",
        [
          kind: :model,
          inputs: Map.take(body, ["state", "questions"]),
          metadata: metadata,
          tags: Keyword.get(opts, :tags, [])
        ],
        exporter,
        fun,
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
      fun.()
    end
  end
end

defimpl Inspect, for: BeamWeaver.TypeSafe.DecisionModel do
  def inspect(value, opts), do: BeamWeaver.Provider.RedactedInspect.redacted_struct(value, opts)
end
