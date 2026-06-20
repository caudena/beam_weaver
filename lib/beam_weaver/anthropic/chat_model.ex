defmodule BeamWeaver.Anthropic.ChatModel do
  @moduledoc """
  Anthropic Messages API chat model implementation.
  """

  alias BeamWeaver.Anthropic.ChatModel.RequestBuilder
  alias BeamWeaver.Anthropic.Client
  alias BeamWeaver.Anthropic.Error
  alias BeamWeaver.Anthropic.Messages
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.StructuredOutput

  @default_model "claude-haiku-4-5-20251001"
  @default_endpoint "https://api.anthropic.com/v1/messages"

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct model: @default_model,
            endpoint: @default_endpoint,
            count_tokens_endpoint: "https://api.anthropic.com/v1/messages/count_tokens",
            api_key: nil,
            anthropic_version: "2023-06-01",
            betas: [],
            default_headers: [],
            model_kwargs: %{},
            cache_control: nil,
            container: nil,
            metadata: nil,
            max_tokens: nil,
            temperature: nil,
            top_k: nil,
            top_p: nil,
            stop_sequences: nil,
            service_tier: nil,
            thinking: nil,
            output_config: nil,
            effort: nil,
            mcp_servers: nil,
            context_management: nil,
            diagnostics: nil,
            reuse_last_container: nil,
            inference_geo: nil,
            speed: nil,
            user_profile_id: nil,
            parallel_tool_calls: nil,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            streaming: false,
            stream_usage: true,
            include_response_headers: false,
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  use BeamWeaver.Provider.ChatModel

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = ChatOptions.keyword_options(opts)
    model = Keyword.get(opts, :model, @default_model)
    profile = ChatOptions.profile_option(opts, :anthropic, model)
    max_tokens = Keyword.get(opts, :max_tokens)

    struct!(
      __MODULE__,
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:profile, profile)
      |> ChatOptions.put_present(:max_tokens, max_tokens || profile.max_output_tokens || 4096)
    )
  end

  @spec count_tokens(t(), term(), keyword()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def count_tokens(%__MODULE__{} = model, input, opts \\ []) do
    with {:ok, messages} <- LanguageModel.normalize_chat_input(input),
         {:ok, body} <- RequestBuilder.count_tokens_body(model, messages, opts),
         {body, opts} = thread_betas(body, opts),
         {:ok, response} <- Client.count_tokens(client(model), body, opts) do
      {:ok, response["input_tokens"] || response[:input_tokens] || 0}
    else
      {:error, %BeamWeaver.Core.Error{} = error} ->
        {:error, Error.new(error.type, error.message, error.details)}

      {:error, _error} = error ->
        error
    end
  end

  @impl true
  def stream_events(%__MODULE__{} = model, messages, opts \\ []) do
    with {:ok, body} <- request_body(model, messages, Keyword.put(opts, :stream, true)) do
      {body, opts} = thread_betas(body, opts)
      Client.messages_stream_events(client(model), body, opts)
    end
  end

  @spec request_body(t(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request_body(%__MODULE__{} = model, messages, opts \\ []),
    do: RequestBuilder.request_body(model, messages, opts)

  defp client(%__MODULE__{} = model) do
    %Client{
      endpoint: model.endpoint,
      count_tokens_endpoint: model.count_tokens_endpoint,
      api_key: model.api_key,
      anthropic_version: model.anthropic_version,
      betas: model.betas || [],
      default_headers: model.default_headers || [],
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    }
  end

  defp thread_betas(body, opts) do
    case Map.pop(body, "betas") do
      {nil, body} ->
        {body, opts}

      {betas, body} ->
        betas = List.wrap(betas)

        opts =
          Keyword.update(opts, :betas, betas, fn existing ->
            Enum.uniq(List.wrap(existing) ++ betas)
          end)

        {body, opts}
    end
  end

  defp runtime_adapter do
    %ChatRuntime.Adapter{
      request: &request_body/3,
      invoke: fn model, body, opts ->
        {body, opts} = thread_betas(body, opts)
        Client.messages(client(model), body, opts)
      end,
      stream: fn model, body, opts ->
        {body, opts} = thread_betas(body, opts)
        Client.messages_stream(client(model), body, opts)
      end,
      stream_response: fn model, body, opts ->
        {body, opts} = thread_betas(body, opts)
        Client.messages_stream_response(client(model), body, opts)
      end,
      decode: fn response, _opts -> Messages.response_to_message(response) end,
      parse: fn message, opts ->
        StructuredOutput.maybe_parse(message, opts,
          error_module: Error,
          provider_name: "Anthropic",
          on_decode_error: :ok
        )
      end
    }
  end
end
