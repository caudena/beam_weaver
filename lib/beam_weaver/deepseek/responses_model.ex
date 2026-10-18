defmodule BeamWeaver.DeepSeek.ResponsesModel do
  @moduledoc """
  DeepSeek OpenAI-compatible Responses API model.

  DeepSeek exposes this API for `deepseek-flash`, its compatibility aliases,
  and `deepseek-v4-pro`, and keeps it stateless. Unsupported state, media, and silently ignored
  compatibility parameters are rejected before transport.
  """

  use BeamWeaver.Provider.RedactedInspect

  alias BeamWeaver.DeepSeek.Client
  alias BeamWeaver.Core.Error
  alias BeamWeaver.DeepSeek.Messages
  alias BeamWeaver.DeepSeek.Tools
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.OpenAI.ChatModel.RequestBuilder
  alias BeamWeaver.OpenAI.ChatModel.TokenCounter
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Provider.StructuredOutput

  @default_model "deepseek-flash"
  @default_base_url "https://api.deepseek.com"
  @default_endpoint @default_base_url <> "/responses"
  @max_output_tokens 393_216
  @reasoning_efforts ~w(none minimal low medium high xhigh max ultra)
  @supported_models BeamWeaver.Models.ProfileRegistry.DeepSeek.supported_models()

  @unsupported_params ~w(
    audio
    background
    context_management
    conversation
    frequency_penalty
    include
    max_tool_calls
    metadata
    modalities
    parallel_tool_calls
    presence_penalty
    previous_response_id
    prompt
    prompt_cache_key
    prompt_cache_options
    prompt_cache_retention
    safety_identifier
    seed
    service_tier
    store
    stream_options
    truncation
    use_previous_response_id
  )

  @allowed_input_types ~w(
    message
    function_call
    function_call_output
    reasoning
    web_search_call
    custom_tool_call
    custom_tool_call_output
  )

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct model: @default_model,
            base_url: @default_base_url,
            endpoint: @default_endpoint,
            api_key: nil,
            default_headers: [],
            extra_body: %{},
            reasoning: nil,
            reasoning_effort: nil,
            verbosity: nil,
            temperature: nil,
            max_tokens: nil,
            max_completion_tokens: nil,
            max_output_tokens: nil,
            top_p: nil,
            top_logprobs: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            seed: nil,
            parallel_tool_calls: nil,
            metadata: nil,
            user: nil,
            service_tier: nil,
            prompt_cache_key: nil,
            prompt_cache_options: nil,
            prompt_cache_retention: nil,
            safety_identifier: nil,
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

  @type t :: %__MODULE__{}

  use BeamWeaver.Provider.ChatModel, stream_source: :deepseek_responses

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []), do: BeamWeaver.DeepSeek.ChatModel.build(__MODULE__, opts, &normalize_endpoint_opts/1)

  @spec request_body(t(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  @impl true
  def request_body(%__MODULE__{} = model, messages, opts \\ []) do
    with :ok <- validate_responses_model(model.model),
         :ok <- validate_container_options(model, opts),
         :ok <- validate_model_overrides(model, opts),
         :ok <- validate_unsupported_options(model, opts),
         {:ok, opts} <- render_tools(opts),
         {:ok, body} <- RequestBuilder.request_body(model, messages, opts),
         body = Map.put(body, "stream", Keyword.get(opts, :stream, false)),
         :ok <- Messages.validate_messages(messages, :responses, body["model"]),
         :ok <- reject_unsupported(body, &Map.has_key?/2),
         :ok <- validate_instructions(body),
         :ok <- validate_required_input(body),
         :ok <- validate_tools(body["tools"]),
         :ok <- validate_input_items(body["input"], body["tools"]),
         :ok <- BeamWeaver.DeepSeek.Vision.validate_request(body, :responses),
         :ok <- validate_call_pairs(body["input"]),
         :ok <- validate_request_values(body),
         :ok <- validate_tool_choice(body["tool_choice"], body["tools"], body["reasoning"]) do
      {:ok, body}
    end
  end

  def count_tokens(%__MODULE__{} = model, input, opts \\ []),
    do: TokenCounter.count(model, input, opts)

  defp render_tools(opts) do
    {:ok, Keyword.update(opts, :tools, [], &Tools.to_responses_tools/1)}
  rescue
    error in ArgumentError -> error(:invalid_request, error.message)
  end

  defp error(type, message, details \\ []),
    do: {:error, Error.new(type, message, Enum.into(details, %{provider: :deepseek, api: :responses}))}

  defp validate_responses_model(model) when model in @supported_models, do: :ok

  defp validate_responses_model(model) do
    error(:unsupported_model, "DeepSeek Responses model is not supported",
      model: model,
      supported: @supported_models,
      expected: "deepseek:deepseek-flash"
    )
  end

  defp validate_container_options(model, opts) do
    with :ok <- validate_optional_map(model.extra_body, :extra_body),
         :ok <- validate_optional_map(Keyword.get(opts, :extra_body), :extra_body),
         :ok <- validate_optional_map(Keyword.get(opts, :reasoning, model.reasoning), :reasoning),
         :ok <- validate_optional_map(Keyword.get(opts, :text), :text),
         :ok <- validate_list(Keyword.get(opts, :tools, []), :tools),
         do: validate_optional_map(ProviderOptions.extra_body(model, opts)["text"], :text)
  end

  defp validate_optional_map(nil, _param), do: :ok
  defp validate_optional_map(value, _param) when is_map(value), do: :ok
  defp validate_optional_map(value, param), do: container_error(param, value, "a map")

  defp validate_list(value, _param) when is_list(value), do: :ok
  defp validate_list(value, param), do: container_error(param, value, "a list")

  defp container_error(param, value, expected),
    do: error(:invalid_request, "DeepSeek Responses #{param} must be #{expected}", param: param, value: inspect(value))

  defp validate_model_overrides(model, opts) do
    [Map.fetch(ProviderOptions.extra_body(model, opts), "model"), Keyword.fetch(opts, :model)]
    |> Enum.find_value(:ok, fn
      {:ok, override} -> with :ok <- validate_responses_model(override), do: nil
      :error -> nil
    end)
  end

  defp validate_unsupported_options(model, opts) do
    with :ok <- model |> Map.from_struct() |> BeamWeaver.MapShape.stringify_keys() |> reject_unsupported(&configured?/2),
         :ok <- opts |> Map.new() |> BeamWeaver.MapShape.stringify_keys() |> reject_unsupported(&Map.has_key?/2),
         do: reject_unsupported(ProviderOptions.extra_body(model, opts), &Map.has_key?/2)
  end

  # A model created with an option every call refuses, such as `metadata:`,
  # fails when it is created, with the error its calls return.
  @doc false
  @spec validate_options(keyword()) :: :ok | {:error, Error.t()}
  def validate_options(opts),
    do: opts |> Map.new() |> BeamWeaver.MapShape.stringify_keys() |> reject_unsupported(&configured?/2)

  defp configured?(values, key), do: Map.get(values, key) != nil

  defp reject_unsupported(values, present?) do
    case Enum.filter(@unsupported_params, &present?.(values, &1)) do
      [] ->
        :ok

      keys ->
        error(:unsupported_model_param, "DeepSeek Responses parameter is not supported",
          params: Enum.map(keys, &String.to_atom/1),
          stateless: true
        )
    end
  end

  defp validate_instructions(%{"instructions" => instructions}) when is_binary(instructions) and instructions != "",
    do: :ok

  defp validate_instructions(%{"instructions" => instructions}) do
    error(:invalid_request, "DeepSeek Responses instructions must be a nonempty string",
      param: :instructions,
      value: inspect(instructions)
    )
  end

  defp validate_instructions(_body), do: :ok

  defp validate_required_input(%{"input" => [_item | _rest]}), do: :ok

  defp validate_required_input(%{"instructions" => instructions})
       when is_binary(instructions) and instructions != "",
       do: :ok

  defp validate_required_input(_body) do
    error(:invalid_request, "DeepSeek Responses requires nonempty input or instructions",
      required: [:input, :instructions]
    )
  end

  defp validate_input_items(items, tools) when is_list(items),
    do: Enum.find_value(items, :ok, fn item -> with :ok <- validate_input_item(item, tools || []), do: nil end)

  defp validate_input_items(_items, _tools) do
    {:error, Error.new(:invalid_request, "DeepSeek Responses input must be a list")}
  end

  defp validate_input_item(%{"type" => "message", "content" => content}, _tools)
       when is_list(content) do
    Enum.find_value(content, :ok, fn part ->
      case is_map(part) && part["type"] do
        type when type in ["input_text", "output_text", "text"] ->
          if !is_binary(part["text"]), do: unsupported_input(type)

        "input_image" ->
          nil

        type ->
          unsupported_input(type)
      end
    end)
  end

  defp validate_input_item(%{"type" => "message", "content" => content}, _tools)
       when is_binary(content),
       do: :ok

  defp validate_input_item(%{"type" => "message"}, _tools),
    do: unsupported_input(:message_content)

  defp validate_input_item(%{"type" => "reasoning"} = item, _tools) do
    # Current Responses output includes an opaque encrypted_content handle,
    # sometimes alongside plain reasoning. Replay both exactly as returned.
    cond do
      item["summary"] not in [nil, false, [], %{}] ->
        unsupported_input(:reasoning_summary)

      not is_nil(item["encrypted_content"]) and not is_binary(item["encrypted_content"]) ->
        required_string_field_error("encrypted_content", item["encrypted_content"], "reasoning", "a string")

      is_list(item["content"]) ->
        if Enum.all?(item["content"], &match?(%{"type" => "reasoning_text", "text" => text} when is_binary(text), &1)),
          do: :ok,
          else: unsupported_input(:reasoning_content)

      is_nil(item["content"]) ->
        :ok

      true ->
        unsupported_input(:reasoning_content)
    end
  end

  defp validate_input_item(%{"type" => "function_call"} = item, _tools) do
    with :ok <- validate_call_id(item, "function_call"),
         :ok <- validate_nonempty_string_field(item, "name", "function_call"),
         do: validate_nonempty_string_field(item, "arguments", "function_call")
  end

  defp validate_input_item(%{"type" => "function_call_output"} = item, _tools) do
    with :ok <- validate_call_id(item, "function_call_output"),
         do: validate_tool_output(item, "function_call_output")
  end

  defp validate_input_item(%{"type" => "custom_tool_call", "name" => "apply_patch"} = item, tools) do
    with :ok <- validate_call_id(item, "custom_tool_call"),
         :ok <- validate_nonempty_string_field(item, "input", "custom_tool_call"),
         do: require_apply_patch(tools)
  end

  defp validate_input_item(%{"type" => "custom_tool_call"} = item, _tools) do
    error(:unsupported_feature, "DeepSeek custom input supports apply_patch only",
      feature: :custom_tool_call,
      name: item["name"]
    )
  end

  defp validate_input_item(%{"type" => "custom_tool_call_output"} = item, tools) do
    with :ok <- validate_call_id(item, "custom_tool_call_output"),
         :ok <- validate_tool_output(item, "custom_tool_call_output"),
         do: require_apply_patch(tools)
  end

  defp validate_input_item(%{"type" => type}, _tools) when is_binary(type) and byte_size(type) > 0, do: :ok
  defp validate_input_item(_item, _tools), do: unsupported_input(nil)

  defp require_apply_patch(tools) do
    if apply_patch_declared?(tools),
      do: :ok,
      else: error(:invalid_request, "DeepSeek custom tool replay requires the apply_patch tool", feature: :apply_patch)
  end

  defp validate_call_id(item, type) do
    case item["call_id"] do
      call_id when is_binary(call_id) and call_id != "" ->
        :ok

      call_id ->
        error(:invalid_request, "DeepSeek Responses call_id must be a nonempty string",
          input_type: type,
          call_id: call_id
        )
    end
  end

  defp validate_nonempty_string_field(item, field, type) do
    case Map.get(item, field) do
      value when is_binary(value) and value != "" -> :ok
      value -> required_string_field_error(field, value, type, "a nonempty string")
    end
  end

  defp validate_tool_output(%{"output" => parts}, _type) when is_list(parts),
    do: validate_input_item(%{"type" => "message", "content" => parts}, [])

  defp validate_tool_output(item, type) do
    case Map.get(item, "output") do
      value when is_binary(value) -> :ok
      value -> required_string_field_error("output", value, type, "a string")
    end
  end

  defp required_string_field_error(field, value, type, expected) do
    error(:invalid_request, "DeepSeek Responses #{type} #{field} must be #{expected}",
      input_type: type,
      param: String.to_atom(field),
      value: value
    )
  end

  defp unsupported_input(type) do
    error(:unsupported_feature, "DeepSeek Responses input item is not supported",
      feature: input_feature(type),
      input_type: type,
      supported: @allowed_input_types
    )
  end

  defp input_feature(type) when type in ["input_image", "image", "image_url"], do: :image
  defp input_feature(type) when type in ["input_file", "file"], do: :file
  defp input_feature(type) when type in ["input_audio", "audio"], do: :audio
  defp input_feature(type), do: type

  defp validate_tools(nil), do: :ok
  defp validate_tools(tools) when is_list(tools), do: Tools.validate_responses_tools(tools)

  defp validate_tools(_tools) do
    {:error, Error.new(:invalid_request, "DeepSeek Responses tools must be a list")}
  end

  defp validate_call_pairs(items) do
    with :ok <- validate_pair_type(items, "function_call", "function_call_output"),
         do: validate_pair_type(items, "custom_tool_call", "custom_tool_call_output")
  end

  defp validate_pair_type(items, call_type, output_type) do
    calls = call_ids(items, call_type)
    outputs = call_ids(items, output_type)

    cond do
      length(calls) != length(Enum.uniq(calls)) ->
        duplicate_call_id_error(call_type, calls)

      length(outputs) != length(Enum.uniq(outputs)) ->
        duplicate_call_id_error(output_type, outputs)

      Enum.sort(calls) != Enum.sort(outputs) ->
        error(:invalid_request, "DeepSeek Responses requires exactly one output for every #{call_type}",
          call_type: call_type,
          output_type: output_type,
          calls: calls,
          outputs: outputs
        )

      true ->
        :ok
    end
  end

  defp call_ids(items, type) do
    for %{"type" => ^type, "call_id" => call_id} <- items, do: call_id
  end

  defp duplicate_call_id_error(type, ids) do
    error(:invalid_request, "DeepSeek Responses call_id values must be unique per item type",
      input_type: type,
      call_ids: Enum.uniq(ids -- Enum.uniq(ids))
    )
  end

  defp validate_request_values(body) do
    with :ok <- validate_integer_range(body["max_output_tokens"], :max_output_tokens, 1, @max_output_tokens),
         :ok <- validate_number_range(body["temperature"], :temperature, 0, 2),
         :ok <- validate_number_range(body["top_p"], :top_p, 0, 1),
         :ok <- validate_integer_range(body["top_logprobs"], :top_logprobs, 0, 20),
         :ok <- validate_boolean(body["stream"], :stream),
         :ok <- validate_optional_map(body["text"], :text),
         :ok <- validate_reasoning(body["reasoning"]),
         do: validate_user(body["user"])
  end

  defp validate_boolean(value, _param) when is_boolean(value), do: :ok

  defp validate_boolean(value, param),
    do: error(:invalid_request, "DeepSeek Responses #{param} must be a boolean", param: param, value: value)

  defp validate_reasoning(nil), do: :ok

  defp validate_reasoning(%{} = reasoning) do
    case reasoning["effort"] do
      effort when is_nil(effort) or effort in @reasoning_efforts ->
        :ok

      effort ->
        error(:invalid_request, "DeepSeek Responses reasoning effort is not supported",
          param: :reasoning,
          effort: effort,
          supported: @reasoning_efforts
        )
    end
  end

  defp validate_reasoning(value), do: container_error(:reasoning, value, "a map")

  defp validate_integer_range(nil, _param, _min, _max), do: :ok

  defp validate_integer_range(value, _param, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: :ok

  defp validate_integer_range(value, param, min, max),
    do: range_error(param, value, "an integer", min, max)

  defp validate_number_range(nil, _param, _min, _max), do: :ok

  defp validate_number_range(value, _param, min, max)
       when is_number(value) and value >= min and value <= max,
       do: :ok

  defp validate_number_range(value, param, min, max),
    do: range_error(param, value, "a number", min, max)

  defp range_error(param, value, type, min, max) do
    error(:invalid_request, "DeepSeek Responses #{param} must be #{type} from #{min} to #{max}",
      param: param,
      value: value,
      min: min,
      max: max
    )
  end

  defp validate_user(nil), do: :ok

  defp validate_user(user) do
    if is_binary(user) and byte_size(user) <= 512 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, user) do
      :ok
    else
      error(:invalid_request, "DeepSeek Responses user must match [A-Za-z0-9_-]+ and be at most 512 bytes",
        param: :user,
        value: inspect(user)
      )
    end
  end

  defp validate_tool_choice(nil, _tools, _reasoning), do: :ok
  defp validate_tool_choice(choice, _tools, _reasoning) when choice in ["none", "auto"], do: :ok
  defp validate_tool_choice("required", [_tool | _rest], _reasoning), do: :ok

  defp validate_tool_choice("required", _tools, _reasoning) do
    tool_choice_error("required", "requires at least one declared tool")
  end

  defp validate_tool_choice(%{"type" => "function", "name" => name} = choice, tools, reasoning)
       when is_binary(name) do
    with :ok <- validate_forced_tool_reasoning(choice, reasoning) do
      if declared_function?(tools, name), do: :ok, else: undeclared_tool_choice(choice, name)
    end
  end

  defp validate_tool_choice(%{"type" => type} = choice, tools, _reasoning)
       when type in ["web_search", "web_search_2025_08_26"] do
    if declared_web_search?(tools), do: :ok, else: undeclared_tool_choice(choice, type)
  end

  defp validate_tool_choice(%{"type" => "custom", "name" => "apply_patch"} = choice, tools, reasoning) do
    with :ok <- validate_forced_tool_reasoning(choice, reasoning) do
      if apply_patch_declared?(tools), do: :ok, else: undeclared_tool_choice(choice, "apply_patch")
    end
  end

  defp validate_tool_choice(choice, _tools, _reasoning) do
    tool_choice_error(choice, "is not supported")
  end

  defp validate_forced_tool_reasoning(_choice, %{"effort" => "none"}), do: :ok

  defp validate_forced_tool_reasoning(choice, reasoning) do
    error(
      :unsupported_model_param,
      "DeepSeek Responses forced function and custom tool choices require reasoning effort none",
      param: :tool_choice,
      value: choice,
      reasoning: reasoning,
      required: %{reasoning: %{effort: "none"}}
    )
  end

  defp declared_function?(tools, name),
    do: Enum.any?(tools || [], &match?(%{"type" => "function", "name" => ^name}, &1))

  defp declared_web_search?(tools),
    do: Enum.any?(tools || [], &match?(%{"type" => type} when type in ["web_search", "web_search_2025_08_26"], &1))

  defp apply_patch_declared?(tools),
    do: Enum.any?(tools || [], &match?(%{"type" => "custom", "name" => "apply_patch"}, &1))

  defp undeclared_tool_choice(choice, name) do
    error(:invalid_request, "DeepSeek Responses tool_choice must reference a declared tool",
      param: :tool_choice,
      value: choice,
      name: name
    )
  end

  defp tool_choice_error(choice, reason) do
    error(:unsupported_model_param, "DeepSeek Responses tool_choice #{reason}",
      param: :tool_choice,
      value: choice,
      supported: ["none", "auto", "required", :named_function, :web_search, :apply_patch]
    )
  end

  defp normalize_endpoint_opts(opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url) || @default_base_url
    client = Client.new(base_url: base_url)

    opts
    |> Keyword.put(:base_url, base_url)
    |> Keyword.put_new(:endpoint, client.responses_endpoint)
  end

  defp client(%__MODULE__{} = model) do
    Client.new(
      base_url: model.base_url,
      responses_endpoint: model.endpoint,
      api_key: model.api_key,
      default_headers: model.default_headers || [],
      transport: model.transport,
      transport_opts: model.transport_opts,
      timeout: model.timeout
    )
  end

  @impl true
  def stream_metadata(%__MODULE__{} = model, body, opts) do
    model
    |> InvocationMetadata.provider(:deepseek, body, opts, :responses)
    |> InvocationMetadata.to_metadata_map()
  end

  @impl true
  def send_request(:invoke, model, body, opts), do: Client.responses(client(model), body, opts)
  def send_request(:stream, model, body, opts), do: Client.responses_stream(client(model), body, opts)
  def send_request(:stream_response, model, body, opts), do: Client.responses_stream_response(client(model), body, opts)

  def send_request(:stream_events, model, body, opts),
    do: Client.responses_stream_typed_events(client(model), body, opts)

  @impl true
  def decode_response(response, _opts), do: Messages.responses_to_message(response)

  @impl true
  def parse_response(_model, message, opts),
    do: StructuredOutput.maybe_parse(message, opts, provider_name: "DeepSeek")
end
