defmodule BeamWeaver.OpenAI.ChatCompletionsModel do
  @moduledoc """
  OpenAI Chat Completions chat model implementation.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.OpenAI.ChatCompletions.Messages
  alias BeamWeaver.OpenAI.ChatCompletions.Options.Body
  alias BeamWeaver.OpenAI.ChatModel.TokenCounter
  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.OpenAI.ModelPolicy
  alias BeamWeaver.OpenAI.RequestMetadata
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Provider.StructuredOutput

  @default_model "gpt-5.5"
  @default_endpoint "https://api.openai.com/v1/chat/completions"

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct model: @default_model,
            endpoint: @default_endpoint,
            api_key: nil,
            organization: nil,
            project: nil,
            extra_body: %{},
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
            moderation: nil,
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
            streaming: false,
            include_response_headers: false,
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  use BeamWeaver.Provider.ChatModel, stream_source: :openai_chat_completions

  @doc """
  Builds a Chat Completions model from keyword options.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = opts |> ChatOptions.keyword_options() |> Compat.expand_base_url(endpoint: "chat/completions")

    model = Keyword.get(opts, :model, @default_model)
    profile = ChatOptions.profile_option(opts, :openai, model)
    temperature = ModelPolicy.default_temperature(model, Keyword.get(opts, :temperature))

    struct!(
      __MODULE__,
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:profile, profile)
      |> Keyword.put(:temperature, temperature)
    )
  end

  @impl true
  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, model.metadata)

    with :ok <- RequestMetadata.validate(metadata, Keyword.get(opts, :model, model.model)),
         do: Body.to_body(model, messages, opts)
  end

  def count_tokens(%__MODULE__{} = model, input, opts), do: TokenCounter.count_text(model, input, opts)

  defp client(%__MODULE__{} = model) do
    %Client{
      chat_completions_endpoint: model.endpoint,
      api_key: model.api_key,
      organization: model.organization,
      project: model.project,
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    }
  end

  @impl true
  def stream_metadata(%__MODULE__{} = model, body, opts),
    do: model |> InvocationMetadata.openai(body, opts, :chat_completions) |> InvocationMetadata.to_metadata_map()

  @impl true
  def send_request(:invoke, model, body, opts), do: Client.chat_completions(client(model), body, opts)
  def send_request(:stream, model, body, opts), do: Client.chat_completions_stream(client(model), body, opts)

  def send_request(:stream_response, model, body, opts),
    do: Client.chat_completions_stream_response(client(model), body, opts)

  def send_request(:stream_events, model, body, opts),
    do: Client.chat_completions_stream_typed_events(client(model), body, opts)

  @impl true
  def decode_response(response, _opts), do: Messages.response_to_message(response)

  @impl true
  def parse_response(_model, message, opts),
    do: StructuredOutput.maybe_parse(message, opts, provider_name: "OpenAI")
end
