defmodule BeamWeaver.DeepSeek.ChatModel do
  @moduledoc """
  DeepSeek OpenAI-compatible Chat Completions model.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.DeepSeek.Client
  alias BeamWeaver.Core.Error
  alias BeamWeaver.DeepSeek.Messages
  alias BeamWeaver.DeepSeek.Options
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.StructuredOutput

  @default_model "deepseek-flash"
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
            extra_body: %{},
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

  use BeamWeaver.Provider.ChatModel, stream_source: :deepseek_chat_completions

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
  @impl true
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

  @impl true
  def stream_metadata(%__MODULE__{} = model, body, opts) do
    model
    |> InvocationMetadata.provider(:deepseek, body, opts, :chat_completions)
    |> InvocationMetadata.to_metadata_map()
  end

  @impl true
  def send_request(:invoke, model, body, opts), do: Client.chat_completions(client(model), body, opts)
  def send_request(:stream, model, body, opts), do: Client.chat_completions_stream(client(model), body, opts)

  def send_request(:stream_response, model, body, opts),
    do: Client.chat_completions_stream_response(client(model), body, opts)

  def send_request(:stream_events, model, body, opts),
    do: Client.chat_completions_stream_typed_events(client(model), body, opts)

  @impl true
  def forced_tool_choice?(%__MODULE__{} = model, opts), do: Options.forced_tool_choice?(model, opts)

  @impl true
  def decode_response(%BeamWeaver.Core.Message{} = message, _opts), do: {:ok, message}
  def decode_response(response, _opts), do: Messages.chat_response_to_message(response)

  @impl true
  def parse_response(model, message, opts),
    do: StructuredOutput.maybe_parse(message, Options.response_parse_opts(model, opts), provider_name: "DeepSeek")
end
