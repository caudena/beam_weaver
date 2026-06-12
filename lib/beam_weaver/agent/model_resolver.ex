defmodule BeamWeaver.Agent.ModelResolver do
  @moduledoc """
  DeepAgents model resolution and inspection helpers.

  Python DeepAgents resolves string model specs through LangChain and inspects
  provider/model identifiers for profile lookup. BeamWeaver delegates model
  construction to `BeamWeaver.Models` and keeps these helpers small and
  provider-scoped.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models

  @type resolve_result :: {:ok, term()} | {:error, Error.t()}

  @doc "Resolves a model spec into a BeamWeaver chat model."
  @spec resolve_model(term(), keyword()) :: resolve_result()
  def resolve_model(model, opts \\ [])

  def resolve_model(model, opts) when is_binary(model) or is_atom(model),
    do: Models.init_chat_model(model, normalize_init_opts(opts))

  def resolve_model(model, _opts), do: {:ok, model}

  @doc "Returns the provider-native model identifier when it can be inspected."
  @spec get_model_identifier(term()) :: String.t() | nil
  def get_model_identifier(model) do
    string_attr(model, :model_name) ||
      function_value(model, :model_name) ||
      string_attr(model, :model) ||
      function_value(model, :model_id) ||
      string_attr(model, :id)
  end

  @doc "Returns a best-effort provider identifier for a BeamWeaver model."
  @spec get_model_provider(term()) :: String.t() | nil
  def get_model_provider(model) do
    string_attr(model, :provider) ||
      function_value(model, :provider) ||
      provider_from_module(model)
  end

  @doc "Checks whether a resolved model matches a provider-prefixed or bare spec."
  @spec model_matches_spec(term(), String.t()) :: boolean()
  def model_matches_spec(model, spec) when is_binary(spec) do
    case get_model_identifier(model) do
      nil ->
        false

      identifier ->
        spec == identifier or provider_prefixed_match?(identifier, spec)
    end
  end

  def model_matches_spec(_model, _spec), do: false

  defp provider_prefixed_match?(identifier, spec) do
    case String.split(spec, ":", parts: 2) do
      [_provider, model_name] when model_name != "" -> model_name == identifier
      _other -> false
    end
  end

  defp normalize_init_opts(opts) do
    opts
    |> Keyword.delete(:use_responses_api)
    |> maybe_put_openai_api(opts)
  end

  defp maybe_put_openai_api(opts, original) do
    if Keyword.get(original, :use_responses_api) == false do
      Keyword.put_new(opts, :api, :chat_completions)
    else
      opts
    end
  end

  defp string_attr(model, attr) when is_map(model) do
    value = Map.get(model, attr, Map.get(model, to_string(attr)))
    if is_binary(value) and value != "", do: value
  end

  defp string_attr(_model, _attr), do: nil

  defp function_value(%module{} = model, function) do
    if function_exported?(module, function, 1) do
      case apply(module, function, [model]) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end
  rescue
    _exception -> nil
  end

  defp function_value(_model, _function), do: nil

  defp provider_from_module(%module{}) do
    cond do
      module in [
        BeamWeaver.OpenAI.ChatModel,
        BeamWeaver.OpenAI.ChatCompletionsModel,
        BeamWeaver.OpenAI.ResponsesModel
      ] ->
        "openai"

      module == BeamWeaver.Anthropic.ChatModel ->
        "anthropic"

      module in [BeamWeaver.XAI.ChatModel, BeamWeaver.XAI.ChatCompletionsModel] ->
        "xai"

      module == BeamWeaver.Moonshot.ChatModel ->
        "moonshot"

      module == BeamWeaver.Models.FakeChatModel ->
        "fake"

      true ->
        nil
    end
  end

  defp provider_from_module(_model), do: nil
end
