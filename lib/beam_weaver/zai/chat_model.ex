defmodule BeamWeaver.ZAI.ChatModel do
  @moduledoc """
  Z.ai GLM-5.2 Chat Completions chat model implementation.
  """

  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.StructuredOutput
  alias BeamWeaver.ZAI.Client
  alias BeamWeaver.ZAI.Error
  alias BeamWeaver.ZAI.Messages
  alias BeamWeaver.ZAI.Options
  alias BeamWeaver.ZAI.Tools

  @default_model "glm-5.2"
  @default_endpoint "https://api.z.ai/api/paas/v4/chat/completions"

  defstruct model: @default_model,
            endpoint: @default_endpoint,
            api_key: nil,
            default_headers: [],
            model_kwargs: %{},
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
            include_response_headers: true,
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
  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    builder_opts = Keyword.delete(opts, :tools)

    with {:ok, body} <- Options.to_body(model, messages, builder_opts),
         {:ok, body} <- maybe_put_stream_usage(body, model, opts) do
      maybe_put_tools(body, tools)
    end
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

  defp normalize_endpoint_opts(opts) do
    case {Keyword.fetch(opts, :base_url), Keyword.has_key?(opts, :endpoint)} do
      {{:ok, base_url}, false} ->
        opts
        |> Keyword.delete(:base_url)
        |> Keyword.put(:endpoint, Client.endpoint(base_url, "chat/completions"))

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

  defp model_stream_metadata(%__MODULE__{} = model, body, opts) do
    model
    |> InvocationMetadata.provider(:zai, body, opts, :chat_completions)
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
          provider_name: "Z.ai"
        )
      end,
      metadata: &model_stream_metadata/3,
      source: :zai_chat_completions
    }
  end
end
