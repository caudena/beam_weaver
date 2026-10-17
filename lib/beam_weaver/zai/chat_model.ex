defmodule BeamWeaver.ZAI.ChatModel do
  @moduledoc """
  Z.ai GLM Chat Completions chat model implementation.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.MapShape
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.StructuredOutput
  alias BeamWeaver.ZAI.Client
  alias BeamWeaver.Core.Error
  alias BeamWeaver.ZAI.Messages
  alias BeamWeaver.ZAI.Options
  alias BeamWeaver.ZAI.Tools

  @default_model "glm-5.2"
  @default_endpoint "https://api.z.ai/api/paas/v4/chat/completions"

  defstruct model: @default_model,
            endpoint: @default_endpoint,
            api_key: nil,
            default_headers: [],
            extra_body: %{},
            do_sample: nil,
            temperature: nil,
            top_p: nil,
            max_tokens: nil,
            max_completion_tokens: nil,
            max_output_tokens: nil,
            stop: nil,
            thinking: nil,
            reasoning_effort: nil,
            tool_stream: nil,
            response_format: nil,
            structured_output: nil,
            tool_choice: nil,
            stream_usage: true,
            request_id: nil,
            user_id: nil,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            streaming: false,
            include_response_headers: false,
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  use BeamWeaver.Provider.ChatModel, stream_source: :zai_chat_completions

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = ChatOptions.keyword_options(opts)
    opts = Compat.expand_base_url(opts, endpoint: "chat/completions")
    model = Keyword.get(opts, :model, @default_model)
    profile = ChatOptions.profile_option(opts, :zai, model)

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
    with {:ok, body} <- Options.to_body(model, messages, Keyword.delete(opts, :tools)),
         tools = opts |> Keyword.get(:tools, []) |> Tools.to_chat_tools(),
         :ok <- Tools.validate_chat_tools(tools),
         do: {:ok, body |> ChatCompletionsWire.put_stream_usage(model, opts) |> MapShape.put_optional("tools", tools)}
  end

  def count_tokens(%__MODULE__{}, input, _opts \\ []),
    do: {:ok, LanguageModel.count_tokens_approximately(input)}

  defp client(%__MODULE__{} = model) do
    %Client{
      endpoint: model.endpoint,
      chat_completions_endpoint: model.endpoint,
      api_key: model.api_key,
      default_headers: model.default_headers || [],
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    }
  end

  @impl true
  def stream_metadata(%__MODULE__{} = model, body, opts) do
    model
    |> InvocationMetadata.provider(:zai, body, opts, :chat_completions)
    |> InvocationMetadata.to_metadata_map()
  end

  @impl true
  def send_request(:invoke, model, body, opts), do: Client.chat_completions(client(model), body, opts)
  def send_request(:stream, model, body, opts), do: Client.chat_completions_stream(client(model), body, opts)

  def send_request(:stream_response, model, body, opts),
    do: Client.chat_completions_stream_response(client(model), body, opts)

  def send_request(:stream_events, model, body, opts),
    do: Client.chat_completions_stream_typed_events(client(model), body, opts)

  # Z.ai takes only automatic tool choice.
  @impl true
  def forced_tool_choice?(_model, _opts), do: false

  @impl true
  def decode_response(%BeamWeaver.Core.Message{} = message, _opts), do: {:ok, message}
  def decode_response(response, _opts), do: Messages.chat_response_to_message(response)

  @impl true
  def parse_response(_model, message, opts),
    do: StructuredOutput.maybe_parse(message, opts, provider_name: "Z.ai")
end
