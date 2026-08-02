defmodule BeamWeaver.DeepSeek.Options do
  @moduledoc false

  alias BeamWeaver.DeepSeek.Error
  alias BeamWeaver.DeepSeek.Messages
  alias BeamWeaver.DeepSeek.Tools
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.Provider.JsonObjectFormat
  alias BeamWeaver.Provider.Options, as: ProviderOptions

  @models ["deepseek-v4-flash", "deepseek-v4-pro"]
  @max_output_tokens 393_216
  @thinking_modes ["enabled", "disabled"]
  @reasoning_efforts ["low", "medium", "high", "xhigh", "max"]
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

  @spec to_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def to_body(model, messages, opts \\ []) do
    with :ok <- validate_profile_params(model, opts),
         :ok <- validate_model_kwargs(option(model, opts, :model_kwargs)),
         {:ok, deepseek_messages} <- Messages.to_chat_messages(messages),
         {:ok, response_format, instruction} <- response_format(model, opts),
         deepseek_messages <- JsonObjectFormat.inject_instruction(deepseek_messages, instruction),
         {:ok, tools} <- render_tools(Keyword.get(opts, :tools, [])),
         {:ok, body} <- build_body(model, deepseek_messages, tools, response_format, opts),
         :ok <- validate_body(body) do
      {:ok, body}
    end
  end

  @doc false
  @spec response_parse_opts(term(), keyword()) :: keyword()
  def response_parse_opts(model, opts) when is_list(opts) do
    format = effective_response_format(model, opts)
    opts = Keyword.drop(opts, [:response_format, :structured_output])

    if structured_output_format?(format) do
      Keyword.put(opts, :response_format, format)
    else
      opts
    end
  end

  defp build_body(model, messages, tools, response_format, opts) do
    model_name = option(model, opts, :model)
    model_kwargs = option(model, opts, :model_kwargs) || %{}

    body =
      %{
        "model" => model_name,
        "messages" => messages
      }
      |> merge_model_kwargs(model_kwargs)
      |> Map.put("model", model_name)
      |> Map.put("messages", messages)
      |> ProviderOptions.put_optional("thinking", normalize_map(option(model, opts, :thinking)))
      |> ProviderOptions.put_optional(
        "reasoning_effort",
        normalize_value(option(model, opts, :reasoning_effort))
      )
      |> ProviderOptions.put_optional("temperature", option(model, opts, :temperature))
      |> ProviderOptions.put_optional("top_p", option(model, opts, :top_p))
      |> ProviderOptions.put_optional("max_tokens", max_tokens(model, opts))
      |> ProviderOptions.put_optional("stop", Keyword.get(opts, :stop, Map.get(model, :stop)))
      |> ProviderOptions.put_optional("response_format", response_format)
      |> ProviderOptions.put_optional("tools", tools)
      |> ProviderOptions.put_optional(
        "tool_choice",
        normalize_value(Keyword.get(opts, :tool_choice, Map.get(model, :tool_choice)))
      )
      |> ProviderOptions.put_optional("stream", Keyword.get(opts, :stream, false))
      |> ProviderOptions.put_optional(
        "stream_options",
        normalize_map(Keyword.get(opts, :stream_options))
      )
      |> maybe_put_stream_usage(model, opts)
      |> ProviderOptions.put_optional("logprobs", option(model, opts, :logprobs))
      |> ProviderOptions.put_optional("top_logprobs", option(model, opts, :top_logprobs))
      |> ProviderOptions.put_optional("user_id", option(model, opts, :user_id))

    {:ok, body}
  end

  defp validate_profile_params(model, opts) do
    params =
      model
      |> Map.from_struct()
      |> Map.take([
        :logprobs,
        :max_completion_tokens,
        :max_output_tokens,
        :max_tokens,
        :model_kwargs,
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
      |> Map.merge(Map.new(Keyword.drop(opts, [:metadata])))

    ParamPolicy.validate(
      Map.get(model, :profile),
      params,
      Keyword.get(opts, :param_policy, Map.get(model, :param_policy)),
      api: :chat_completions,
      metadata: Keyword.get(opts, :metadata, %{})
    )
    |> convert_core_error()
  end

  defp response_format(model, opts) do
    format = effective_response_format(model, opts)

    case format do
      %{"type" => type} when type in [:text, "text"] ->
        {:ok, nil, nil}

      %{type: type} when type in [:text, "text"] ->
        {:ok, nil, nil}

      other ->
        JsonObjectFormat.normalize(other,
          error_module: Error,
          error_message: "DeepSeek Chat Completions supports JSON object response_format only",
          error_details: %{provider: :deepseek, api: :chat_completions}
        )
    end
  end

  defp render_tools([]), do: {:ok, []}

  defp render_tools(tools) when is_list(tools) do
    {:ok, Tools.to_chat_tools(tools)}
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
         :ok <- validate_tool_choice(body["tool_choice"], body["tools"], body["thinking"]) do
      :ok
    end
  end

  defp validate_model_kwargs(nil), do: :ok
  defp validate_model_kwargs(model_kwargs) when is_map(model_kwargs), do: :ok

  defp validate_model_kwargs(model_kwargs) do
    {:error,
     Error.new(:invalid_request, "DeepSeek model_kwargs must be a map", %{
       provider: :deepseek,
       api: :chat_completions,
       param: :model_kwargs,
       value: inspect(model_kwargs)
     })}
  end

  defp validate_tools(nil), do: :ok
  defp validate_tools(tools) when is_list(tools), do: Tools.validate_chat_tools(tools)

  defp validate_tools(tools) do
    {:error,
     Error.new(:invalid_request, "DeepSeek tools must be a list", %{
       provider: :deepseek,
       api: :chat_completions,
       param: :tools,
       value: inspect(tools)
     })}
  end

  defp validate_response_format(nil), do: :ok

  defp validate_response_format(%{"type" => type} = format)
       when type in ["text", "json_object"] and map_size(format) == 1,
       do: :ok

  defp validate_response_format(response_format) do
    {:error,
     Error.new(
       :invalid_response_format,
       "DeepSeek Chat Completions supports text or JSON object response_format only",
       %{
         provider: :deepseek,
         api: :chat_completions,
         response_format: inspect(response_format),
         supported: [%{"type" => "text"}, %{"type" => "json_object"}]
       }
     )}
  end

  defp validate_model(model) when model in @models, do: :ok

  defp validate_model(model) do
    {:error,
     Error.new(:unsupported_model, "DeepSeek model is not supported", %{
       provider: :deepseek,
       model: model,
       supported: @models,
       expected: "deepseek:deepseek-v4-flash"
     })}
  end

  defp reject_unsupported_params(body) do
    rejected = Enum.filter(@deprecated_params ++ @unsupported_params, &Map.has_key?(body, &1))

    case rejected do
      [] ->
        :ok

      keys ->
        {:error,
         Error.new(:unsupported_model_param, "DeepSeek Chat Completions parameter is not supported", %{
           provider: :deepseek,
           api: :chat_completions,
           model: body["model"],
           params: Enum.map(keys, &String.to_atom/1)
         })}
    end
  end

  defp validate_thinking(nil), do: :ok
  defp validate_thinking(%{"type" => type}) when type in @thinking_modes, do: :ok

  defp validate_thinking(value) do
    {:error,
     Error.new(:unsupported_model_param, "DeepSeek thinking must select enabled or disabled", %{
       provider: :deepseek,
       param: :thinking,
       value: value,
       supported: Enum.map(@thinking_modes, &%{"type" => &1})
     })}
  end

  defp validate_reasoning_effort(nil), do: :ok
  defp validate_reasoning_effort(effort) when effort in @reasoning_efforts, do: :ok

  defp validate_reasoning_effort(effort) do
    {:error,
     Error.new(:unsupported_model_param, "DeepSeek reasoning_effort is not supported", %{
       provider: :deepseek,
       param: :reasoning_effort,
       value: effort,
       supported: @reasoning_efforts
     })}
  end

  defp validate_stop(nil), do: :ok
  defp validate_stop(stop) when is_binary(stop), do: :ok

  defp validate_stop(stop) when is_list(stop) do
    cond do
      length(stop) > 16 ->
        stop_error(stop, "DeepSeek supports at most 16 stop sequences")

      Enum.all?(stop, &is_binary/1) ->
        :ok

      true ->
        stop_error(stop, "DeepSeek stop sequences must be strings")
    end
  end

  defp validate_stop(stop), do: stop_error(stop, "DeepSeek stop must be a string or list")

  defp stop_error(stop, message) do
    {:error,
     Error.new(:invalid_request, message, %{
       provider: :deepseek,
       param: :stop,
       value: inspect(stop)
     })}
  end

  defp validate_stream_options(%{"stream_options" => options}) when not is_map(options) do
    {:error,
     Error.new(:invalid_request, "DeepSeek stream_options must be a map", %{
       provider: :deepseek,
       param: :stream_options,
       value: inspect(options)
     })}
  end

  defp validate_stream_options(%{"stream_options" => _options, "stream" => true}), do: :ok

  defp validate_stream_options(%{"stream_options" => _options}) do
    {:error,
     Error.new(:unsupported_model_param, "DeepSeek stream_options requires stream: true", %{
       provider: :deepseek,
       param: :stream_options,
       required: %{stream: true}
     })}
  end

  defp validate_stream_options(_body), do: :ok

  defp validate_logprobs(%{"top_logprobs" => value, "logprobs" => true})
       when is_integer(value) and value in 0..20,
       do: :ok

  defp validate_logprobs(%{"top_logprobs" => value}) do
    {:error,
     Error.new(:invalid_request, "DeepSeek top_logprobs requires logprobs: true and a value from 0 to 20", %{
       provider: :deepseek,
       top_logprobs: value
     })}
  end

  defp validate_logprobs(%{"logprobs" => value}) when is_boolean(value), do: :ok

  defp validate_logprobs(%{"logprobs" => value}) do
    {:error,
     Error.new(:invalid_request, "DeepSeek logprobs must be a boolean", %{
       provider: :deepseek,
       param: :logprobs,
       value: value
     })}
  end

  defp validate_logprobs(_body), do: :ok

  defp validate_user_id(nil), do: :ok

  defp validate_user_id(user_id) when is_binary(user_id) do
    if byte_size(user_id) <= 512 and Regex.match?(~r/^[A-Za-z0-9_-]+$/, user_id) do
      :ok
    else
      user_id_error(user_id)
    end
  end

  defp validate_user_id(user_id), do: user_id_error(user_id)

  defp user_id_error(user_id) do
    {:error,
     Error.new(:invalid_request, "DeepSeek user_id must match [A-Za-z0-9_-]+ and be at most 512 bytes", %{
       provider: :deepseek,
       param: :user_id,
       value: inspect(user_id)
     })}
  end

  defp validate_tool_choice(nil, _tools, _thinking), do: :ok

  defp validate_tool_choice(choice, _tools, thinking)
       when not is_nil(choice) and (is_nil(thinking) or thinking == %{"type" => "enabled"}) do
    {:error,
     Error.new(
       :unsupported_model_param,
       "DeepSeek thinking mode does not accept an explicit tool_choice",
       %{
         provider: :deepseek,
         param: :tool_choice,
         value: choice,
         required: %{thinking: %{type: "disabled"}}
       }
     )}
  end

  defp validate_tool_choice(choice, _tools, _thinking) when choice in ["none", "auto"], do: :ok

  defp validate_tool_choice("required", [_tool | _rest], _thinking), do: :ok

  defp validate_tool_choice("required", _tools, _thinking) do
    {:error,
     Error.new(:invalid_request, "DeepSeek tool_choice required needs at least one tool", %{
       provider: :deepseek,
       param: :tool_choice,
       value: "required"
     })}
  end

  defp validate_tool_choice(
         %{"type" => "function", "function" => %{"name" => name}},
         tools,
         thinking
       )
       when is_binary(name) do
    cond do
      not Enum.any?(tools || [], &(get_in(&1, ["function", "name"]) == name)) ->
        {:error,
         Error.new(:invalid_request, "DeepSeek named tool_choice must reference a declared tool", %{
           provider: :deepseek,
           param: :tool_choice,
           name: name
         })}

      not thinking_disabled?(thinking) ->
        {:error,
         Error.new(
           :unsupported_model_param,
           "DeepSeek forced named tool_choice requires thinking to be explicitly disabled",
           %{
             provider: :deepseek,
             param: :tool_choice,
             name: name,
             required: %{thinking: %{type: "disabled"}}
           }
         )}

      true ->
        :ok
    end
  end

  defp validate_tool_choice(value, _tools, _thinking) do
    {:error,
     Error.new(:unsupported_model_param, "DeepSeek tool_choice is not supported", %{
       provider: :deepseek,
       param: :tool_choice,
       value: value,
       supported: ["none", "auto", "required", %{type: "function", function: %{name: "..."}}]
     })}
  end

  defp thinking_disabled?(%{"type" => "disabled"}), do: true
  defp thinking_disabled?(_thinking), do: false

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

  defp range_error(param, value, expected, min, max) do
    {:error,
     Error.new(:invalid_request, "DeepSeek #{param} must be #{expected}", %{
       provider: :deepseek,
       param: param,
       value: value,
       min: min,
       max: max
     })}
  end

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

  defp option(model, opts, key), do: Keyword.get(opts, key, Map.get(model, key))

  defp effective_response_format(model, opts) do
    option(model, opts, :response_format) || option(model, opts, :structured_output)
  end

  defp structured_output_format?(nil), do: false
  defp structured_output_format?(%{"type" => type}) when type in [:text, "text"], do: false
  defp structured_output_format?(%{type: type}) when type in [:text, "text"], do: false
  defp structured_output_format?(_format), do: true

  defp normalize_map(nil), do: nil
  defp normalize_map(value) when is_map(value), do: MessageParts.stringify_keys(value)
  defp normalize_map(value), do: value

  defp normalize_value(nil), do: nil
  defp normalize_value(value) when is_map(value), do: MessageParts.stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value

  defp merge_model_kwargs(body, model_kwargs) when is_map(model_kwargs) do
    Map.merge(body, MessageParts.stringify_keys(model_kwargs))
  end

  defp convert_core_error({:error, %BeamWeaver.Core.Error{} = error}) do
    {:error, Error.new(error.type, error.message, error.details)}
  end

  defp convert_core_error(other), do: other
end
