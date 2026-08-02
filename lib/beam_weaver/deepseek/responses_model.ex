defmodule BeamWeaver.DeepSeek.ResponsesModel do
  @moduledoc """
  DeepSeek OpenAI-compatible Responses API model.

  DeepSeek currently exposes this API for `deepseek-v4-flash` only and keeps it
  stateless. Unsupported state, media, and silently ignored compatibility
  parameters are rejected before transport.
  """

  alias BeamWeaver.DeepSeek.Client
  alias BeamWeaver.DeepSeek.Error
  alias BeamWeaver.DeepSeek.Messages
  alias BeamWeaver.DeepSeek.Tools
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.OpenAI.ChatModel.RequestBuilder
  alias BeamWeaver.OpenAI.ChatModel.TokenCounter
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.StructuredOutput

  @default_model "deepseek-v4-flash"
  @default_base_url "https://api.deepseek.com"
  @default_endpoint @default_base_url <> "/responses"
  @max_output_tokens 393_216
  @reasoning_efforts ~w(none low medium high xhigh max)

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
            model_kwargs: %{},
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

  use BeamWeaver.Provider.ChatModel

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = ChatOptions.keyword_options(opts)
    opts = normalize_endpoint_opts(opts)
    model = Keyword.get(opts, :model, @default_model)
    profile = ChatOptions.profile_option(opts, :deepseek, model)

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
    with :ok <- validate_responses_model(model.model),
         :ok <- validate_container_options(model, opts),
         :ok <- validate_model_overrides(model, opts),
         :ok <- validate_unsupported_options(model, opts),
         :ok <- Messages.validate_text_messages(messages, :responses),
         {:ok, body} <- model |> RequestBuilder.request_body(messages, opts) |> convert_error(),
         body <- restore_reserved_fields(body, model, opts),
         :ok <- validate_responses_model(body["model"]),
         :ok <- validate_unsupported_body(body),
         :ok <- validate_instructions(body),
         :ok <- validate_required_input(body),
         :ok <- validate_tools(body["tools"]),
         :ok <- validate_input_items(body["input"], body["tools"]),
         :ok <- validate_call_pairs(body["input"]),
         :ok <- validate_request_values(body),
         :ok <- validate_tool_choice(body["tool_choice"], body["tools"], body["reasoning"]) do
      {:ok, body}
    end
  end

  def count_tokens(%__MODULE__{} = model, input, opts \\ []),
    do: TokenCounter.count(model, input, opts)

  defp validate_responses_model("deepseek-v4-flash"), do: :ok

  defp validate_responses_model(model) do
    {:error,
     Error.new(:unsupported_model, "DeepSeek Responses currently supports V4 Flash only", %{
       provider: :deepseek,
       api: :responses,
       model: model,
       supported: ["deepseek-v4-flash"],
       expected: "deepseek:deepseek-v4-flash"
     })}
  end

  defp validate_container_options(model, opts) do
    model_kwargs = Keyword.get(opts, :model_kwargs, model.model_kwargs)

    with :ok <- validate_optional_map(model_kwargs, :model_kwargs),
         :ok <- validate_optional_map(Keyword.get(opts, :extra_body), :extra_body),
         :ok <- validate_optional_map(Keyword.get(opts, :reasoning, model.reasoning), :reasoning),
         :ok <- validate_optional_map(Keyword.get(opts, :text), :text),
         :ok <- validate_list(Keyword.get(opts, :tools, []), :tools),
         :ok <- validate_nested_optional_map(model_kwargs, "text", :text) do
      :ok
    end
  end

  defp validate_optional_map(nil, _param), do: :ok
  defp validate_optional_map(value, _param) when is_map(value), do: :ok

  defp validate_optional_map(value, param),
    do: container_error(param, value, "a map")

  defp validate_list(value, _param) when is_list(value), do: :ok
  defp validate_list(value, param), do: container_error(param, value, "a list")

  defp validate_nested_optional_map(nil, _key, _param), do: :ok

  defp validate_nested_optional_map(map, key, param) when is_map(map) do
    map = BeamWeaver.MapShape.stringify_keys(map)

    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, value} when is_map(value) -> :ok
      {:ok, value} -> container_error(param, value, "a map")
    end
  end

  defp container_error(param, value, expected) do
    {:error,
     Error.new(:invalid_request, "DeepSeek Responses #{param} must be #{expected}", %{
       provider: :deepseek,
       api: :responses,
       param: param,
       value: inspect(value)
     })}
  end

  defp validate_model_overrides(model, opts) do
    model_kwargs = Keyword.get(opts, :model_kwargs, model.model_kwargs)
    extra_body = Keyword.get(opts, :extra_body)

    overrides =
      []
      |> maybe_add_keyword_value(opts, :model)
      |> maybe_add_map_value(model_kwargs, "model")
      |> maybe_add_map_value(extra_body, "model")

    Enum.reduce_while(overrides, :ok, fn override, :ok ->
      case validate_responses_model(override) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp maybe_add_keyword_value(values, opts, key) do
    if Keyword.has_key?(opts, key), do: [Keyword.get(opts, key) | values], else: values
  end

  defp maybe_add_map_value(values, nil, _key), do: values

  defp maybe_add_map_value(values, map, key) when is_map(map) do
    case map |> BeamWeaver.MapShape.stringify_keys() |> Map.fetch(key) do
      {:ok, value} -> [value | values]
      :error -> values
    end
  end

  defp restore_reserved_fields(body, model, opts) do
    body
    |> Map.put("model", model.model)
    |> Map.put("stream", Keyword.get(opts, :stream, false))
  end

  defp validate_unsupported_options(model, opts) do
    model_params = model |> Map.from_struct() |> BeamWeaver.MapShape.stringify_keys()
    call_params = opts |> Map.new() |> BeamWeaver.MapShape.stringify_keys()
    model_kwargs = Keyword.get(opts, :model_kwargs, model.model_kwargs)
    extra_body = Keyword.get(opts, :extra_body)

    with :ok <- reject_configured_unsupported_values(model_params),
         :ok <- reject_unsupported_keys(call_params),
         :ok <- reject_unsupported_keys(stringify_optional_map(model_kwargs)),
         :ok <- reject_unsupported_keys(stringify_optional_map(extra_body)) do
      :ok
    end
  end

  defp validate_unsupported_body(body), do: reject_unsupported_keys(body)

  defp reject_unsupported_keys(values) when is_map(values) do
    values
    |> unsupported_keys(&Map.has_key?(&1, &2))
    |> unsupported_keys_result()
  end

  defp reject_configured_unsupported_values(values) when is_map(values) do
    values
    |> unsupported_keys(&(Map.get(&1, &2) != nil))
    |> unsupported_keys_result()
  end

  defp unsupported_keys(values, predicate) do
    Enum.filter(@unsupported_params, &predicate.(values, &1))
  end

  defp unsupported_keys_result(rejected) do
    case rejected do
      [] ->
        :ok

      keys ->
        {:error,
         Error.new(:unsupported_model_param, "DeepSeek Responses parameter is not supported", %{
           provider: :deepseek,
           api: :responses,
           params: Enum.map(keys, &String.to_atom/1),
           stateless: true
         })}
    end
  end

  defp meaningful_key?(map, key), do: Map.get(map, key) not in [nil, false, [], %{}]

  defp stringify_optional_map(nil), do: %{}
  defp stringify_optional_map(map) when is_map(map), do: BeamWeaver.MapShape.stringify_keys(map)

  defp validate_instructions(%{"instructions" => instructions})
       when is_binary(instructions) and instructions != "",
       do: :ok

  defp validate_instructions(%{"instructions" => instructions}) do
    {:error,
     Error.new(:invalid_request, "DeepSeek Responses instructions must be a nonempty string", %{
       provider: :deepseek,
       api: :responses,
       param: :instructions,
       value: inspect(instructions)
     })}
  end

  defp validate_instructions(_body), do: :ok

  defp validate_required_input(%{"input" => [_item | _rest]}), do: :ok

  defp validate_required_input(%{"instructions" => instructions})
       when is_binary(instructions) and instructions != "",
       do: :ok

  defp validate_required_input(_body) do
    {:error,
     Error.new(:invalid_request, "DeepSeek Responses requires nonempty input or instructions", %{
       provider: :deepseek,
       api: :responses,
       required: [:input, :instructions]
     })}
  end

  defp validate_input_items(items, tools) when is_list(items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case validate_input_item(item, tools || []) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_input_items(_items, _tools) do
    {:error, Error.new(:invalid_request, "DeepSeek Responses input must be a list")}
  end

  defp validate_input_item(%{"type" => "message", "content" => content}, _tools)
       when is_list(content) do
    Enum.reduce_while(content, :ok, fn part, :ok ->
      case is_map(part) && part["type"] do
        type when type in ["input_text", "output_text", "text"] ->
          if is_binary(part["text"]), do: {:cont, :ok}, else: {:halt, unsupported_input(type)}

        type ->
          {:halt, unsupported_input(type)}
      end
    end)
  end

  defp validate_input_item(%{"type" => "message", "content" => content}, _tools)
       when is_binary(content),
       do: :ok

  defp validate_input_item(%{"type" => "message"}, _tools),
    do: unsupported_input(:message_content)

  defp validate_input_item(%{"type" => "reasoning"} = item, _tools) do
    if meaningful_key?(item, "summary") or meaningful_key?(item, "encrypted_content") do
      {:error,
       Error.new(:unsupported_feature, "DeepSeek Responses reasoning replay supports plain text only", %{
         provider: :deepseek,
         api: :responses,
         feature: :reasoning_replay
       })}
    else
      :ok
    end
  end

  defp validate_input_item(%{"type" => "function_call"} = item, _tools) do
    with :ok <- validate_call_id(item, "function_call"),
         :ok <- validate_nonempty_string_field(item, "name", "function_call"),
         :ok <- validate_nonempty_string_field(item, "arguments", "function_call") do
      :ok
    end
  end

  defp validate_input_item(%{"type" => "function_call_output"} = item, _tools) do
    with :ok <- validate_call_id(item, "function_call_output"),
         :ok <- validate_string_field(item, "output", "function_call_output") do
      :ok
    end
  end

  defp validate_input_item(%{"type" => "custom_tool_call", "name" => "apply_patch"} = item, tools) do
    with :ok <- validate_call_id(item, "custom_tool_call"),
         :ok <- validate_nonempty_string_field(item, "input", "custom_tool_call"),
         true <- apply_patch_declared?(tools) do
      :ok
    else
      false ->
        {:error,
         Error.new(:invalid_request, "DeepSeek custom tool replay requires the apply_patch tool", %{
           provider: :deepseek,
           api: :responses,
           feature: :apply_patch
         })}

      {:error, _error} = error ->
        error
    end
  end

  defp validate_input_item(%{"type" => "custom_tool_call"} = item, _tools) do
    {:error,
     Error.new(:unsupported_feature, "DeepSeek custom input supports apply_patch only", %{
       provider: :deepseek,
       api: :responses,
       feature: :custom_tool_call,
       name: item["name"]
     })}
  end

  defp validate_input_item(%{"type" => "custom_tool_call_output"} = item, tools) do
    with :ok <- validate_call_id(item, "custom_tool_call_output"),
         :ok <- validate_string_field(item, "output", "custom_tool_call_output"),
         true <- apply_patch_declared?(tools) do
      :ok
    else
      false ->
        {:error,
         Error.new(:invalid_request, "DeepSeek custom tool replay requires the apply_patch tool", %{
           provider: :deepseek,
           api: :responses,
           feature: :apply_patch
         })}

      {:error, _error} = error ->
        error
    end
  end

  defp validate_input_item(%{"type" => type}, _tools)
       when type in ["web_search_call"],
       do: :ok

  defp validate_input_item(%{"type" => type}, _tools), do: unsupported_input(type)
  defp validate_input_item(_item, _tools), do: unsupported_input(nil)

  defp validate_call_id(item, type) do
    case item["call_id"] do
      call_id when is_binary(call_id) and call_id != "" ->
        :ok

      call_id ->
        {:error,
         Error.new(:invalid_request, "DeepSeek Responses call_id must be a nonempty string", %{
           provider: :deepseek,
           api: :responses,
           input_type: type,
           call_id: call_id
         })}
    end
  end

  defp validate_nonempty_string_field(item, field, type) do
    case Map.get(item, field) do
      value when is_binary(value) and value != "" -> :ok
      value -> required_string_field_error(field, value, type, "a nonempty string")
    end
  end

  defp validate_string_field(item, field, type) do
    case Map.fetch(item, field) do
      {:ok, value} when is_binary(value) -> :ok
      {:ok, value} -> required_string_field_error(field, value, type, "a string")
      :error -> required_string_field_error(field, nil, type, "a string")
    end
  end

  defp required_string_field_error(field, value, type, expected) do
    {:error,
     Error.new(:invalid_request, "DeepSeek Responses #{type} #{field} must be #{expected}", %{
       provider: :deepseek,
       api: :responses,
       input_type: type,
       param: String.to_atom(field),
       value: value
     })}
  end

  defp unsupported_input(type) do
    {:error,
     Error.new(:unsupported_feature, "DeepSeek Responses input item is not supported", %{
       provider: :deepseek,
       api: :responses,
       feature: input_feature(type),
       input_type: type,
       supported: @allowed_input_types
     })}
  end

  defp input_feature(type) when type in ["input_image", "image", "image_url"], do: :image
  defp input_feature(type) when type in ["input_file", "file"], do: :file
  defp input_feature(type) when type in ["input_audio", "audio"], do: :audio
  defp input_feature(type), do: type

  defp validate_tools(nil), do: :ok
  defp validate_tools([]), do: :ok
  defp validate_tools(tools) when is_list(tools), do: Tools.validate_responses_tools(tools)

  defp validate_tools(_tools) do
    {:error, Error.new(:invalid_request, "DeepSeek Responses tools must be a list")}
  end

  defp validate_call_pairs(items) when is_list(items) do
    with :ok <- validate_pair_type(items, "function_call", "function_call_output"),
         :ok <- validate_pair_type(items, "custom_tool_call", "custom_tool_call_output") do
      :ok
    end
  end

  defp validate_call_pairs(_items), do: :ok

  defp validate_pair_type(items, call_type, output_type) do
    calls = call_ids(items, call_type)
    outputs = call_ids(items, output_type)

    cond do
      length(calls) != length(Enum.uniq(calls)) ->
        duplicate_call_id_error(call_type, calls)

      length(outputs) != length(Enum.uniq(outputs)) ->
        duplicate_call_id_error(output_type, outputs)

      Enum.sort(calls) != Enum.sort(outputs) ->
        {:error,
         Error.new(
           :invalid_request,
           "DeepSeek Responses requires exactly one output for every #{call_type}",
           %{
             provider: :deepseek,
             api: :responses,
             call_type: call_type,
             output_type: output_type,
             calls: calls,
             outputs: outputs
           }
         )}

      true ->
        :ok
    end
  end

  defp call_ids(items, type) do
    for %{"type" => ^type, "call_id" => call_id} <- items, do: call_id
  end

  defp duplicate_call_id_error(type, ids) do
    duplicates = ids -- Enum.uniq(ids)

    {:error,
     Error.new(:invalid_request, "DeepSeek Responses call_id values must be unique per item type", %{
       provider: :deepseek,
       api: :responses,
       input_type: type,
       call_ids: Enum.uniq(duplicates)
     })}
  end

  defp validate_request_values(body) do
    with :ok <-
           validate_integer_range(
             body["max_output_tokens"],
             :max_output_tokens,
             1,
             @max_output_tokens
           ),
         :ok <- validate_number_range(body["temperature"], :temperature, 0, 2),
         :ok <- validate_number_range(body["top_p"], :top_p, 0, 1),
         :ok <- validate_integer_range(body["top_logprobs"], :top_logprobs, 0, 20),
         :ok <- validate_boolean(body["stream"], :stream),
         :ok <- validate_optional_map(body["text"], :text),
         :ok <- validate_reasoning(body["reasoning"]),
         :ok <- validate_user(body["user"]) do
      :ok
    end
  end

  defp validate_boolean(value, _param) when is_boolean(value), do: :ok

  defp validate_boolean(value, param) do
    {:error,
     Error.new(:invalid_request, "DeepSeek Responses #{param} must be a boolean", %{
       provider: :deepseek,
       api: :responses,
       param: param,
       value: value
     })}
  end

  defp validate_reasoning(nil), do: :ok

  defp validate_reasoning(%{} = reasoning) do
    case reasoning["effort"] do
      nil ->
        :ok

      effort when effort in @reasoning_efforts ->
        :ok

      effort ->
        {:error,
         Error.new(:invalid_request, "DeepSeek Responses reasoning effort is not supported", %{
           provider: :deepseek,
           api: :responses,
           param: :reasoning,
           effort: effort,
           supported: @reasoning_efforts
         })}
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
    {:error,
     Error.new(:invalid_request, "DeepSeek Responses #{param} must be #{type} from #{min} to #{max}", %{
       provider: :deepseek,
       api: :responses,
       param: param,
       value: value,
       min: min,
       max: max
     })}
  end

  defp validate_user(nil), do: :ok

  defp validate_user(user) when is_binary(user) do
    if byte_size(user) <= 512 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, user) do
      :ok
    else
      user_error(user)
    end
  end

  defp validate_user(user), do: user_error(user)

  defp user_error(user) do
    {:error,
     Error.new(:invalid_request, "DeepSeek Responses user must match [A-Za-z0-9_-]+ and be at most 512 bytes", %{
       provider: :deepseek,
       api: :responses,
       param: :user,
       value: inspect(user)
     })}
  end

  defp validate_tool_choice(nil, _tools, _reasoning), do: :ok
  defp validate_tool_choice(choice, _tools, _reasoning) when choice in ["none", "auto"], do: :ok
  defp validate_tool_choice("required", [_tool | _rest], _reasoning), do: :ok

  defp validate_tool_choice("required", _tools, _reasoning) do
    tool_choice_error("required", "requires at least one declared tool")
  end

  defp validate_tool_choice(%{"type" => "function", "name" => name} = choice, tools, reasoning)
       when is_binary(name) do
    with :ok <- validate_forced_tool_reasoning(choice, reasoning),
         true <- declared_function?(tools, name) do
      :ok
    else
      false -> undeclared_tool_choice(choice, name)
      {:error, _error} = error -> error
    end
  end

  defp validate_tool_choice(%{"type" => type} = choice, tools, _reasoning)
       when type in ["web_search", "web_search_2025_08_26"] do
    if declared_web_search?(tools), do: :ok, else: undeclared_tool_choice(choice, type)
  end

  defp validate_tool_choice(
         %{"type" => "custom", "name" => "apply_patch"} = choice,
         tools,
         reasoning
       ) do
    with :ok <- validate_forced_tool_reasoning(choice, reasoning),
         true <- apply_patch_declared?(tools) do
      :ok
    else
      false -> undeclared_tool_choice(choice, "apply_patch")
      {:error, _error} = error -> error
    end
  end

  defp validate_tool_choice(choice, _tools, _reasoning) do
    tool_choice_error(choice, "is not supported")
  end

  defp validate_forced_tool_reasoning(_choice, %{"effort" => "none"}), do: :ok

  defp validate_forced_tool_reasoning(choice, reasoning) do
    {:error,
     Error.new(
       :unsupported_model_param,
       "DeepSeek Responses forced function and custom tool choices require reasoning effort none",
       %{
         provider: :deepseek,
         api: :responses,
         param: :tool_choice,
         value: choice,
         reasoning: reasoning,
         required: %{reasoning: %{effort: "none"}}
       }
     )}
  end

  defp declared_function?(tools, name) do
    Enum.any?(tools || [], fn
      %{"type" => "function", "name" => ^name} -> true
      _tool -> false
    end)
  end

  defp declared_web_search?(tools) do
    Enum.any?(tools || [], fn
      %{"type" => type} when type in ["web_search", "web_search_2025_08_26"] -> true
      _tool -> false
    end)
  end

  defp apply_patch_declared?(tools) do
    Enum.any?(tools || [], fn
      %{"type" => "custom", "name" => "apply_patch"} -> true
      _tool -> false
    end)
  end

  defp undeclared_tool_choice(choice, name) do
    {:error,
     Error.new(:invalid_request, "DeepSeek Responses tool_choice must reference a declared tool", %{
       provider: :deepseek,
       api: :responses,
       param: :tool_choice,
       value: choice,
       name: name
     })}
  end

  defp tool_choice_error(choice, reason) do
    {:error,
     Error.new(:unsupported_model_param, "DeepSeek Responses tool_choice #{reason}", %{
       provider: :deepseek,
       api: :responses,
       param: :tool_choice,
       value: choice,
       supported: ["none", "auto", "required", :named_function, :web_search, :apply_patch]
     })}
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

  defp model_stream_metadata(%__MODULE__{} = model, body, opts) do
    model
    |> InvocationMetadata.provider(:deepseek, body, opts, :responses)
    |> InvocationMetadata.to_metadata_map()
  end

  defp convert_error({:error, %BeamWeaver.OpenAI.Error{} = error}) do
    {:error, Error.new(error.type, error.message, error.details)}
  end

  defp convert_error({:error, %BeamWeaver.Core.Error{} = error}) do
    {:error, Error.new(error.type, error.message, error.details)}
  end

  defp convert_error(other), do: other

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
          provider_name: "DeepSeek"
        )
      end,
      metadata: &model_stream_metadata/3,
      source: :deepseek_responses
    }
  end
end
