defmodule BeamWeaver.DeepSeek.Options do
  @moduledoc false

  import BeamWeaver.Provider.Options,
    only: [
      extra_body: 2,
      merge_extra_body: 3,
      normalize_option_map: 1,
      normalize_value: 1,
      option: 3,
      put_optional: 3
    ]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.DeepSeek.Messages
  alias BeamWeaver.DeepSeek.Tools
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Provider.JsonObjectFormat

  @models BeamWeaver.Models.ProfileRegistry.DeepSeek.supported_models()
  @max_output_tokens 393_216
  @thinking_modes ["enabled", "disabled"]
  @reasoning_efforts ~w(none minimal low medium high xhigh max ultra)
  @deprecated_params [
    "frequency_penalty",
    "presence_penalty"
  ]
  @unsupported_params [
    "audio",
    "function_call",
    "functions",
    "logit_bias",
    "modalities",
    "n",
    "parallel_tool_calls",
    "prediction",
    "prompt_cache_key",
    "prompt_cache_options",
    "prompt_cache_retention",
    "safety_identifier",
    "seed",
    "service_tier",
    "store",
    "user",
    "verbosity",
    "web_search_options"
  ]

  # `extra_body` can't replace these: the client sets them for the call.
  @reserved_body_fields ["model", "messages", "stream"]

  @spec to_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def to_body(model, messages, opts) do
    with :ok <- validate_profile_params(model, opts),
         :ok <- validate_extra_body(model, opts),
         {:ok, deepseek_messages} <- Messages.to_chat_messages(messages, option(model, opts, :model)),
         {:ok, response_format, instruction} <- response_format(model, opts),
         deepseek_messages = JsonObjectFormat.inject_instruction(deepseek_messages, instruction),
         {:ok, tools} <- render_tools(Keyword.get(opts, :tools, [])),
         body = build_body(model, deepseek_messages, tools, response_format, opts),
         :ok <- validate_body(body),
         :ok <- BeamWeaver.DeepSeek.Vision.validate_request(body, :chat_completions) do
      {:ok, body}
    end
  end

  @doc false
  # Thinking mode takes no explicit tool choice; a forced one needs thinking
  # disabled.
  def forced_tool_choice?(model, opts) do
    thinking = normalize_option_map(option(model, opts, :thinking))
    effort = normalize_value(option(model, opts, :reasoning_effort))

    thinking_disabled?(thinking) or (is_nil(thinking) and effort == "none")
  end

  @doc false
  @spec response_parse_opts(term(), keyword()) :: keyword()
  def response_parse_opts(model, opts) when is_list(opts) do
    format = effective_response_format(model, opts)
    opts = Keyword.drop(opts, [:response_format, :structured_output])

    if is_nil(format) or text_format?(format), do: opts, else: Keyword.put(opts, :response_format, format)
  end

  defp build_body(model, messages, tools, response_format, opts) do
    %{"model" => option(model, opts, :model), "messages" => messages}
    |> put_optional("thinking", normalize_option_map(option(model, opts, :thinking)))
    |> put_optional("reasoning_effort", normalize_value(option(model, opts, :reasoning_effort)))
    |> put_optional("temperature", option(model, opts, :temperature))
    |> put_optional("top_p", option(model, opts, :top_p))
    |> put_optional("max_tokens", max_tokens(model, opts))
    |> put_optional("stop", option(model, opts, :stop))
    |> put_optional("response_format", response_format)
    |> put_optional("tools", tools)
    |> put_optional("tool_choice", ChatCompletionsWire.tool_choice(option(model, opts, :tool_choice)))
    |> put_optional("stream", Keyword.get(opts, :stream, false))
    |> put_optional("stream_options", normalize_option_map(Keyword.get(opts, :stream_options)))
    |> maybe_put_stream_usage(model, opts)
    |> put_optional("logprobs", option(model, opts, :logprobs))
    |> put_optional("top_logprobs", option(model, opts, :top_logprobs))
    |> put_optional("user_id", option(model, opts, :user_id))
    |> merge_extra_body(extra_body(model, opts), reserved: @reserved_body_fields)
  end

  defp error(type, message, details),
    do: {:error, Error.new(type, message, Enum.into(details, %{provider: :deepseek}))}

  defp validate_profile_params(model, opts) do
    params =
      model
      |> Map.from_struct()
      |> Map.take([
        :extra_body,
        :logprobs,
        :max_completion_tokens,
        :max_output_tokens,
        :max_tokens,
        :reasoning_effort,
        :response_format,
        :stop,
        :stream_usage,
        :structured_output,
        :temperature,
        :thinking,
        :tool_choice,
        :top_logprobs,
        :top_p,
        :user_id
      ])
      |> Map.merge(Map.new(opts))

    ParamPolicy.validate(Map.get(model, :profile), params, option(model, opts, :param_policy), api: :chat_completions)
  end

  defp response_format(model, opts) do
    format = effective_response_format(model, opts)

    if text_format?(format),
      do: {:ok, nil, nil},
      else:
        JsonObjectFormat.normalize(format,
          error_message: "DeepSeek Chat Completions supports JSON object response_format only",
          error_details: %{provider: :deepseek, api: :chat_completions}
        )
  end

  defp render_tools(tools) when is_list(tools) do
    with {:error, %Error{} = error} <- BeamWeaver.Result.traverse(tools, &Tools.render_chat_tool/1),
         do: {:error, %{error | details: Map.put(error.details || %{}, :provider, :deepseek)}}
  rescue
    exception in ArgumentError ->
      {:error, Error.new(:invalid_request, exception.message, %{provider: :deepseek})}
  end

  defp render_tools(_tools) do
    {:error, Error.new(:invalid_request, "DeepSeek tools must be a list")}
  end

  defp validate_body(body) do
    with :ok <- validate_model(body["model"]),
         :ok <- reject_unsupported_params(body),
         :ok <- validate_tools(body["tools"]),
         :ok <- validate_response_format(body["response_format"]),
         :ok <- validate_thinking(body["thinking"]),
         :ok <- validate_reasoning_effort(body["reasoning_effort"]),
         :ok <- validate_integer_range(body["max_tokens"], :max_tokens, 1, @max_output_tokens),
         :ok <- validate_number_range(body["temperature"], :temperature, 0, 2),
         :ok <- validate_number_range(body["top_p"], :top_p, 0, 1),
         :ok <- validate_stop(body["stop"]),
         :ok <- validate_stream_options(body),
         :ok <- validate_logprobs(body),
         :ok <- validate_user_id(body["user_id"]),
         do: validate_tool_choice(body["tool_choice"], body["tools"], effective_thinking(body))
  end

  defp validate_extra_body(model, opts) do
    case Enum.reject([Map.get(model, :extra_body), Keyword.get(opts, :extra_body)], &(is_nil(&1) or is_map(&1))) do
      [] ->
        :ok

      [value | _rest] ->
        error(:invalid_request, "DeepSeek extra_body must be a map",
          api: :chat_completions,
          param: :extra_body,
          value: inspect(value)
        )
    end
  end

  defp validate_tools(nil), do: :ok
  defp validate_tools(tools) when is_list(tools), do: Tools.validate_chat_tools(tools)

  defp validate_tools(tools),
    do:
      error(:invalid_request, "DeepSeek tools must be a list",
        api: :chat_completions,
        param: :tools,
        value: inspect(tools)
      )

  defp validate_response_format(nil), do: :ok

  defp validate_response_format(%{"type" => type} = format)
       when type in ["text", "json_object"] and map_size(format) == 1,
       do: :ok

  defp validate_response_format(response_format) do
    error(:invalid_response_format, "DeepSeek Chat Completions supports text or JSON object response_format only",
      api: :chat_completions,
      response_format: inspect(response_format),
      supported: [%{"type" => "text"}, %{"type" => "json_object"}]
    )
  end

  defp validate_model(model) when model in @models, do: :ok

  defp validate_model(model) do
    error(:unsupported_model, "DeepSeek model is not supported",
      model: model,
      supported: @models,
      expected: "deepseek:deepseek-flash"
    )
  end

  defp reject_unsupported_params(body) do
    case Enum.filter(@deprecated_params ++ @unsupported_params, &Map.has_key?(body, &1)) do
      [] ->
        :ok

      keys ->
        error(:unsupported_model_param, "DeepSeek Chat Completions parameter is not supported",
          api: :chat_completions,
          model: body["model"],
          params: Enum.map(keys, &String.to_atom/1)
        )
    end
  end

  defp validate_thinking(nil), do: :ok
  defp validate_thinking(%{"type" => type}) when type in @thinking_modes, do: :ok

  defp validate_thinking(value) do
    error(:unsupported_model_param, "DeepSeek thinking must select enabled or disabled",
      param: :thinking,
      value: value,
      supported: Enum.map(@thinking_modes, &%{"type" => &1})
    )
  end

  defp validate_reasoning_effort(effort) when is_nil(effort) or effort in @reasoning_efforts, do: :ok

  defp validate_reasoning_effort(effort) do
    error(:unsupported_model_param, "DeepSeek reasoning_effort is not supported",
      param: :reasoning_effort,
      value: effort,
      supported: @reasoning_efforts
    )
  end

  defp validate_stop(stop) when is_nil(stop) or is_binary(stop), do: :ok

  defp validate_stop(stop) when is_list(stop) do
    cond do
      length(stop) > 16 -> stop_error(stop, "DeepSeek supports at most 16 stop sequences")
      Enum.all?(stop, &is_binary/1) -> :ok
      true -> stop_error(stop, "DeepSeek stop sequences must be strings")
    end
  end

  defp validate_stop(stop), do: stop_error(stop, "DeepSeek stop must be a string or list")

  defp stop_error(stop, message), do: error(:invalid_request, message, param: :stop, value: inspect(stop))

  defp validate_stream_options(%{"stream_options" => options}) when not is_map(options) do
    error(:invalid_request, "DeepSeek stream_options must be a map", param: :stream_options, value: inspect(options))
  end

  defp validate_stream_options(%{"stream_options" => _options, "stream" => true}), do: :ok

  defp validate_stream_options(%{"stream_options" => _options}) do
    error(:unsupported_model_param, "DeepSeek stream_options requires stream: true",
      param: :stream_options,
      required: %{stream: true}
    )
  end

  defp validate_stream_options(_body), do: :ok

  defp validate_logprobs(%{"top_logprobs" => value, "logprobs" => true})
       when is_integer(value) and value in 0..20,
       do: :ok

  defp validate_logprobs(%{"top_logprobs" => value}) do
    error(:invalid_request, "DeepSeek top_logprobs requires logprobs: true and a value from 0 to 20",
      top_logprobs: value
    )
  end

  defp validate_logprobs(%{"logprobs" => value}) when is_boolean(value), do: :ok

  defp validate_logprobs(%{"logprobs" => value}),
    do: error(:invalid_request, "DeepSeek logprobs must be a boolean", param: :logprobs, value: value)

  defp validate_logprobs(_body), do: :ok

  defp validate_user_id(nil), do: :ok

  defp validate_user_id(user_id) do
    if is_binary(user_id) and byte_size(user_id) <= 512 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, user_id) do
      :ok
    else
      error(:invalid_request, "DeepSeek user_id must match [A-Za-z0-9_-]+ and be at most 512 bytes",
        param: :user_id,
        value: inspect(user_id)
      )
    end
  end

  defp validate_tool_choice(nil, _tools, _thinking), do: :ok
  defp validate_tool_choice(choice, _tools, _thinking) when choice in ["none", "auto"], do: :ok

  defp validate_tool_choice(choice, _tools, thinking)
       when not is_nil(choice) and (is_nil(thinking) or thinking == %{"type" => "enabled"}) do
    error(:unsupported_model_param, "DeepSeek thinking mode does not accept an explicit tool_choice",
      param: :tool_choice,
      value: choice,
      required: %{thinking: %{type: "disabled"}}
    )
  end

  defp validate_tool_choice("required", [_tool | _rest], _thinking), do: :ok

  defp validate_tool_choice("required", _tools, _thinking) do
    error(:invalid_request, "DeepSeek tool_choice required needs at least one tool",
      param: :tool_choice,
      value: "required"
    )
  end

  defp validate_tool_choice(%{"type" => "function", "function" => %{"name" => name}}, tools, thinking)
       when is_binary(name) do
    cond do
      not Enum.any?(tools || [], &(get_in(&1, ["function", "name"]) == name)) ->
        error(:invalid_request, "DeepSeek named tool_choice must reference a declared tool",
          param: :tool_choice,
          name: name
        )

      not thinking_disabled?(thinking) ->
        error(:unsupported_model_param, "DeepSeek forced named tool_choice requires thinking to be explicitly disabled",
          param: :tool_choice,
          name: name,
          required: %{thinking: %{type: "disabled"}}
        )

      true ->
        :ok
    end
  end

  defp validate_tool_choice(value, _tools, _thinking) do
    error(:unsupported_model_param, "DeepSeek tool_choice is not supported",
      param: :tool_choice,
      value: value,
      supported: ["none", "auto", "required", %{type: "function", function: %{name: "..."}}]
    )
  end

  defp thinking_disabled?(%{"type" => "disabled"}), do: true
  defp thinking_disabled?(_thinking), do: false

  defp effective_thinking(%{"reasoning_effort" => "none"} = body),
    do: body["thinking"] || %{"type" => "disabled"}

  defp effective_thinking(body), do: body["thinking"]

  defp validate_integer_range(nil, _param, _min, _max), do: :ok

  defp validate_integer_range(value, _param, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: :ok

  defp validate_integer_range(value, param, min, max) do
    range_error(param, value, "an integer from #{min} to #{max}", min, max)
  end

  defp validate_number_range(nil, _param, _min, _max), do: :ok

  defp validate_number_range(value, _param, min, max)
       when is_number(value) and value >= min and value <= max,
       do: :ok

  defp validate_number_range(value, param, min, max) do
    range_error(param, value, "a number from #{min} to #{max}", min, max)
  end

  defp range_error(param, value, expected, min, max),
    do: error(:invalid_request, "DeepSeek #{param} must be #{expected}", param: param, value: value, min: min, max: max)

  defp maybe_put_stream_usage(body, model, opts) do
    stream? = body["stream"] == true
    stream_usage? = Keyword.get(opts, :stream_usage, Map.get(model, :stream_usage, true))

    cond do
      not stream? or not stream_usage? ->
        body

      is_map(body["stream_options"]) ->
        update_in(body, ["stream_options"], &Map.put_new(&1, "include_usage", true))

      Map.has_key?(body, "stream_options") ->
        body

      true ->
        Map.put(body, "stream_options", %{"include_usage" => true})
    end
  end

  defp max_tokens(model, opts) do
    option(model, opts, :max_tokens) ||
      option(model, opts, :max_output_tokens) ||
      option(model, opts, :max_completion_tokens)
  end

  defp effective_response_format(model, opts) do
    option(model, opts, :response_format) || option(model, opts, :structured_output)
  end

  defp text_format?(%{"type" => type}) when type in [:text, "text"], do: true
  defp text_format?(%{type: type}) when type in [:text, "text"], do: true
  defp text_format?(_format), do: false
end
