defmodule BeamWeaver.OpenAI.ChatModel do
  @moduledoc ~S"""
  OpenAI chat model implementing the BeamWeaver chat contract.

  Prefer `BeamWeaver.Models.init_chat_model/2` for provider-prefixed identifiers,
  then call `BeamWeaver.Core.ChatModel` or declare the model in an agent.
  Construction does not contact the provider. Model/profile options describe
  local compatibility; account access is established only by a real request.

  See [OpenAI](providers/openai.md) for endpoint-specific parameters, reasoning,
  media and tools. Preserve complete messages for multi-turn replay. Streaming
  consumers must enumerate once and handle terminal errors; display text is not
  a lossless representation of a native provider turn.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.OpenAI.ChatModel.RequestBuilder
  alias BeamWeaver.OpenAI.ChatModel.TokenCounter
  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.Messages
  alias BeamWeaver.OpenAI.ModelPolicy
  alias BeamWeaver.OpenAI.RequestMetadata
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Provider.StructuredOutput

  @default_model "gpt-5.5"
  @default_endpoint "https://api.openai.com/v1/responses"

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct model: @default_model,
            endpoint: @default_endpoint,
            api_key: nil,
            organization: nil,
            project: nil,
            default_headers: [],
            extra_body: %{},
            access_programs: nil,
            reasoning: nil,
            reasoning_effort: nil,
            verbosity: nil,
            temperature: nil,
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

  @type t :: %__MODULE__{
          model: String.t(),
          endpoint: String.t(),
          api_key: String.t() | (-> String.t() | nil) | nil,
          organization: String.t() | nil,
          project: String.t() | nil,
          default_headers: [{String.t(), String.t()}],
          extra_body: map(),
          access_programs: map() | nil,
          reasoning: map() | nil,
          reasoning_effort: atom() | String.t() | nil,
          verbosity: atom() | String.t() | nil,
          temperature: number() | nil,
          max_tokens: pos_integer() | nil,
          max_completion_tokens: pos_integer() | nil,
          max_output_tokens: pos_integer() | nil,
          top_p: number() | nil,
          frequency_penalty: number() | nil,
          presence_penalty: number() | nil,
          seed: integer() | nil,
          parallel_tool_calls: boolean() | nil,
          metadata: map() | nil,
          moderation: map() | nil,
          user: String.t() | nil,
          service_tier: String.t() | atom() | nil,
          prompt_cache_key: String.t() | nil,
          prompt_cache_options: map() | nil,
          prompt_cache_retention: String.t() | atom() | nil,
          safety_identifier: String.t() | nil,
          modalities: [String.t()] | nil,
          audio: map() | nil,
          store: boolean() | nil,
          tokenizer: term() | nil,
          streaming: boolean(),
          include_response_headers: boolean(),
          transport: module(),
          transport_opts: keyword(),
          timeout: non_neg_integer()
        }

  use BeamWeaver.Provider.ChatModel, stream_source: :openai_responses, exact_stream_events: true

  @doc """
  Builds a chat model from keyword options.

  Options are the struct's fields; set the model with `:model`, and the API
  with `:base_url` (the API root, such as `"https://api.openai.com/v1"`) or the
  full `:endpoint` URL. Unknown options, such as `:model_name`, raise a
  `KeyError`.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = opts |> ChatOptions.keyword_options() |> Compat.expand_base_url(endpoint: "responses")

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
      |> BeamWeaver.MapShape.put_present(:max_tokens, Keyword.get(opts, :max_tokens, max_completion_tokens))
    )
  end

  def count_tokens(%__MODULE__{} = model, input, opts), do: TokenCounter.count(model, input, opts)

  @doc """
  Streams through the Responses API and returns content-block lifecycle events.
  """
  @spec stream_events(t(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  @impl true
  def stream_events(%__MODULE__{} = model, messages, opts \\ []) do
    with {:ok, body} <- request_body(model, messages, Keyword.put(opts, :stream, true)) do
      Client.responses_stream_events(client(model), body, opts)
    end
  end

  @doc """
  Builds the OpenAI Responses API request body for a chat invocation.
  """
  @spec request_body(t(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  @impl true
  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, model.metadata)

    with :ok <- RequestMetadata.validate(metadata, Keyword.get(opts, :model, model.model)),
         do: RequestBuilder.request_body(model, messages, opts)
  end

  defp client(%__MODULE__{} = model) do
    fields = ~w(endpoint api_key organization project default_headers transport transport_opts timeout)a
    struct(Client, Map.take(model, fields))
  end

  @impl true
  def stream_metadata(%__MODULE__{} = model, body, opts),
    do: model |> InvocationMetadata.openai(body, opts, :responses) |> InvocationMetadata.to_metadata_map()

  @impl true
  def send_request(:invoke, model, body, opts), do: Client.responses(client(model), body, opts)
  def send_request(:stream, model, body, opts), do: Client.responses_stream(client(model), body, opts)
  def send_request(:stream_response, model, body, opts), do: Client.responses_stream_response(client(model), body, opts)

  def send_request(:stream_events, model, body, opts),
    do: Client.responses_stream_typed_events(client(model), body, opts)

  def send_request(:exact_stream_events, model, body, opts),
    do: Client.responses_stream_typed_events(client(model), body, opts)

  @impl true
  def decode_response(response, _opts), do: Messages.response_to_message(response)

  @impl true
  def parse_response(_model, message, opts),
    do: StructuredOutput.maybe_parse(message, opts, provider_name: "OpenAI", refusal?: true)
end
