defmodule BeamWeaver.Moonshot.ChatModel do
  @moduledoc """
  Moonshot/Kimi Chat Completions chat model implementation.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.Provider.OpenAICompatibleClient, as: Compat
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Moonshot.Client
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Moonshot.Messages
  alias BeamWeaver.Moonshot.Options
  alias BeamWeaver.Moonshot.Tools
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Provider.StructuredOutput

  @default_model "kimi-k2.6"
  @default_endpoint "https://api.moonshot.ai/v1/chat/completions"
  @default_count_tokens_endpoint "https://api.moonshot.ai/v1/tokenizers/estimate-token-count"

  defstruct model: @default_model,
            endpoint: @default_endpoint,
            count_tokens_endpoint: @default_count_tokens_endpoint,
            api_key: nil,
            default_headers: [],
            extra_body: %{},
            temperature: nil,
            max_tokens: nil,
            max_completion_tokens: nil,
            max_output_tokens: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            n: nil,
            prompt_cache_key: nil,
            reasoning_effort: nil,
            safety_identifier: nil,
            thinking: nil,
            response_format: nil,
            structured_output: nil,
            tool_choice: nil,
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

  use BeamWeaver.Provider.ChatModel, stream_source: :moonshot_chat_completions

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = ChatOptions.keyword_options(opts)

    opts =
      Compat.expand_base_url(opts,
        endpoint: "chat/completions",
        count_tokens_endpoint: "tokenizers/estimate-token-count"
      )

    model = Keyword.get(opts, :model, @default_model)
    profile = ChatOptions.profile_option(opts, :moonshot, model)

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
         {:ok, tools} <- render_tools(Keyword.get(opts, :tools, [])),
         body =
           body |> ChatCompletionsWire.put_stream_usage(model, opts) |> ProviderOptions.put_optional("tools", tools),
         :ok <- validate_dynamic_tools(body),
         :ok <- validate_required_tool_choice(body),
         :ok <- validate_web_search_thinking(body) do
      {:ok, body}
    end
  end

  @spec count_tokens(t(), term(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_tokens(%__MODULE__{} = model, input, opts \\ []) do
    with {:ok, messages} <- LanguageModel.normalize_chat_input(input),
         {:ok, body} <- token_count_body(model, messages, opts),
         {:ok, response} <- Client.estimate_token_count(client(model), body, opts) do
      token_count(response)
    end
  end

  @spec token_count_body(t(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def token_count_body(%__MODULE__{} = model, messages, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])

    with {:ok, moonshot_messages} <- Messages.to_chat_messages(messages),
         {:ok, tools} <- render_tools(tools) do
      {:ok,
       %{
         "model" => Keyword.get(opts, :model, model.model),
         "messages" => moonshot_messages
       }
       |> ProviderOptions.put_optional("tools", tools)
       |> ProviderOptions.put_optional(
         "thinking",
         ProviderOptions.normalize_value(Keyword.get(opts, :thinking, model.thinking))
       )}
    end
  end

  defp token_count(%{"data" => %{"total_tokens" => count}}) when is_integer(count),
    do: {:ok, count}

  defp token_count(%{"total_tokens" => count}) when is_integer(count), do: {:ok, count}

  defp token_count(response) do
    {:error,
     Error.new(:invalid_response, "Moonshot token-count response is invalid", %{
       response: inspect(response)
     })}
  end

  defp client(%__MODULE__{} = model) do
    %Client{
      endpoint: model.endpoint,
      chat_completions_endpoint: model.endpoint,
      count_tokens_endpoint: model.count_tokens_endpoint,
      api_key: model.api_key,
      default_headers: model.default_headers || [],
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    }
  end

  defp render_tools([]), do: {:ok, []}

  defp render_tools(tools) do
    with {:ok, rendered} <- Tools.render_chat_tools(tools),
         :ok <- Tools.validate_chat_tools(rendered),
         do: {:ok, rendered}
  end

  defp validate_web_search_thinking(%{"tools" => tools} = body) when is_list(tools) do
    if Enum.any?(tools, &Tools.web_search_tool?/1) and
         get_in(body, ["thinking", "type"]) != "disabled" do
      {:error,
       Error.new(:unsupported_feature, "Moonshot $web_search requires thinking to be disabled", %{
         provider: :moonshot,
         model: body["model"],
         feature: :web_search,
         required: %{thinking: %{type: "disabled"}}
       })}
    else
      :ok
    end
  end

  defp validate_web_search_thinking(_body), do: :ok

  defp validate_dynamic_tools(%{"messages" => messages, "model" => "kimi-k3"})
       when is_list(messages),
       do: :ok

  defp validate_dynamic_tools(%{"messages" => messages, "model" => model})
       when is_list(messages) do
    if Enum.any?(messages, &Map.has_key?(&1, "tools")) do
      {:error,
       Error.new(
         :unsupported_feature,
         "Moonshot dynamic tool messages require Kimi K3",
         %{
           provider: :moonshot,
           model: model,
           feature: :dynamic_tool_loading,
           supported: ["kimi-k3"]
         }
       )}
    else
      :ok
    end
  end

  defp validate_required_tool_choice(%{"tool_choice" => "required"} = body) do
    top_level_tools? = match?([_ | _], body["tools"])

    dynamic_tools? =
      Enum.any?(body["messages"] || [], fn message ->
        match?([_ | _], message["tools"])
      end)

    if top_level_tools? or dynamic_tools? do
      :ok
    else
      {:error,
       Error.new(:invalid_request, "Moonshot tool_choice required needs at least one tool", %{
         provider: :moonshot,
         model: body["model"],
         param: :tool_choice,
         value: "required"
       })}
    end
  end

  defp validate_required_tool_choice(_body), do: :ok

  @impl true
  def stream_metadata(%__MODULE__{} = model, body, opts) do
    model
    |> InvocationMetadata.provider(:moonshot, body, opts, :chat_completions)
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
  def parse_response(_model, message, opts),
    do: StructuredOutput.maybe_parse(message, opts, provider_name: "Moonshot")
end
