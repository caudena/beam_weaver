defmodule BeamWeaver.ZAI.Options do
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

  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Models.ProfileRegistry
  alias BeamWeaver.Provider.JsonObjectFormat
  alias BeamWeaver.Core.Error
  alias BeamWeaver.ZAI.Messages

  @default_model "glm-5.2"

  # `extra_body` can't replace these: the client sets them for the call.
  @reserved_body_fields ["model", "messages", "stream"]

  @spec to_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def to_body(model, messages, opts \\ []) do
    with :ok <- validate_profile_params(model, opts),
         {:ok, zai_messages} <- Messages.to_chat_messages(messages, message_profile(model, opts)),
         {:ok, response_format, schema_instruction} <- response_format(model, opts),
         zai_messages <- JsonObjectFormat.inject_instruction(zai_messages, schema_instruction),
         {:ok, body} <- build_body(model, zai_messages, response_format, opts),
         {:ok, profile} <- resolve_profile(body),
         :ok <- validate_thinking(body, profile),
         :ok <- validate_reasoning_effort(body, profile),
         :ok <- validate_tool_stream(body),
         :ok <- validate_tool_choice(body),
         :ok <- validate_stop(body["stop"]) do
      {:ok, body}
    end
  end

  defp build_body(model, messages, response_format, opts) do
    model_name = option(model, opts, :model)
    extra_body = extra_body(model, opts)

    body =
      %{
        "model" => model_name,
        "messages" => messages
      }
      |> put_optional("do_sample", option(model, opts, :do_sample))
      |> put_optional("temperature", option(model, opts, :temperature))
      |> put_optional("top_p", option(model, opts, :top_p))
      |> put_optional("max_tokens", max_tokens(model, opts))
      |> put_optional("stop", option(model, opts, :stop))
      |> put_optional("stream", Keyword.get(opts, :stream, false))
      |> put_optional("stream_options", normalize_option_map(Keyword.get(opts, :stream_options)))
      |> put_optional("tool_stream", option(model, opts, :tool_stream))
      |> put_optional("thinking", normalize_value(option(model, opts, :thinking)))
      |> put_optional("reasoning_effort", normalize_value(option(model, opts, :reasoning_effort)))
      |> put_optional("response_format", response_format)
      |> put_optional("tool_choice", normalize_value(option(model, opts, :tool_choice)))
      |> put_optional("request_id", option(model, opts, :request_id))
      |> put_optional("user_id", option(model, opts, :user_id))
      |> merge_extra_body(extra_body, reserved: @reserved_body_fields)

    case rejected_extra_body_keys(extra_body) do
      [] ->
        {:ok, body}

      keys ->
        {:error,
         Error.new(:unsupported_model_param, "Z.ai does not support deprecated OpenAI params", %{
           provider: :zai,
           model: model_name,
           params: keys
         })}
    end
  end

  defp response_format(model, opts) do
    format = option(model, opts, :response_format) || option(model, opts, :structured_output)

    JsonObjectFormat.normalize(format,
      error_message: "Z.ai supports JSON object response_format only"
    )
  end

  defp validate_profile_params(model, opts) do
    params =
      model
      |> Map.from_struct()
      |> Map.take([
        :do_sample,
        :max_completion_tokens,
        :max_output_tokens,
        :max_tokens,
        :reasoning_effort,
        :request_id,
        :response_format,
        :stop,
        :stream_usage,
        :structured_output,
        :temperature,
        :thinking,
        :tool_choice,
        :tool_stream,
        :top_p,
        :user_id
      ])
      |> Map.merge(Map.new(opts))

    ParamPolicy.validate(
      Map.get(model, :profile),
      params,
      Keyword.get(opts, :param_policy, Map.get(model, :param_policy)),
      api: :chat_completions
    )
  end

  # The profile that decides which media the messages may carry: the model's
  # own, or the registry's for a call that names another model.
  defp message_profile(model, opts) do
    case option(model, opts, :model) do
      name when name == model.model ->
        model.profile

      name ->
        case ProfileRegistry.ZAI.resolve(name) do
          {:ok, profile} -> profile
          {:error, _error} -> nil
        end
    end
  end

  defp resolve_profile(%{"model" => model}) do
    case ProfileRegistry.ZAI.resolve(model) do
      {:ok, profile} ->
        {:ok, profile}

      _ ->
        {:error,
         Error.new(:unsupported_model, "Z.ai model is not supported", %{
           provider: :zai,
           model: model,
           expected: "zai:#{@default_model}"
         })}
    end
  end

  defp validate_thinking(%{"thinking" => thinking} = body, profile) do
    supported = profile_values(profile, :thinking_modes)

    case thinking do
      %{"type" => type} ->
        if supported == [] or type in supported,
          do: :ok,
          else: thinking_error(body, "Z.ai #{body["model"]} received unsupported thinking mode", supported)

      _missing_type ->
        thinking_error(body, "Z.ai thinking option must include a type", supported)
    end
  end

  defp validate_thinking(_body, _profile), do: :ok

  defp thinking_error(body, message, supported) do
    {:error,
     Error.new(:unsupported_model_param, message, %{
       provider: :zai,
       model: body["model"],
       param: :thinking,
       value: body["thinking"],
       supported: Enum.map(supported, &%{"type" => &1})
     })}
  end

  defp validate_reasoning_effort(%{"reasoning_effort" => effort} = body, profile) do
    supported = Enum.map(profile.reasoning_effort_levels, &to_string/1)

    if supported == [] or effort in supported do
      :ok
    else
      {:error,
       Error.new(:unsupported_model_param, "Z.ai #{body["model"]} received unsupported reasoning_effort", %{
         provider: :zai,
         model: body["model"],
         param: :reasoning_effort,
         value: effort,
         supported: supported
       })}
    end
  end

  defp validate_reasoning_effort(_body, _profile), do: :ok

  defp profile_values(profile, key), do: profile.extra |> Map.get(key, []) |> Enum.map(&to_string/1)

  defp validate_tool_stream(%{"tool_stream" => true, "stream" => true}), do: :ok

  defp validate_tool_stream(%{"tool_stream" => true} = body) do
    {:error,
     Error.new(:unsupported_model_param, "Z.ai tool_stream requires stream: true", %{
       provider: :zai,
       model: body["model"],
       param: :tool_stream,
       required: %{stream: true}
     })}
  end

  defp validate_tool_stream(_body), do: :ok

  defp validate_tool_choice(%{"tool_choice" => nil}), do: :ok
  defp validate_tool_choice(%{"tool_choice" => "auto"}), do: :ok

  defp validate_tool_choice(%{"tool_choice" => value} = body) do
    {:error,
     Error.new(:unsupported_model_param, "Z.ai currently supports only automatic tool choice", %{
       provider: :zai,
       model: body["model"],
       param: :tool_choice,
       value: value,
       supported: ["auto"]
     })}
  end

  defp validate_tool_choice(_body), do: :ok

  defp validate_stop(nil), do: :ok
  defp validate_stop(stop) when is_binary(stop), do: :ok

  defp validate_stop(stop) when is_list(stop) do
    if Enum.all?(stop, &is_binary/1) do
      :ok
    else
      stop_error(stop)
    end
  end

  defp validate_stop(stop), do: stop_error(stop)

  defp stop_error(stop) do
    {:error,
     Error.new(:invalid_request, "Z.ai stop sequences must be strings", %{
       provider: :zai,
       stop: inspect(stop)
     })}
  end

  defp max_tokens(model, opts) do
    option(model, opts, :max_tokens) ||
      option(model, opts, :max_output_tokens) ||
      option(model, opts, :max_completion_tokens)
  end

  # Deprecated OpenAI params these APIs reject even through `extra_body`.
  defp rejected_extra_body_keys(extra_body) do
    extra_body
    |> Map.keys()
    |> Enum.filter(&(&1 in ["functions", "function_call", "max_completion_tokens"]))
    |> Enum.map(fn
      "functions" -> :functions
      "function_call" -> :function_call
      "max_completion_tokens" -> :max_completion_tokens
    end)
  end
end
