defmodule BeamWeaver.Agent.ModelResolver do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models

  @type resolve_result :: {:ok, term()} | {:error, Error.t()}

  @spec resolve_model(term(), keyword()) :: resolve_result()
  def resolve_model(model, opts \\ [])

  # The model options are also sent with every call, so the call options among
  # them (such as `tools:`) stay out of the model's construction.
  def resolve_model(model, opts) when is_binary(model) or is_atom(model),
    do: Models.init_chat_model(model, Models.init_options(model, normalize_init_opts(opts)))

  def resolve_model(model, _opts), do: {:ok, model}

  @spec resolve_agent_model(term(), keyword()) :: resolve_result()
  def resolve_agent_model(model, opts) when is_binary(model) or (is_atom(model) and not is_nil(model)),
    do: resolve_model(model, opts)

  def resolve_agent_model(%_{} = model, _opts), do: {:ok, model}

  def resolve_agent_model(model, _opts) when is_function(model) do
    {:error,
     Error.new(
       :invalid_agent_model,
       "agent model must be a model value; use wrap_model_call middleware to choose the model per call",
       %{model: describe(model)}
     )}
  end

  def resolve_agent_model(model, _opts) do
    {:error,
     Error.new(
       :invalid_agent_model,
       ~s(agent model must be a "provider:model" string or a chat model struct; its options go after the model or in model_opts),
       %{model: describe(model)}
     )}
  end

  # How an error shows a model or model options it rejects: the kind of value,
  # and the keys of a map or keyword list, never the values. Errors reach logs
  # and traces, and the values can hold an API key.
  @spec describe(term()) :: String.t()
  def describe(value) when is_function(value), do: inspect(value)
  def describe(value) when is_atom(value) or is_number(value), do: inspect(value)
  def describe(value) when is_binary(value), do: "a string"
  def describe(%module{}), do: "a #{inspect(module)} struct"
  def describe(value) when is_map(value), do: "a map with keys #{inspect(Map.keys(value))}"
  def describe(value) when is_tuple(value), do: "a tuple of #{tuple_size(value)} elements"

  def describe([_ | _] = value) do
    if Keyword.keyword?(value),
      do: "a keyword list with keys #{inspect(Keyword.keys(value))}",
      else: "a list of #{length(value)} elements"
  end

  def describe([]), do: "an empty list"
  def describe(_value), do: "a value of another type"

  defp normalize_init_opts(opts) do
    case Keyword.pop(opts, :use_responses_api) do
      {false, opts} -> Keyword.put_new(opts, :api, :chat_completions)
      {_use_responses_api, opts} -> opts
    end
  end
end
