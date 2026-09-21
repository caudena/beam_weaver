defmodule BeamWeaver.Core.DecisionModel do
  @moduledoc """
  Models that evaluate state against typed questions instead of generating text.

  Inputs contain `:state` and `:questions`. Implementations also implement
  `BeamWeaver.Runnable`, so decisions compose with graphs, batching and async
  calls. `Runnable.stream/3` yields one completed result, not token deltas.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable

  @callback evaluate(struct(), map(), keyword()) :: {:ok, struct()} | {:error, Error.t()}
  @callback decision_model?(struct()) :: boolean()

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
  def async_invoke(model, input, opts \\ []), do: Runnable.async_invoke(model, input, opts)
  def async_batch(model, inputs, opts \\ []), do: Runnable.async_batch(model, inputs, opts)
end
