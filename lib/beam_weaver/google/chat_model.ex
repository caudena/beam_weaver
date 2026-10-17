defmodule BeamWeaver.Google.ChatModel do
  @moduledoc """
  Google Gemini Developer API chat model implementation.
  """

  use BeamWeaver.Provider.RedactedInspect

  import BeamWeaver.Provider.Options, only: [option: 3]

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Google.Client
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
            extra_body: %{},
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

  @impl true
  def stream_typed_events(%__MODULE__{} = model, messages, opts \\ []) do
    stream_events(model, messages, opts)
  end

  @impl true
  def stream_exact_typed_events(%__MODULE__{} = model, body, opts \\ []) when is_binary(body) do
    Client.stream_events(client(model), model.model, body, opts)
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
  @impl true
  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    params = request_params(model, opts)
    policy = model.param_policy || ParamPolicy.default_for(model.profile)
    requested_tools = option(model, opts, :tools) || []
    requested_tool_choice = option(model, opts, :tool_choice)

    with :ok <- ParamPolicy.validate(model.profile, params, policy, api: :generate_content),
         :ok <- validate_thinking_level(model, opts),
         :ok <- validate_builtin_tools(model, requested_tools),
         {:ok, {system, contents}} <- Messages.encode_messages(messages, opts),
         :ok <- validate_final_turn(model, contents),
         {:ok, tools} <- Tools.render_tools(requested_tools, opts),
         {:ok, tool_config} <-
           Tools.render_tool_choice(
             effective_tool_choice(opts, requested_tools, requested_tool_choice),
             requested_tools,
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
        |> Options.merge_extra_body(Options.extra_body(model, opts))

      {:ok, body}
    end
  end

  def count_tokens_body(%__MODULE__{} = model, messages, opts \\ []) do
    with {:ok, {system, contents}} <- Messages.encode_messages(messages, opts) do
      request =
        %{"contents" => contents}
        |> Options.put_optional("systemInstruction", Options.empty_to_nil(system))
        |> Options.put_optional("generationConfig", Options.empty_to_nil(generation_config(model, opts)))

      body =
        if map_size(request) > 1 do
          %{"generateContentRequest" => request}
        else
          request
        end

      {:ok, body}
    end
  end

  # Profiles list the thinking levels a model takes and the built-in tools it
  # lacks; both are checked before the request.
  defp validate_thinking_level(%__MODULE__{} = model, opts) do
    levels = profile_extra(model, :thinking_levels)
    level = option(model, opts, :thinking_level)

    if is_nil(level) or not is_list(levels) or to_string(level) in Enum.map(levels, &to_string/1) do
      :ok
    else
      {:error,
       Error.new(:unsupported_model_param, "#{model.model} does not take thinking level #{level}", %{
         provider: :google,
         model: model.model,
         params: [:thinking_level],
         value: level,
         supported: levels
       })}
    end
  end

  defp validate_builtin_tools(%__MODULE__{} = model, tools) do
    unsupported = profile_extra(model, :unsupported_tools) || []

    case tools |> List.wrap() |> Tools.builtin_tool_kinds() |> Enum.filter(&(&1 in unsupported)) do
      [] ->
        :ok

      kinds ->
        {:error,
         Error.new(:unsupported_feature, "#{model.model} does not take the #{Enum.join(kinds, ", ")} tool", %{
           provider: :google,
           model: model.model,
           feature: :tools,
           unsupported_tools: kinds
         })}
    end
  end

  defp profile_extra(%{profile: %{extra: extra}}, key) when is_map(extra), do: Map.get(extra, key)
  defp profile_extra(_model, _key), do: nil

  defp validate_final_turn(%__MODULE__{} = model, contents) do
    if rejects_prefilled_model_turns?(model) and last_non_empty_role(contents) == "model" do
      {:error,
       Error.new(
         :invalid_message,
         "Google model requests cannot end with a non-empty model turn",
         %{
           provider: :google,
           model: model.model,
           role: :model,
           requirement: :final_user_or_tool_turn
         }
       )}
    else
      :ok
    end
  end

  defp rejects_prefilled_model_turns?(%{profile: %{extra: extra}}) when is_map(extra) do
    Map.get(extra, :prefilled_model_turns, Map.get(extra, "prefilled_model_turns")) == false
  end

  defp rejects_prefilled_model_turns?(_model), do: false

  defp last_non_empty_role(contents) do
    contents
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => role, "parts" => [_part | _rest]} -> role
      _content -> nil
    end)
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

  defp effective_tool_choice(opts, tools, nil) do
    cond do
      Keyword.has_key?(opts, :tool_choice) or List.wrap(tools) == [] -> nil
      Tools.mixed_execution?(tools) -> :validated
      true -> :auto
    end
  end

  defp effective_tool_choice(_opts, _tools, choice), do: choice

  defp tool_config(model, opts, rendered_choice) do
    (rendered_choice || %{})
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
      if(structured_output_request?(model, opts), do: "application/json")
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

  # A call's `max_tokens` or `max_completion_tokens` is the same cap.
  defp max_output_tokens(model, opts) do
    Keyword.get(opts, :max_output_tokens) || Keyword.get(opts, :max_tokens) ||
      Keyword.get(opts, :max_completion_tokens) || model.max_output_tokens ||
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
    |> Map.delete(:metadata)
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

  @impl true
  def send_request(:invoke, model, body, opts), do: Client.generate_content(client(model), model.model, body, opts)
  def send_request(:stream, model, body, opts), do: Client.stream_text(client(model), model.model, body, opts)

  def send_request(:stream_response, model, body, opts),
    do: Client.stream_response(client(model), model.model, body, opts)

  @impl true
  def decode_response(response, opts), do: Messages.response_to_message(response, opts)

  @impl true
  def parse_response(_model, message, opts) do
    if response_format(opts) != nil,
      do: StructuredOutput.parse(message, StructuredOutput.parser(opts), provider_name: "Google", on_decode_error: :ok),
      else: {:ok, message}
  end
end
