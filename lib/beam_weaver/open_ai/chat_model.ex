defmodule BeamWeaver.OpenAI.ChatModel do
  @moduledoc """
  Responses API chat model implementation for the first non-Azure OpenAI slice.
  """

  alias BeamWeaver.OpenAI.ChatModel.RequestBuilder
  alias BeamWeaver.OpenAI.ChatModel.StructuredOutput
  alias BeamWeaver.OpenAI.ChatModel.TokenCounter
  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.OpenAI.Messages
  alias BeamWeaver.OpenAI.ModelPolicy
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions

  @default_model "gpt-5.5"
  @default_endpoint "https://api.openai.com/v1/responses"

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct model: @default_model,
            endpoint: @default_endpoint,
            api_key: nil,
            organization: nil,
            project: nil,
            model_kwargs: %{},
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
            user: nil,
            service_tier: nil,
            prompt_cache_key: nil,
            prompt_cache_retention: nil,
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
          model_kwargs: map(),
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
          user: String.t() | nil,
          service_tier: String.t() | atom() | nil,
          prompt_cache_key: String.t() | nil,
          prompt_cache_retention: String.t() | atom() | nil,
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

  use BeamWeaver.Provider.ChatModel

  @doc """
  Builds a chat model from keyword options.

  The public struct is the idiomatic Elixir representation. Use `:model` and
  `:endpoint` explicitly; Python-style constructor aliases are intentionally not
  accepted.
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = ChatOptions.keyword_options(opts)

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
      |> ChatOptions.put_present(
        :max_tokens,
        Keyword.get(opts, :max_tokens, max_completion_tokens)
      )
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
  def request_body(%__MODULE__{} = model, messages, opts \\ []),
    do: RequestBuilder.request_body(model, messages, opts)

  defp client(%__MODULE__{} = model) do
    %Client{
      endpoint: model.endpoint,
      api_key: model.api_key,
      organization: model.organization,
      project: model.project,
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    }
  end

  defp runtime_adapter do
    %ChatRuntime.Adapter{
      request: &request_body/3,
      invoke: fn model, body, opts -> Client.responses(client(model), body, opts) end,
      stream: fn model, body, opts -> Client.responses_stream(client(model), body, opts) end,
      stream_response: fn model, body, opts ->
        Client.responses_stream_response(client(model), body, opts)
      end,
      decode: fn response, _opts -> Messages.response_to_message(response) end,
      parse: &StructuredOutput.maybe_parse/2
    }
  end
end
