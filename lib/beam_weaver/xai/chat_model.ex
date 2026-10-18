defmodule BeamWeaver.XAI.ChatModel do
  @moduledoc ~S"""
  XAI chat model implementing the BeamWeaver chat contract.

  Prefer `BeamWeaver.Models.init_chat_model/2` for provider-prefixed identifiers,
  then call `BeamWeaver.Core.ChatModel` or declare the model in an agent.
  Construction does not contact the provider. Model/profile options describe
  local compatibility; account access is established only by a real request.

  See [XAI](providers/xai.md) for endpoint-specific parameters, reasoning,
  media and tools. Preserve complete messages for multi-turn replay. Streaming
  consumers must enumerate once and handle terminal errors; display text is not
  a lossless representation of a native provider turn.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.OpenAI.ChatModel.RequestBuilder
  alias BeamWeaver.OpenAI.ChatModel.TokenCounter
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Provider.StructuredOutput
  alias BeamWeaver.XAI.Client
  alias BeamWeaver.Core.Error
  alias BeamWeaver.XAI.Messages
  alias BeamWeaver.XAI.Tools

  @default_model "grok-4.6"
  @default_endpoint "https://api.x.ai/v1/responses"
  @encrypted_reasoning "reasoning.encrypted_content"

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct model: @default_model,
            endpoint: @default_endpoint,
            api_key: nil,
            x_grok_conv_id: nil,
            default_headers: [],
            extra_body: %{},
            reasoning: nil,
            reasoning_effort: nil,
            verbosity: nil,
            logprobs: nil,
            temperature: nil,
            max_tokens: nil,
            max_completion_tokens: nil,
            max_output_tokens: nil,
            max_turns: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            seed: nil,
            parallel_tool_calls: nil,
            metadata: nil,
            user: nil,
            service_tier: nil,
            prompt_cache_key: nil,
            modalities: nil,
            audio: nil,
            store: nil,
            deferred: nil,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            streaming: false,
            include_response_headers: false,
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  use BeamWeaver.Provider.ChatModel, stream_source: :xai_responses

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = opts |> ChatOptions.keyword_options() |> Compat.expand_base_url(endpoint: "responses")
    model = Keyword.get(opts, :model, @default_model)
    profile = ChatOptions.profile_option(opts, :xai, model)

    struct!(
      __MODULE__,
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:profile, profile)
    )
  end

  def count_tokens(%__MODULE__{} = model, input, opts \\ []),
    do: TokenCounter.count(model, input, opts)

  @spec request_body(t(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  @impl true
  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    with {:ok, body} <- RequestBuilder.request_body(model, messages, opts, response_id: &Messages.response_id/1),
         body = body |> Messages.preserve_xai_open_object_maps() |> include_encrypted_reasoning(model, opts),
         :ok <- validate_tools(body),
         do: {:ok, body}
  end

  defp validate_tools(%{"tools" => tools}) when is_list(tools), do: Tools.validate_responses_tools(tools)
  defp validate_tools(_body), do: :ok

  # A reasoning model sees its earlier thinking only when the request sends it
  # back, and xAI returns that thinking, encrypted, only when asked. The reply's
  # reasoning blocks keep it, so the next request replays it. An `include` in
  # `extra_body` replaces the list.
  defp include_encrypted_reasoning(body, model, opts) do
    if reasoning_model?(model) and not Map.has_key?(ProviderOptions.extra_body(model, opts), "include"),
      do: Map.update(body, "include", [@encrypted_reasoning], &Enum.uniq(List.wrap(&1) ++ [@encrypted_reasoning])),
      else: body
  end

  defp reasoning_model?(%__MODULE__{profile: %{reasoning_output: false}}), do: false
  defp reasoning_model?(%__MODULE__{}), do: true

  defp client(%__MODULE__{} = model) do
    %Client{
      endpoint: model.endpoint,
      api_key: model.api_key,
      x_grok_conv_id: model.x_grok_conv_id,
      default_headers: model.default_headers || [],
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    }
  end

  @impl true
  def stream_metadata(%__MODULE__{} = model, body, opts),
    do: model |> InvocationMetadata.provider(:xai, body, opts, :responses) |> InvocationMetadata.to_metadata_map()

  @impl true
  def send_request(:invoke, model, body, opts), do: Client.responses(client(model), body, opts)
  def send_request(:stream, model, body, opts), do: Client.responses_stream(client(model), body, opts)
  def send_request(:stream_response, model, body, opts), do: Client.responses_stream_response(client(model), body, opts)

  def send_request(:stream_events, model, body, opts),
    do: Client.responses_stream_typed_events(client(model), body, opts)

  @impl true
  def decode_response(response, _opts), do: Messages.responses_to_message(response)

  @impl true
  def parse_response(_model, message, opts),
    do: StructuredOutput.maybe_parse(message, opts, provider_name: "xAI", refusal?: true)
end
