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

  @spec get_model_identifier(term()) :: String.t() | nil
  def get_model_identifier(model) do
    inspect_model(model, &direct_model_identifier/1)
  end

  @spec get_model_provider(term()) :: String.t() | nil
  def get_model_provider(model) do
    inspect_model(model, &direct_model_provider/1)
  end

  defp inspect_model(model, inspector), do: inspect_model(model, inspector, 0)

  defp inspect_model(_model, _inspector, depth) when depth >= 8, do: nil

  defp inspect_model(model, inspector, depth) do
    inspector.(model) ||
      case nested_model(model) do
        nested when is_map(nested) -> inspect_model(nested, inspector, depth + 1)
        _nested -> nil
      end
  end

  defp direct_model_identifier(model) do
    string_attr(model, :model_name) ||
      function_value(model, :model_name) ||
      string_attr(model, :model) ||
      function_value(model, :model_id) ||
      string_attr(model, :id)
  end

  defp direct_model_provider(model) do
    string_attr(model, :provider) ||
      function_value(model, :provider) ||
      provider_from_module(model)
  end

  defp nested_model(model) when is_map(model), do: Map.get(model, :model, Map.get(model, "model"))
  defp nested_model(_model), do: nil

  defp normalize_init_opts(opts) do
    case Keyword.pop(opts, :use_responses_api) do
      {false, opts} -> Keyword.put_new(opts, :api, :chat_completions)
      {_use_responses_api, opts} -> opts
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

      module == BeamWeaver.ZAI.ChatModel ->
        "zai"

      module in [BeamWeaver.DeepSeek.ChatModel, BeamWeaver.DeepSeek.ResponsesModel] ->
        "deepseek"

      module == BeamWeaver.Models.FakeChatModel ->
        "fake"

      true ->
        nil
    end
  end

  defp provider_from_module(_model), do: nil
end
