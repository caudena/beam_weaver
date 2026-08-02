defmodule BeamWeaver.DeepSeek.ChatModel do
  @moduledoc """
  DeepSeek OpenAI-compatible Chat Completions model.
  """

  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.DeepSeek.Client
  alias BeamWeaver.DeepSeek.Error
  alias BeamWeaver.DeepSeek.Messages
  alias BeamWeaver.DeepSeek.Options
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.StructuredOutput

  @default_model "deepseek-v4-flash"
  @default_base_url "https://api.deepseek.com"
  @default_endpoint @default_base_url <> "/chat/completions"
  @default_beta_endpoint @default_base_url <> "/beta/chat/completions"

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct model: @default_model,
            base_url: @default_base_url,
            endpoint: @default_endpoint,
            beta_endpoint: @default_beta_endpoint,
            api_key: nil,
            default_headers: [],
            model_kwargs: %{},
            thinking: nil,
            reasoning_effort: nil,
            temperature: nil,
            max_tokens: nil,
            max_completion_tokens: nil,
            max_output_tokens: nil,
            top_p: nil,
            stop: nil,
            response_format: nil,
            structured_output: nil,
            tool_choice: nil,
            logprobs: nil,
            top_logprobs: nil,
            user_id: nil,
            stream_usage: true,
            streaming: false,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            include_response_headers: false,
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  use BeamWeaver.Provider.ChatModel

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = ChatOptions.keyword_options(opts)
    opts = normalize_endpoint_opts(opts)
    model = Keyword.get(opts, :model, @default_model)
    profile = ChatOptions.profile_option(opts, :deepseek, model)

    struct!(
      __MODULE__,
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:profile, profile)
    )
  end

  @spec request_body(t(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request_body(%__MODULE__{} = model, messages, opts \\ []),
    do: Options.to_body(model, messages, opts)

  def count_tokens(%__MODULE__{} = model, input, opts \\ []) do
    case model.tokenizer || BeamWeaver.Models.tokenizer_for(model) do
      {:ok, tokenizer} -> LanguageModel.count_tokens({:tokenizer, tokenizer}, input, opts)
      tokenizer when not is_nil(tokenizer) -> LanguageModel.count_tokens({:tokenizer, tokenizer}, input, opts)
      _missing -> {:ok, LanguageModel.count_tokens_approximately(input)}
    end
  end

  defp normalize_endpoint_opts(opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url) || @default_base_url

    client_opts =
      [base_url: base_url]
      |> maybe_put_client_endpoint(:endpoint, Keyword.get(opts, :endpoint))
      |> maybe_put_client_endpoint(
        :beta_chat_completions_endpoint,
        Keyword.get(opts, :beta_endpoint)
      )

    client = Client.new(client_opts)

    opts
    |> Keyword.put(:base_url, base_url)
    |> Keyword.put_new(:endpoint, client.chat_completions_endpoint)
    |> Keyword.put_new(:beta_endpoint, client.beta_chat_completions_endpoint)
  end

  defp maybe_put_client_endpoint(opts, _key, nil), do: opts
  defp maybe_put_client_endpoint(opts, key, value), do: Keyword.put(opts, key, value)

  defp client(%__MODULE__{} = model) do
    Client.new(
      base_url: model.base_url,
      endpoint: model.endpoint,
      chat_completions_endpoint: model.endpoint,
      beta_chat_completions_endpoint: model.beta_endpoint,
      api_key: model.api_key,
      default_headers: model.default_headers || [],
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    )
  end

  defp model_stream_metadata(%__MODULE__{} = model, body, opts) do
    model
    |> InvocationMetadata.provider(:deepseek, body, opts, :chat_completions)
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
      decode: fn
        %BeamWeaver.Core.Message{} = message, _opts -> {:ok, message}
        response, _opts -> Messages.chat_response_to_message(response)
      end,
      parse: fn model, message, opts ->
        StructuredOutput.maybe_parse(message, Options.response_parse_opts(model, opts),
          error_module: Error,
          provider_name: "DeepSeek"
        )
      end,
      metadata: &model_stream_metadata/3,
      source: :deepseek_chat_completions
    }
  end
end
