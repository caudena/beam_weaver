defmodule BeamWeaver.Agent.Middleware.ModelFallback do
  @moduledoc """
  Falls back to alternate models when the primary model call fails.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Error

  defstruct fallbacks: [], retry_on: :error

  def new(opts \\ []) do
    %__MODULE__{
      fallbacks: Keyword.get(opts, :fallbacks, Keyword.get(opts, :models, [])),
      retry_on: Keyword.get(opts, :retry_on, :error)
    }
  end

  @impl true
  def name(_middleware), do: :model_fallback

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    case handler.(request) do
      {:error, %Error{} = error} = result ->
        if fallback_error?(middleware.retry_on, error) do
          try_fallbacks(middleware.fallbacks, request, handler, result)
        else
          result
        end

      other ->
        other
    end
  end

  defp try_fallbacks([], _request, _handler, result), do: result

  defp try_fallbacks([model | rest], request, handler, _last_error) do
    request
    |> ModelRequest.override(model: model)
    |> handler.()
    |> case do
      {:error, %Error{}} = error -> try_fallbacks(rest, request, handler, error)
      other -> other
    end
  end

  defp fallback_error?(:error, %Error{}), do: true
  defp fallback_error?(:all, _error), do: true
  defp fallback_error?(type, %Error{type: type}) when is_atom(type), do: true
  defp fallback_error?(types, %Error{type: type}) when is_list(types), do: type in types
  defp fallback_error?(fun, error) when is_function(fun, 1), do: fun.(error) == true
  defp fallback_error?(_retry_on, _error), do: false
end
