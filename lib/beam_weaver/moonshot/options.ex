defmodule BeamWeaver.Moonshot.Options do
  @moduledoc false

  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Moonshot.Error
  alias BeamWeaver.Moonshot.Messages
  alias BeamWeaver.OpenAI.MessageParts

  @kimi_model_policies %{
    "kimi-k2.7-code" => %{thinking: :enabled_only},
    "kimi-k2.7-code-highspeed" => %{thinking: :enabled_only},
    "kimi-k2.6" => %{thinking: :toggle},
    "kimi-k2.5" => %{thinking: :toggle}
  }

  @spec to_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def to_body(model, messages, opts \\ []) do
    with :ok <- validate_profile_params(model, opts),
         {:ok, moonshot_messages} <- Messages.to_chat_messages(messages),
         {:ok, response_format} <- response_format(model, opts),
         :ok <- validate_partial_response_format(moonshot_messages, response_format),
         {:ok, body} <- build_body(model, moonshot_messages, response_format, opts),
         :ok <- validate_kimi_policy(body),
         :ok <- validate_stop(body["stop"]) do
      {:ok, body}
    end
  end

  defp build_body(model, messages, response_format, opts) do
    model_name = option(model, opts, :model)
    model_kwargs = option(model, opts, :model_kwargs) || %{}

    body =
      %{
        "model" => model_name,
        "messages" => messages
      }
      |> merge_model_kwargs(model_kwargs)
      |> put_optional("tool_choice", normalize_value(option(model, opts, :tool_choice)))
      |> put_optional("response_format", response_format)
      |> put_optional("thinking", normalize_value(option(model, opts, :thinking)))
      |> put_optional("temperature", option(model, opts, :temperature))
      |> put_optional("max_completion_tokens", max_completion_tokens(model, opts))
      |> put_optional("top_p", option(model, opts, :top_p))
      |> put_optional("frequency_penalty", option(model, opts, :frequency_penalty))
      |> put_optional("presence_penalty", option(model, opts, :presence_penalty))
      |> put_optional("n", option(model, opts, :n))
      |> put_optional("stop", Keyword.get(opts, :stop))
      |> put_optional("stream", Keyword.get(opts, :stream, false))
      |> put_optional("stream_options", normalize_map(Keyword.get(opts, :stream_options)))
      |> put_optional("prompt_cache_key", option(model, opts, :prompt_cache_key))
      |> put_optional("safety_identifier", option(model, opts, :safety_identifier))

    case rejected_model_kwargs(model_kwargs) do
      [] ->
        {:ok, body}

      keys ->
        {:error,
         Error.new(
           :unsupported_model_param,
           "Moonshot does not support deprecated OpenAI params",
           %{
             provider: :moonshot,
             model: model_name,
             params: keys
           }
         )}
    end
  end

  defp response_format(model, opts) do
    case option(model, opts, :response_format) || option(model, opts, :structured_output) do
      nil ->
        {:ok, nil}

      %{"type" => _type} = format ->
        {:ok, format}

      %{type: type} = format when is_binary(type) ->
        {:ok, MessageParts.stringify_keys(format)}

      %{type: type} = format when is_atom(type) ->
        {:ok, format |> Map.put(:type, Atom.to_string(type)) |> MessageParts.stringify_keys()}

      %{name: name, schema: schema} = format when is_binary(name) and is_map(schema) ->
        {:ok, Messages.structured_output_format(name, schema, strict: Map.get(format, :strict, true))}

      %{"name" => name, "schema" => schema} = format when is_binary(name) and is_map(schema) ->
        {:ok, Messages.structured_output_format(name, schema, strict: Map.get(format, "strict", true))}

      {name, schema} when is_binary(name) and is_map(schema) ->
        {:ok, Messages.structured_output_format(name, schema)}

      other ->
        {:error,
         Error.new(:invalid_response_format, "structured output requires a name and schema", %{
           response_format: inspect(other)
         })}
    end
  end

  defp validate_profile_params(model, opts) do
    params =
      model
      |> Map.from_struct()
      |> Map.take([
        :frequency_penalty,
        :max_completion_tokens,
        :max_output_tokens,
        :max_tokens,
        :model_kwargs,
        :n,
        :presence_penalty,
        :prompt_cache_key,
        :response_format,
        :safety_identifier,
        :stream_usage,
        :structured_output,
        :temperature,
        :thinking,
        :tool_choice,
        :top_p
      ])
      |> Map.merge(Map.new(Keyword.drop(opts, [:metadata])))

    ParamPolicy.validate(
      Map.get(model, :profile),
      params,
      Keyword.get(opts, :param_policy, Map.get(model, :param_policy)),
      api: :chat_completions,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp validate_partial_response_format(messages, %{"type" => "json_object"}) do
    if Enum.any?(messages, &(&1["role"] == "assistant" and &1["partial"] == true)) do
      {:error,
       Error.new(
         :invalid_request,
         "Moonshot partial mode cannot be combined with JSON object mode",
         %{
           provider: :moonshot,
           feature: :partial
         }
       )}
    else
      :ok
    end
  end

  defp validate_partial_response_format(_messages, _response_format), do: :ok

  defp validate_kimi_policy(%{"model" => model_name} = body) do
    case Map.fetch(@kimi_model_policies, model_name) do
      {:ok, policy} ->
        with :ok <- validate_kimi_thinking(body, policy),
             :ok <- validate_kimi_tool_choice(body, policy) do
          validate_kimi_sampling(body, policy)
        end

      :error ->
        :ok
    end
  end

  defp validate_kimi_policy(_body), do: :ok

  defp validate_kimi_thinking(%{"model" => model_name} = body, %{thinking: :enabled_only}) do
    case get_in(body, ["thinking", "type"]) do
      nil ->
        :ok

      "enabled" ->
        :ok

      value ->
        {:error,
         Error.new(:unsupported_model_param, "Moonshot Kimi model requires thinking mode", %{
           provider: :moonshot,
           model: model_name,
           param: :thinking,
           value: %{"type" => value},
           supported: [%{"type" => "enabled"}]
         })}
    end
  end

  defp validate_kimi_thinking(%{"model" => model_name} = body, %{thinking: :toggle}) do
    case get_in(body, ["thinking", "type"]) do
      nil ->
        :ok

      value when value in ["enabled", "disabled"] ->
        :ok

      value ->
        {:error,
         Error.new(:unsupported_model_param, "Moonshot Kimi model received unsupported thinking mode", %{
           provider: :moonshot,
           model: model_name,
           param: :thinking,
           value: %{"type" => value},
           supported: [%{"type" => "enabled"}, %{"type" => "disabled"}]
         })}
    end
  end

  defp validate_kimi_tool_choice(%{"model" => model_name} = body, _policy) do
    thinking_type = get_in(body, ["thinking", "type"]) || "enabled"
    tool_choice = Map.get(body, "tool_choice")

    if thinking_type == "disabled" or tool_choice in [nil, "auto", "none"] do
      :ok
    else
      {:error,
       Error.new(
         :unsupported_model_param,
         "Moonshot Kimi thinking mode supports only automatic tool choice",
         %{
           provider: :moonshot,
           model: model_name,
           param: :tool_choice,
           value: tool_choice,
           supported: ["auto", "none"],
           when_thinking: "enabled"
         }
       )}
    end
  end

  defp validate_kimi_sampling(%{"model" => model_name} = body, policy) do
    thinking_type = get_in(body, ["thinking", "type"]) || "enabled"

    expected_temperature =
      if policy.thinking == :toggle and thinking_type == "disabled" do
        0.6
      else
        1.0
      end

    with :ok <- validate_fixed_number(body, "temperature", expected_temperature, model_name),
         :ok <- validate_fixed_number(body, "top_p", 0.95, model_name),
         :ok <- validate_fixed_number(body, "n", 1, model_name),
         :ok <- validate_fixed_number(body, "presence_penalty", 0, model_name) do
      validate_fixed_number(body, "frequency_penalty", 0, model_name)
    end
  end

  defp validate_fixed_number(body, key, expected, model_name) do
    case Map.get(body, key) do
      nil ->
        :ok

      value when is_number(value) ->
        if abs(value * 1.0 - expected * 1.0) < 1.0e-9 do
          :ok
        else
          fixed_number_error(key, value, expected, model_name)
        end

      value ->
        fixed_number_error(key, value, expected, model_name)
    end
  end

  defp fixed_number_error(key, value, expected, model_name) do
    {:error,
     Error.new(:unsupported_model_param, "Moonshot Kimi model uses fixed sampling params", %{
       provider: :moonshot,
       model: model_name,
       param: fixed_param(key),
       value: value,
       supported: expected
     })}
  end

  defp fixed_param("temperature"), do: :temperature
  defp fixed_param("top_p"), do: :top_p
  defp fixed_param("top_k"), do: :top_k
  defp fixed_param(key), do: key

  defp validate_stop(nil), do: :ok

  defp validate_stop(stop) when is_binary(stop) do
    if byte_size(stop) <= 32 do
      :ok
    else
      stop_error(stop)
    end
  end

  defp validate_stop(stop) when is_list(stop) do
    if length(stop) > 5 do
      {:error,
       Error.new(:invalid_request, "Moonshot stop supports at most 5 sequences", %{
         provider: :moonshot,
         count: length(stop),
         max: 5
       })}
    else
      Enum.reduce_while(stop, :ok, fn sequence, :ok ->
        case validate_stop(sequence) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp validate_stop(stop), do: stop_error(stop)

  defp stop_error(stop) do
    {:error,
     Error.new(:invalid_request, "Moonshot stop sequences must be strings of at most 32 bytes", %{
       provider: :moonshot,
       stop: inspect(stop)
     })}
  end

  defp max_completion_tokens(model, opts) do
    option(model, opts, :max_completion_tokens) ||
      option(model, opts, :max_output_tokens) ||
      option(model, opts, :max_tokens)
  end

  defp option(model, opts, key), do: Keyword.get(opts, key, Map.get(model, key))

  defp normalize_map(nil), do: nil
  defp normalize_map(value) when is_map(value), do: MessageParts.stringify_keys(value)

  defp normalize_value(nil), do: nil
  defp normalize_value(value) when is_map(value), do: MessageParts.stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value

  defp merge_model_kwargs(body, model_kwargs) when map_size(model_kwargs) == 0, do: body

  defp merge_model_kwargs(body, model_kwargs) when is_map(model_kwargs),
    do: Map.merge(body, MessageParts.stringify_keys(model_kwargs))

  defp rejected_model_kwargs(model_kwargs) when is_map(model_kwargs) do
    model_kwargs
    |> MessageParts.stringify_keys()
    |> Map.keys()
    |> Enum.filter(&(&1 in ["functions", "function_call"]))
    |> Enum.map(fn
      "functions" -> :functions
      "function_call" -> :function_call
    end)
  end

  defp put_optional(body, _key, nil), do: body
  defp put_optional(body, _key, []), do: body
  defp put_optional(body, key, value), do: Map.put(body, key, value)
end
