defmodule BeamWeaver.XAI.ChatCompletionsModel do
  @moduledoc """
  xAI Chat Completions chat model implementation.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.OpenAI.ChatCompletions.Options
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
            search_parameters: nil,
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
    opts = ChatOptions.keyword_options(opts)
    opts = Compat.expand_base_url(opts, endpoint: "chat/completions")
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
    tools = Keyword.get(opts, :tools, [])

    with :ok <- validate_stop(model, opts) do
      %Options{opts: Keyword.delete(opts, :tools)}
      |> Options.to_body(model, messages)
      |> normalize_xai_structured_output()
      |> maybe_put_stream_usage(model, opts)
      |> maybe_put_tools(tools)
      |> maybe_put_deferred(model, opts)
    end
  end

  defp normalize_xai_structured_output({:ok, body}),
    do: {:ok, Messages.preserve_xai_open_object_maps(body)}

  defp normalize_xai_structured_output(other), do: other

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
      chat_completions_endpoint: model.endpoint,
      api_key: model.api_key,
      x_grok_conv_id: model.x_grok_conv_id,
      default_headers: model.default_headers || [],
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    }
  end

  defp maybe_put_tools({:ok, body}, []), do: {:ok, body}

  defp maybe_put_tools({:ok, body}, tools) when is_list(tools) do
    with {:ok, chat_tools} <- Tools.render_chat_completions_tools(tools),
         :ok <- Tools.validate_chat_completions_tools(chat_tools) do
      {:ok, Map.put(body, "tools", chat_tools)}
    end
  end

  defp maybe_put_tools(other, _tools), do: other

  defp maybe_put_stream_usage({:ok, body}, model, opts) do
    stream? = Keyword.get(opts, :stream, false)
    stream_usage? = Keyword.get(opts, :stream_usage, model.stream_usage)

    cond do
      not stream? ->
        {:ok, body}

      not stream_usage? ->
        {:ok, body}

      Map.has_key?(body, "stream_options") ->
        {:ok, body}

      true ->
        {:ok, Map.put(body, "stream_options", %{"include_usage" => true})}
    end
  end

  defp maybe_put_stream_usage(other, _model, _opts), do: other

  defp maybe_put_deferred({:ok, body}, model, opts) do
    {:ok, put_optional(body, "deferred", Keyword.get(opts, :deferred, model.deferred))}
  end

  defp maybe_put_deferred(other, _model, _opts), do: other

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
  def stream_metadata(%__MODULE__{} = model, body, opts), do: stream_metadata(model, body, opts, :chat_completions)

  defp stream_metadata(%__MODULE__{} = model, body, opts, api) do
    model
    |> InvocationMetadata.provider(:xai, body, opts, api)
    |> InvocationMetadata.to_metadata_map()
  end

  defp put_optional(body, _key, nil), do: body
  defp put_optional(body, _key, []), do: body
  defp put_optional(body, key, value), do: Map.put(body, key, value)

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
