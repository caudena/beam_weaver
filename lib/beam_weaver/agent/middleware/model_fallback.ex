defmodule BeamWeaver.Agent.Middleware.ModelFallback do
  @moduledoc """
  Falls back to alternate models when the primary model call fails.

  Options:

    * `:fallbacks` - the models to try, in order: model values or
      `"provider:model"` strings, which are resolved the way an agent's
      `model` declaration is.
    * `:retry_on` - which errors switch models: `:error` (the default, every
      error), an error type or a list of types, or a function of the error.

  A fallback gets the agent's model options that its profile takes, such as
  `temperature:`; the ones it doesn't take, such as `reasoning_effort:` for a
  Claude model, are left out. The settings of the agent's model itself
  (`api_key:`, `base_url:`, `endpoint:`, `transport:`, `extra_body:` and the
  like) never reach a fallback, which uses its own: when a fallback's API key
  isn't in your configuration, pass a model value with `api_key:`.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResolver
  alias BeamWeaver.Agent.ProviderProfile
  alias BeamWeaver.Core.Error

  defstruct fallbacks: [], retry_on: :error

  def new(opts \\ []) do
    %__MODULE__{
      fallbacks: opts |> Keyword.get(:fallbacks, Keyword.get(opts, :models, [])) |> Enum.map(&resolve_model!/1),
      retry_on: Keyword.get(opts, :retry_on, :error)
    }
  end

  @impl true
  def name(_middleware), do: :model_fallback

  @impl true
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

  defp resolve_model!(spec) when is_binary(spec) or is_atom(spec) do
    case ModelResolver.resolve_model(spec, ProviderProfile.apply_provider_profile(to_string(spec))) do
      {:ok, model} -> model
      {:error, %Error{} = error} -> raise ArgumentError, "invalid fallback model #{inspect(spec)}: #{error.message}"
    end
  end

  defp resolve_model!(model), do: model

  defp try_fallbacks([], _request, _handler, result), do: result

  defp try_fallbacks([model | rest], request, handler, _last_error) do
    request
    |> ModelRequest.override(
      model: model,
      model_opts: Helpers.call_options_for(request.model_opts || [], request.model, model)
    )
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
