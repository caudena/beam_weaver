defmodule BeamWeaver.Moonshot.ChatModel do
  @moduledoc """
  Moonshot/Kimi Chat Completions chat model implementation.
  """

  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Moonshot.Client
  alias BeamWeaver.Moonshot.Error
  alias BeamWeaver.Moonshot.Messages
  alias BeamWeaver.Moonshot.Options
  alias BeamWeaver.Moonshot.Tools
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
            model_kwargs: %{},
            temperature: nil,
            max_tokens: nil,
            max_completion_tokens: nil,
            max_output_tokens: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            n: nil,
            prompt_cache_key: nil,
            safety_identifier: nil,
            thinking: nil,
            response_format: nil,
            structured_output: nil,
            tool_choice: nil,
            stream_usage: true,
            profile: nil,
            tokenizer: nil,
            param_policy: nil,
            include_response_headers: false,
            transport: nil,
            transport_opts: [],
            timeout: 15_000

  @type t :: %__MODULE__{}

  use BeamWeaver.Provider.ChatModel

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = ChatOptions.keyword_options(opts)
    opts = normalize_endpoint_opts(opts)
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
  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    builder_opts = Keyword.delete(opts, :tools)

    with {:ok, body} <- Options.to_body(model, messages, builder_opts),
         {:ok, body} <- maybe_put_stream_usage(body, model, opts),
         {:ok, body} <- maybe_put_tools(body, tools),
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

  defp normalize_endpoint_opts(opts) do
    case {Keyword.fetch(opts, :base_url), Keyword.has_key?(opts, :endpoint)} do
      {{:ok, base_url}, false} ->
        opts
        |> Keyword.delete(:base_url)
        |> Keyword.put(:endpoint, Client.endpoint(base_url, "chat/completions"))
        |> Keyword.put_new(
          :count_tokens_endpoint,
          Client.endpoint(base_url, "tokenizers/estimate-token-count")
        )

      {{:ok, _base_url}, true} ->
        Keyword.delete(opts, :base_url)

      _other ->
        opts
    end
  end

  defp maybe_put_tools(body, []), do: {:ok, body}

  defp maybe_put_tools(body, tools) when is_list(tools) do
    with {:ok, tools} <- render_tools(tools) do
      {:ok, Map.put(body, "tools", tools)}
    end
  end

  defp render_tools([]), do: {:ok, []}

  defp render_tools(tools) do
    rendered = Tools.to_chat_tools(tools)

    case Tools.validate_chat_tools(rendered) do
      :ok -> {:ok, rendered}
      {:error, _error} = error -> error
    end
  end

  defp maybe_put_stream_usage(body, model, opts) do
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

  defp model_stream_metadata(%__MODULE__{} = model, body, opts) do
    model
    |> InvocationMetadata.provider(:moonshot, body, opts, :chat_completions)
    |> InvocationMetadata.to_metadata_map()
  end

  defp runtime_adapter do
    %ChatRuntime.Adapter{
      request: &request_body/3,
      invoke: fn model, body, opts -> Client.chat_completions(client(model), body, opts) end,
      stream: fn model, body, opts ->
        Client.chat_completions_stream(client(model), body, opts)
      end,
      stream_response: fn model, body, opts ->
        Client.chat_completions_stream_response(client(model), body, opts)
      end,
      stream_events: fn model, body, opts ->
        Client.chat_completions_stream_typed_events(client(model), body, opts)
      end,
      decode: fn
        %BeamWeaver.Core.Message{} = message, _opts -> {:ok, message}
        response, _opts -> Messages.chat_response_to_message(response)
      end,
      parse: fn message, opts ->
        StructuredOutput.maybe_parse(message, opts,
          error_module: Error,
          provider_name: "Moonshot"
        )
      end,
      metadata: &model_stream_metadata/3,
      source: :moonshot_chat_completions
    }
  end
end
