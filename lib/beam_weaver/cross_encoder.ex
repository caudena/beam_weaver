defmodule BeamWeaver.CrossEncoder do
  @moduledoc """
  Behaviour and facade for cross-encoder rerankers.

  A cross encoder scores text pairs directly. BeamWeaver keeps this as an
  explicit behaviour/adaptor contract instead of a Python abstract base class.
  """

  alias BeamWeaver.Core.Error

  @type text_pair :: {String.t(), String.t()}

  @callback score(term(), [text_pair()], keyword()) :: {:ok, [float()]} | {:error, Error.t()}

  @spec score(term(), [text_pair()], keyword()) :: {:ok, [float()]} | {:error, Error.t()}
  def score(model, text_pairs, opts \\ [])

  def score(model, text_pairs, opts) when is_list(text_pairs) do
    call(model, :score, [model, text_pairs, opts])
  end

  def score(_model, text_pairs, _opts) do
    {:error,
     Error.new(:invalid_cross_encoder_input, "cross encoder text pairs must be a list", %{
       text_pairs: inspect(text_pairs)
     })}
  end

  defp call(%{__struct__: module}, function, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      unsupported(model_module: module, function: function)
    end
  end

  defp call(module, function, args) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      unsupported(model_module: module, function: function)
    end
  end

  defp call(_model, function, _args), do: unsupported(function: function)

  defp unsupported(details) do
    {:error,
     Error.new(:unsupported_cross_encoder, "cross encoder does not implement the contract", %{
       details: details
     })}
  end
end
