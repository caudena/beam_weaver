defmodule BeamWeaver.XAI.ChatModel do
  @moduledoc """
  xAI Responses API chat model implementation.
  """

  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.OpenAI.ChatModel.RequestBuilder
  alias BeamWeaver.OpenAI.ChatModel.TokenCounter
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.StructuredOutput
  alias BeamWeaver.XAI.Client
  alias BeamWeaver.XAI.Error
  alias BeamWeaver.XAI.Messages
  alias BeamWeaver.XAI.Tools

  @default_model "grok-4.5"
  @default_endpoint "https://api.x.ai/v1/responses"

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct model: @default_model,
            endpoint: @default_endpoint,
            api_key: nil,
            x_grok_conv_id: nil,
            default_headers: [],
            model_kwargs: %{},
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
            search_parameters: nil,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            streaming: false,
            include_response_headers: false,
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  use BeamWeaver.Provider.ChatModel

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = ChatOptions.keyword_options(opts)
    opts = normalize_endpoint_opts(opts, "responses")
    model = Keyword.get(opts, :model, @default_model)
    profile = ChatOptions.profile_option(opts, :xai, model)

    struct!(
      __MODULE__,
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:profile, profile)
      |> ChatOptions.put_present(:max_output_tokens, Keyword.get(opts, :max_output_tokens))
    )
  end

  def count_tokens(%__MODULE__{} = model, input, opts \\ []),
    do: TokenCounter.count(model, input, opts)

  @spec request_body(t(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    opts = maybe_drop_stop_for_reasoning(model, opts)

    model
    |> RequestBuilder.request_body(messages, opts)
    |> convert_error()
    |> normalize_xai_structured_output()
    |> validate_tools()
  end

  defp normalize_xai_structured_output({:ok, body}),
    do: {:ok, Messages.preserve_xai_open_object_maps(body)}

  defp normalize_xai_structured_output(other), do: other

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

  defp convert_error({:error, %BeamWeaver.OpenAI.Error{} = error}) do
    {:error, Error.new(error.type, error.message, error.details)}
  end

  defp convert_error(other), do: other

  defp validate_tools({:ok, %{"tools" => tools} = body}) when is_list(tools) do
    case Tools.validate_responses_tools(tools) do
      :ok -> {:ok, body}
      {:error, _error} = error -> error
    end
  end

  defp validate_tools(other), do: other

  defp maybe_drop_stop_for_reasoning(%__MODULE__{profile: %{reasoning_output: true}}, opts),
    do: Keyword.delete(opts, :stop)

  defp maybe_drop_stop_for_reasoning(_model, opts), do: opts

  defp normalize_endpoint_opts(opts, endpoint_path) do
    case {Keyword.fetch(opts, :base_url), Keyword.has_key?(opts, :endpoint)} do
      {{:ok, base_url}, false} ->
        opts
        |> Keyword.delete(:base_url)
        |> Keyword.put(:endpoint, Client.endpoint(base_url, endpoint_path))

      {{:ok, _base_url}, true} ->
        Keyword.delete(opts, :base_url)

      _other ->
        opts
    end
  end

  defp model_stream_metadata(%__MODULE__{} = model, body, opts, api) do
    model
    |> InvocationMetadata.provider(:xai, body, opts, api)
    |> InvocationMetadata.to_metadata_map()
  end

  defp runtime_adapter do
    %ChatRuntime.Adapter{
      request: &request_body/3,
      invoke: fn model, body, opts -> Client.responses(client(model), body, opts) end,
      stream: fn model, body, opts -> Client.responses_stream(client(model), body, opts) end,
      stream_response: fn model, body, opts ->
        Client.responses_stream_response(client(model), body, opts)
      end,
      stream_events: fn model, body, opts ->
        Client.responses_stream_typed_events(client(model), body, opts)
      end,
      decode: fn response, _opts -> Messages.responses_to_message(response) end,
      parse: fn message, opts ->
        StructuredOutput.maybe_parse(message, opts,
          error_module: Error,
          provider_name: "xAI",
          refusal?: true
        )
      end,
      metadata: fn model, body, opts -> model_stream_metadata(model, body, opts, :responses) end,
      source: :xai_responses
    }
  end
end
