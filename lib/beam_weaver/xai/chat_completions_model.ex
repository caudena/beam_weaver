defmodule BeamWeaver.XAI.ChatCompletionsModel do
  @moduledoc ~S"""
  XAI Chat Completions model implementing the BeamWeaver chat contract.

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
  alias BeamWeaver.OpenAI.ChatCompletions.Options.Body
  alias BeamWeaver.OpenAI.ChatModel.TokenCounter
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.StructuredOutput
  alias BeamWeaver.XAI.Client
  alias BeamWeaver.Core.Error
  alias BeamWeaver.XAI.Messages
  alias BeamWeaver.XAI.Tools

  @default_model "grok-4.6"
  @default_endpoint "https://api.x.ai/v1/chat/completions"

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct model: @default_model,
            endpoint: @default_endpoint,
            api_key: nil,
            x_grok_conv_id: nil,
            default_headers: [],
            extra_body: %{},
            guidelines: nil,
            prompt_cache_key: nil,
            safety_identifier: nil,
            temperature: nil,
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
            modalities: nil,
            audio: nil,
            store: nil,
            n: nil,
            deferred: nil,
            stream_usage: true,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            streaming: false,
            include_response_headers: false,
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  use BeamWeaver.Provider.ChatModel, stream_source: :xai_chat_completions

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = opts |> ChatOptions.keyword_options() |> Compat.expand_base_url(endpoint: "chat/completions")
    model = Keyword.get(opts, :model, @default_model)
    profile = ChatOptions.profile_option(opts, :xai, model)
    n = Keyword.get(opts, :n)
    streaming = Keyword.get(opts, :streaming, false)

    if n && n < 1 do
      raise ArgumentError, "n must be at least 1"
    end

    if streaming && n && n != 1 do
      raise ArgumentError, "n must be 1 when streaming"
    end

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
  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    with :ok <- validate_stop(model, opts),
         {:ok, body} <- Body.to_body(model, messages, Keyword.delete(opts, :tools)),
         {:ok, body} <- put_tools(body, Keyword.get(opts, :tools, [])) do
      {:ok,
       body
       |> Messages.preserve_xai_open_object_maps()
       |> ChatCompletionsWire.put_stream_usage(model, opts)
       |> BeamWeaver.MapShape.put_optional("deferred", Keyword.get(opts, :deferred, model.deferred))}
    end
  end

  def count_tokens(%__MODULE__{} = model, input, opts), do: TokenCounter.count_text(model, input, opts)

  defp client(%__MODULE__{} = model) do
    %Client{
      endpoint: model.endpoint,
      chat_completions_endpoint: model.endpoint,
      api_key: model.api_key,
      x_grok_conv_id: model.x_grok_conv_id,
      default_headers: model.default_headers || [],
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    }
  end

  defp put_tools(body, [_ | _] = tools) do
    with {:ok, chat_tools} <- Tools.render_chat_completions_tools(tools),
         :ok <- Tools.validate_chat_completions_tools(chat_tools),
         do: {:ok, Map.put(body, "tools", chat_tools)}
  end

  defp put_tools(body, _tools), do: {:ok, body}

  # Grok reasoning models take no stop sequences.
  defp validate_stop(%__MODULE__{profile: %{reasoning_output: true}} = model, opts) do
    if Keyword.get(opts, :stop) in [nil, []] do
      :ok
    else
      {:error,
       Error.new(:unsupported_model_param, "xAI reasoning models do not take stop sequences", %{
         provider: :xai,
         model: Keyword.get(opts, :model, model.model),
         params: [:stop]
       })}
    end
  end

  defp validate_stop(_model, _opts), do: :ok

  @impl true
  def stream_metadata(%__MODULE__{} = model, body, opts),
    do:
      model |> InvocationMetadata.provider(:xai, body, opts, :chat_completions) |> InvocationMetadata.to_metadata_map()

  @impl true
  def send_request(:invoke, model, body, opts), do: Client.chat_completions(client(model), body, opts)
  def send_request(:stream, model, body, opts), do: Client.chat_completions_stream(client(model), body, opts)

  def send_request(:stream_response, model, body, opts),
    do: Client.chat_completions_stream_response(client(model), body, opts)

  def send_request(:stream_events, model, body, opts),
    do: Client.chat_completions_stream_typed_events(client(model), body, opts)

  @impl true
  def decode_response(response, _opts), do: Messages.chat_completions_to_message(response)

  @impl true
  def parse_response(_model, message, opts),
    do: StructuredOutput.maybe_parse(message, opts, provider_name: "xAI")
end
