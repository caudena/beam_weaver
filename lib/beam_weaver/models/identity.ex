defmodule BeamWeaver.Models.Identity do
  @moduledoc false

  # A model's id and provider, read from the model value: its fields, its
  # module's functions, or the model it wraps.

  @spec identifier(term()) :: String.t() | nil
  def identifier(model) do
    inspect_model(model, &direct_model_identifier/1)
  end

  @spec provider(term()) :: String.t() | nil
  def provider(model) do
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

  @module_providers %{
    BeamWeaver.OpenAI.ChatModel => "openai",
    BeamWeaver.OpenAI.ChatCompletionsModel => "openai",
    BeamWeaver.OpenAI.ResponsesModel => "openai",
    BeamWeaver.Anthropic.ChatModel => "anthropic",
    BeamWeaver.XAI.ChatModel => "xai",
    BeamWeaver.XAI.ChatCompletionsModel => "xai",
    BeamWeaver.Moonshot.ChatModel => "moonshot",
    BeamWeaver.ZAI.ChatModel => "zai",
    BeamWeaver.DeepSeek.ChatModel => "deepseek",
    BeamWeaver.DeepSeek.ResponsesModel => "deepseek",
    BeamWeaver.Models.FakeChatModel => "fake"
  }

  defp provider_from_module(%module{}), do: @module_providers[module]
  defp provider_from_module(_model), do: nil
end
