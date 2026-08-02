defmodule BeamWeaver.DeepSeek.Provider do
  @moduledoc false

  @behaviour BeamWeaver.Provider.Adapter

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.ProfileRegistry

  @impl true
  def provider, do: :deepseek

  @impl true
  def profiles, do: ProfileRegistry.profiles(:deepseek)

  @impl true
  def chat_model(opts) do
    model = Keyword.get(opts, :model)

    case normalize_api(Keyword.get(opts, :api, :chat_completions)) do
      {:ok, :chat_completions} ->
        {:ok, BeamWeaver.DeepSeek.ChatModel}

      {:ok, :responses} when model == "deepseek-v4-pro" ->
        {:error,
         Error.new(:unsupported_model, "DeepSeek Responses currently supports V4 Flash only", %{
           provider: :deepseek,
           api: :responses,
           model: model,
           supported: ["deepseek-v4-flash"],
           expected: "deepseek:deepseek-v4-flash"
         })}

      {:ok, :responses} ->
        {:ok, BeamWeaver.DeepSeek.ResponsesModel}

      {:error, api} ->
        {:error,
         Error.new(:invalid_provider_option, "unsupported DeepSeek API selection", %{
           provider: :deepseek,
           option: :api,
           value: api,
           supported: [:chat_completions, :responses]
         })}
    end
  end

  @impl true
  def profile(model), do: ProfileRegistry.fetch(:deepseek, model)

  @impl true
  def infer_provider?(_model, _kind), do: false

  @impl true
  def default_model(:chat), do: "deepseek-v4-flash"
  def default_model(_kind), do: nil

  @impl true
  def capabilities do
    %{
      api_families: [:chat_completions, :responses],
      openai_compatible: true,
      default_api: :chat_completions
    }
  end

  defp normalize_api(api) when api in [:chat, :chat_completions, "chat", "chat_completions"],
    do: {:ok, :chat_completions}

  defp normalize_api(api) when api in [:responses, "responses"], do: {:ok, :responses}
  defp normalize_api(api), do: {:error, api}
end
