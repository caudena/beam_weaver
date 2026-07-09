defmodule BeamWeaver.OpenAI.ChatCompletionsModel do
  @moduledoc """
  OpenAI Chat Completions chat model implementation.
  """

  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.OpenAI.ChatCompletions.Messages
  alias BeamWeaver.OpenAI.ChatCompletions.Options
  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.OpenAI.ModelPolicy
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.StructuredOutput

  @default_model "gpt-5.5"
  @default_endpoint "https://api.openai.com/v1/chat/completions"

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct model: @default_model,
            endpoint: @default_endpoint,
            api_key: nil,
            organization: nil,
            project: nil,
            model_kwargs: %{},
            temperature: nil,
            logit_bias: nil,
            reasoning_effort: nil,
            max_tokens: nil,
            max_completion_tokens: nil,
            max_output_tokens: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            seed: nil,
            parallel_tool_calls: nil,
            metadata: nil,
            user: nil,
            service_tier: nil,
            prompt_cache_key: nil,
            prompt_cache_options: nil,
            prompt_cache_retention: nil,
            safety_identifier: nil,
            verbosity: nil,
            web_search_options: nil,
            functions: nil,
            function_call: nil,
            modalities: nil,
            audio: nil,
            store: nil,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            include_response_headers: false,
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  use BeamWeaver.Provider.ChatModel

  @doc """
  Builds a Chat Completions model from keyword options.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = ChatOptions.keyword_options(opts)

    model = Keyword.get(opts, :model, @default_model)
    max_completion_tokens = Keyword.get(opts, :max_completion_tokens)
    profile = ChatOptions.profile_option(opts, :openai, model)
    temperature = ModelPolicy.default_temperature(model, Keyword.get(opts, :temperature))

    struct!(
      __MODULE__,
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:profile, profile)
      |> Keyword.put(:temperature, temperature)
      |> ChatOptions.put_present(
        :max_tokens,
        Keyword.get(opts, :max_tokens, max_completion_tokens)
      )
    )
  end

  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    %Options{opts: opts}
    |> Options.to_body(model, messages)
  end

  def count_tokens(%__MODULE__{} = model, input, opts) do
    case model.tokenizer || BeamWeaver.Models.tokenizer_for(model) do
      {:ok, tokenizer} ->
        LanguageModel.count_tokens({:tokenizer, tokenizer}, input, opts)

      tokenizer when not is_nil(tokenizer) ->
        LanguageModel.count_tokens({:tokenizer, tokenizer}, input, opts)

      _missing ->
        {:ok, LanguageModel.count_tokens_approximately(input)}
    end
  end

  defp client(%__MODULE__{} = model) do
    %Client{
      endpoint: model.endpoint,
      api_key: model.api_key,
      organization: model.organization,
      project: model.project,
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    }
  end

  defp model_stream_metadata(%__MODULE__{} = model, body, opts, api) do
    model
    |> InvocationMetadata.openai(body, opts, api)
    |> InvocationMetadata.to_metadata_map()
  end

  defp runtime_adapter do
    %ChatRuntime.Adapter{
      request: &request_body/3,
      invoke: fn model, body, opts -> Client.chat_completions(client(model), body, opts) end,
      stream: fn model, body, opts ->
        Client.chat_completions_stream(client(model), body, opts)
      end,
      stream_response: fn model, body, opts ->
        Client.chat_completions_stream_response(client(model), body, opts)
      end,
      stream_events: fn model, body, opts ->
        Client.chat_completions_stream_typed_events(client(model), body, opts)
      end,
      decode: fn response, _opts -> Messages.response_to_message(response) end,
      parse: fn message, opts ->
        StructuredOutput.maybe_parse(message, opts,
          error_module: Error,
          provider_name: "OpenAI"
        )
      end,
      metadata: fn model, body, opts ->
        model_stream_metadata(model, body, opts, :chat_completions)
      end,
      source: :openai_chat_completions
    }
  end
end
