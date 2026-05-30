defmodule BeamWeaver.Google.ChatModel do
  @moduledoc """
  Google Gemini Developer API chat model implementation.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Google.Client
  alias BeamWeaver.Google.Error, as: GoogleError
  alias BeamWeaver.Google.Messages
  alias BeamWeaver.Google.Tools
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.Options
  alias BeamWeaver.Provider.StructuredOutput

  @default_model "gemini-3.5-flash"

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct model: @default_model,
            base_url: nil,
            endpoint: nil,
            api_key: nil,
            default_headers: [],
            model_kwargs: %{},
            candidate_count: nil,
            temperature: nil,
            top_k: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            max_output_tokens: nil,
            stop_sequences: nil,
            logprobs: nil,
            response_logprobs: nil,
            response_mime_type: nil,
            response_schema: nil,
            response_json_schema: nil,
            response_format_config: nil,
            response_modalities: nil,
            media_resolution: nil,
            seed: nil,
            thinking_level: nil,
            thinking_budget: nil,
            include_thoughts: nil,
            safety_settings: nil,
            cached_content: nil,
            image_config: nil,
            speech_config: nil,
            labels: nil,
            generation_config: nil,
            tool_config: nil,
            include_server_side_tool_invocations: nil,
            retrieval_config: nil,
            service_tier: nil,
            store: nil,
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
    model = Keyword.get(opts, :model, @default_model)
    profile = ChatOptions.profile_option(opts, :google, model)

    struct!(
      __MODULE__,
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put_new(:api_key, Config.get([:google, :api_key]))
      |> Keyword.put_new(:base_url, Config.get([:google, :base_url]))
      |> Keyword.put(:profile, profile)
    )
  end

  @impl true
  def stream_events(%__MODULE__{} = model, messages, opts \\ []) do
    with {:ok, body} <- request_body(model, messages, Keyword.put(opts, :stream, true)) do
      Client.stream_events(client(model), model.model, body, opts)
    end
  end

  def count_tokens(%__MODULE__{} = model, input, opts \\ []) do
    with {:ok, messages} <- LanguageModel.normalize_chat_input(input),
         {:ok, body} <- count_tokens_body(model, messages, opts),
         {:ok, response} <- Client.count_tokens(client(model), model.model, body, opts) do
      {:ok, response["totalTokens"] || response["total_tokens"] || 0}
    end
  end

  @spec request_body(t(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    params = request_params(model, opts)

    with :ok <- ParamPolicy.validate(model.profile, params, param_policy(model), api: :generate_content),
         {:ok, {system, contents}} <- Messages.encode_messages(messages, opts),
         {:ok, tools} <- Tools.render_tools(option(model, opts, :tools), opts),
         {:ok, tool_config} <-
           Tools.render_tool_choice(
             option(model, opts, :tool_choice),
             option(model, opts, :tools) || [],
             opts
           ) do
      tool_config = tool_config(model, opts, tool_config)

      body =
        %{"contents" => contents}
        |> Options.put_optional("systemInstruction", system)
        |> Options.put_optional("generationConfig", generation_config(model, opts))
        |> Options.put_optional("tools", tools)
        |> Options.put_optional("toolConfig", tool_config)
        |> Options.put_optional("safetySettings", safety_settings(model, opts))
        |> Options.put_optional("cachedContent", option(model, opts, :cached_content))
        |> Options.put_optional("serviceTier", option(model, opts, :service_tier))
        |> Options.put_optional("store", option(model, opts, :store))
        |> Options.merge_extra_body(option(model, opts, :extra_body))
        |> Options.merge_extra_body(option(model, opts, :model_kwargs))

      {:ok, body}
    end
  end

  def count_tokens_body(%__MODULE__{} = model, messages, opts \\ []) do
    with {:ok, {system, contents}} <- Messages.encode_messages(messages, opts) do
      generate_content_request =
        %{"contents" => contents}
        |> Options.put_optional("generationConfig", generation_config(model, opts))

      {:ok,
       %{"contents" => contents}
       |> Options.put_optional("systemInstruction", system)
       |> Options.put_optional("generateContentRequest", generate_content_request)}
    end
  end

  defp generation_config(%__MODULE__{} = model, opts) do
    %{}
    |> Options.put_optional("candidateCount", option(model, opts, :candidate_count))
    |> Options.put_optional("temperature", option(model, opts, :temperature))
    |> Options.put_optional("topK", option(model, opts, :top_k))
    |> Options.put_optional("topP", option(model, opts, :top_p))
    |> Options.put_optional("frequencyPenalty", option(model, opts, :frequency_penalty))
    |> Options.put_optional("presencePenalty", option(model, opts, :presence_penalty))
    |> Options.put_optional("maxOutputTokens", max_output_tokens(model, opts))
    |> Options.put_optional("logprobs", option(model, opts, :logprobs))
    |> Options.put_optional("responseLogprobs", option(model, opts, :response_logprobs))
    |> Options.put_optional(
      "stopSequences",
      option(model, opts, :stop_sequences) || Keyword.get(opts, :stop)
    )
    |> Options.put_optional("responseMimeType", response_mime_type(model, opts))
    |> Options.put_optional("responseJsonSchema", response_json_schema(model, opts))
    |> Options.put_optional(
      "responseFormat",
      Options.normalize_option_map(option(model, opts, :response_format_config))
    )
    |> Options.put_optional("responseModalities", option(model, opts, :response_modalities))
    |> Options.put_optional("mediaResolution", option(model, opts, :media_resolution))
    |> Options.put_optional("seed", option(model, opts, :seed))
    |> Options.put_optional("thinkingConfig", thinking_config(model, opts))
    |> Options.put_optional(
      "imageConfig",
      Options.normalize_option_map(option(model, opts, :image_config))
    )
    |> Options.put_optional(
      "speechConfig",
      Options.normalize_option_map(option(model, opts, :speech_config))
    )
    |> Options.put_optional("labels", Options.normalize_option_map(option(model, opts, :labels)))
    |> Options.put_optional(
      "enableEnhancedCivicAnswers",
      option(model, opts, :enable_enhanced_civic_answers)
    )
    |> Options.merge_extra_body(option(model, opts, :generation_config))
    |> Options.empty_to_nil()
  end

  defp tool_config(model, opts, rendered_choice) do
    rendered_choice
    |> maybe_map()
    |> Options.merge_extra_body(option(model, opts, :tool_config))
    |> Options.put_optional(
      "includeServerSideToolInvocations",
      option(model, opts, :include_server_side_tool_invocations)
    )
    |> Options.put_optional(
      "retrievalConfig",
      Options.normalize_option_map(option(model, opts, :retrieval_config))
    )
    |> Options.empty_to_nil()
  end

  defp response_mime_type(model, opts) do
    option(model, opts, :response_mime_type) ||
      if(
        response_format(opts) != nil or option(model, opts, :response_schema) != nil or
          option(model, opts, :response_json_schema) != nil,
        do: "application/json"
      )
  end

  defp response_json_schema(model, opts) do
    schema =
      option(model, opts, :response_json_schema) ||
        option(model, opts, :response_schema) ||
        response_format_schema(response_format(opts))

    if is_map(schema), do: Options.stringify_keys(schema), else: schema
  end

  defp response_format(opts),
    do: Keyword.get(opts, :response_format) || Keyword.get(opts, :structured_output)

  defp max_output_tokens(model, opts) do
    option(model, opts, :max_output_tokens) ||
      if(structured_output_request?(model, opts), do: profile_max_output_tokens(model))
  end

  defp structured_output_request?(model, opts) do
    response_format(opts) != nil or option(model, opts, :response_schema) != nil or
      option(model, opts, :response_json_schema) != nil
  end

  defp profile_max_output_tokens(%{profile: %{max_output_tokens: value}}) when is_integer(value) and value > 0,
    do: value

  defp profile_max_output_tokens(_model), do: nil

  defp response_format_schema(%{"json_schema" => %{"schema" => schema}}), do: schema
  defp response_format_schema(%{json_schema: %{schema: schema}}), do: schema
  defp response_format_schema(%{"type" => "json_object"}), do: nil
  defp response_format_schema(%{type: :json_object}), do: nil
  defp response_format_schema(%{type: "json_object"}), do: nil
  defp response_format_schema(%{"schema" => schema}), do: schema
  defp response_format_schema(%{schema: schema}), do: schema
  defp response_format_schema(schema) when is_map(schema), do: schema
  defp response_format_schema(_format), do: nil

  defp thinking_config(model, opts) do
    %{}
    |> Options.put_optional("thinkingLevel", option(model, opts, :thinking_level))
    |> Options.put_optional("thinkingBudget", option(model, opts, :thinking_budget))
    |> Options.put_optional("includeThoughts", option(model, opts, :include_thoughts))
    |> Options.empty_to_nil()
  end

  defp safety_settings(model, opts) do
    case option(model, opts, :safety_settings) do
      settings when is_map(settings) ->
        Enum.map(settings, fn {category, threshold} ->
          %{"category" => to_string(category), "threshold" => to_string(threshold)}
        end)

      settings ->
        settings
    end
  end

  defp maybe_parse_structured_output(message, opts) do
    if response_format(opts) != nil do
      StructuredOutput.parse(message, StructuredOutput.parser(opts),
        error_module: GoogleError,
        provider_name: "Google",
        on_decode_error: :ok
      )
    else
      {:ok, message}
    end
  end

  defp request_params(model, opts) do
    model
    |> Map.from_struct()
    |> Map.take([
      :candidate_count,
      :temperature,
      :top_k,
      :top_p,
      :frequency_penalty,
      :presence_penalty,
      :max_output_tokens,
      :stop_sequences,
      :logprobs,
      :response_logprobs,
      :response_mime_type,
      :response_schema,
      :response_json_schema,
      :response_format_config,
      :response_modalities,
      :media_resolution,
      :seed,
      :thinking_level,
      :thinking_budget,
      :include_thoughts,
      :safety_settings,
      :cached_content,
      :image_config,
      :speech_config,
      :generation_config,
      :tool_config,
      :include_server_side_tool_invocations,
      :retrieval_config,
      :service_tier,
      :store
    ])
    |> Map.merge(Map.new(opts))
    |> Map.drop(internal_call_opts())
  end

  defp internal_call_opts do
    [
      :metadata
    ]
  end

  defp client(%__MODULE__{} = model) do
    Client.new(
      base_url: model.base_url || model.endpoint,
      api_key: model.api_key,
      default_headers: model.default_headers || [],
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    )
  end

  defp option(model, opts, key), do: Keyword.get(opts, key, Map.get(model, key))

  defp maybe_map(nil), do: %{}
  defp maybe_map(map) when is_map(map), do: map

  defp param_policy(%__MODULE__{} = model),
    do: model.param_policy || ParamPolicy.default_for(model.profile)

  defp runtime_adapter do
    %ChatRuntime.Adapter{
      request: &request_body/3,
      invoke: fn model, body, opts ->
        Client.generate_content(client(model), model.model, body, opts)
      end,
      stream: fn model, body, opts ->
        Client.stream_text(client(model), model.model, body, opts)
      end,
      stream_response: fn model, body, opts ->
        Client.stream_response(client(model), model.model, body, opts)
      end,
      decode: fn response, opts -> Messages.response_to_message(response, opts) end,
      parse: &maybe_parse_structured_output/2
    }
  end
end
