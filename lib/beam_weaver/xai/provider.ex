defmodule BeamWeaver.XAI.Provider do
  @moduledoc false

  @behaviour BeamWeaver.Provider.Adapter

  alias BeamWeaver.Models
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Models.ProfileRegistry

  @impl true
  def provider, do: :xai

  @impl true
  def profiles, do: ProfileRegistry.profiles(:xai)

  @impl true
  def chat_model(opts) do
    with {:ok, module, api} <- chat_api(opts),
         :ok <- validate_metadata(opts, api),
         do: {:ok, module}
  end

  defp chat_api(opts) do
    case Keyword.get(opts, :api) || :responses do
      api when api in [:responses, "responses"] ->
        {:ok, BeamWeaver.XAI.ChatModel, :responses}

      api when api in [:chat_completions, "chat_completions"] ->
        {:ok, BeamWeaver.XAI.ChatCompletionsModel, :chat_completions}

      api ->
        {:error,
         BeamWeaver.Core.Error.new(:invalid_provider_option, "unsupported xAI API selection", %{
           provider: :xai,
           option: :api,
           value: api,
           supported: [:responses, :chat_completions]
         })}
    end
  end

  # xAI takes no request metadata: Chat Completions has no such field, and the
  # Responses API keeps one only for compatibility. Every call checks a
  # model's `metadata` against its profile and param policy, so the model is
  # checked the same way when it is created, and fails with the call's error.
  defp validate_metadata(opts, api) do
    case Keyword.get(opts, :metadata) do
      nil ->
        :ok

      metadata ->
        model = Keyword.get(opts, :model) || default_model(:chat)

        with {:ok, profile} <- Models.fetch_profile(:xai, model, opts),
             do: ParamPolicy.validate(profile, %{metadata: metadata}, Keyword.get(opts, :param_policy), api: api)
    end
  end

  @impl true
  def profile(model), do: ProfileRegistry.fetch(:xai, model)

  @impl true
  def infer_provider?("grok-" <> _rest, :chat), do: true
  def infer_provider?(_model, _kind), do: false

  @impl true
  def default_model(:chat), do: "grok-4.6"
  def default_model(_kind), do: nil

  @impl true
  def capabilities,
    do: %{api_families: [:responses, :chat_completions], openai_compatible: true}
end
