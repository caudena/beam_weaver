defmodule BeamWeaver.ZAI.Options do
  @moduledoc false

  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.ZAI.Error
  alias BeamWeaver.ZAI.Messages

  @model "glm-5.2"
  @reasoning_efforts ["max", "xhigh", "high", "medium", "low", "minimal", "none"]

  @spec to_body(term(), [BeamWeaver.Core.Message.t()], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def to_body(model, messages, opts \\ []) do
    with :ok <- validate_profile_params(model, opts),
         {:ok, zai_messages} <- Messages.to_chat_messages(messages),
         {:ok, response_format} <- response_format(model, opts),
         {:ok, body} <- build_body(model, zai_messages, response_format, opts),
         :ok <- validate_model(body),
         :ok <- validate_thinking(body),
         :ok <- validate_reasoning_effort(body),
         :ok <- validate_tool_stream(body),
         :ok <- validate_tool_choice(body),
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
      |> put_optional("do_sample", option(model, opts, :do_sample))
      |> put_optional("temperature", option(model, opts, :temperature))
      |> put_optional("top_p", option(model, opts, :top_p))
      |> put_optional("max_tokens", max_tokens(model, opts))
      |> put_optional("stop", Keyword.get(opts, :stop))
      |> put_optional("stream", Keyword.get(opts, :stream, false))
      |> put_optional("stream_options", normalize_map(Keyword.get(opts, :stream_options)))
      |> put_optional("tool_stream", option(model, opts, :tool_stream))
      |> put_optional("thinking", normalize_value(option(model, opts, :thinking)))
      |> put_optional("reasoning_effort", normalize_value(option(model, opts, :reasoning_effort)))
      |> put_optional("response_format", response_format)
      |> put_optional("tool_choice", normalize_value(option(model, opts, :tool_choice)))
      |> put_optional("request_id", option(model, opts, :request_id))
      |> put_optional("user_id", option(model, opts, :user_id))

    case rejected_model_kwargs(model_kwargs) do
      [] ->
        {:ok, body}

      keys ->
        {:error,
         Error.new(:unsupported_model_param, "Z.ai GLM-5.2 does not support deprecated OpenAI params", %{
           provider: :zai,
           model: model_name,
           params: keys
         })}
    end
  end

  defp response_format(model, opts) do
    case option(model, opts, :response_format) || option(model, opts, :structured_output) do
      nil ->
        {:ok, nil}

      %{"type" => "json_object"} ->
        {:ok, %{"type" => "json_object"}}

      %{type: type} when type in [:json_object, "json_object"] ->
        {:ok, %{"type" => "json_object"}}

      %{name: name, schema: schema} when is_binary(name) and is_map(schema) ->
        {:ok, %{"type" => "json_object"}}

      %{"name" => name, "schema" => schema} when is_binary(name) and is_map(schema) ->
        {:ok, %{"type" => "json_object"}}

      {name, schema} when is_binary(name) and is_map(schema) ->
        {:ok, %{"type" => "json_object"}}

      other ->
        {:error,
         Error.new(:invalid_response_format, "Z.ai GLM-5.2 supports JSON object response_format only", %{
           response_format: inspect(other),
           supported: [%{"type" => "json_object"}]
         })}
    end
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
        :model_kwargs,
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
      |> Map.merge(Map.new(Keyword.drop(opts, [:metadata])))

    ParamPolicy.validate(
      Map.get(model, :profile),
      params,
      Keyword.get(opts, :param_policy, Map.get(model, :param_policy)),
      api: :chat_completions,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp validate_model(%{"model" => @model}), do: :ok

  defp validate_model(%{"model" => model}) do
    {:error,
     Error.new(:unsupported_model, "Z.ai provider currently supports only GLM-5.2", %{
       provider: :zai,
       model: model,
       supported: [@model],
       expected: "zai:#{@model}"
     })}
  end

  defp validate_thinking(%{"thinking" => %{"type" => type}} = body)
       when type in ["enabled", "disabled"] do
    if type == "disabled" and body["reasoning_effort"] in [nil, "none"] do
      :ok
    else
      :ok
    end
  end

  defp validate_thinking(%{"thinking" => %{"type" => type}}) do
    {:error,
     Error.new(:unsupported_model_param, "Z.ai GLM-5.2 received unsupported thinking mode", %{
       provider: :zai,
       model: @model,
       param: :thinking,
       value: %{"type" => type},
       supported: [%{"type" => "enabled"}, %{"type" => "disabled"}]
     })}
  end

  defp validate_thinking(%{"thinking" => value}) do
    {:error,
     Error.new(:unsupported_model_param, "Z.ai GLM-5.2 thinking option must include a type", %{
       provider: :zai,
       model: @model,
       param: :thinking,
       value: value,
       supported: [%{"type" => "enabled"}, %{"type" => "disabled"}]
     })}
  end

  defp validate_thinking(_body), do: :ok

  defp validate_reasoning_effort(%{"reasoning_effort" => effort}) when effort in @reasoning_efforts,
    do: :ok

  defp validate_reasoning_effort(%{"reasoning_effort" => effort}) do
    {:error,
     Error.new(:unsupported_model_param, "Z.ai GLM-5.2 received unsupported reasoning_effort", %{
       provider: :zai,
       model: @model,
       param: :reasoning_effort,
       value: effort,
       supported: @reasoning_efforts
     })}
  end

  defp validate_reasoning_effort(_body), do: :ok

  defp validate_tool_stream(%{"tool_stream" => true, "stream" => true}), do: :ok

  defp validate_tool_stream(%{"tool_stream" => true}) do
    {:error,
     Error.new(:unsupported_model_param, "Z.ai tool_stream requires stream: true", %{
       provider: :zai,
       model: @model,
       param: :tool_stream,
       required: %{stream: true}
     })}
  end

  defp validate_tool_stream(_body), do: :ok

  defp validate_tool_choice(%{"tool_choice" => nil}), do: :ok
  defp validate_tool_choice(%{"tool_choice" => "auto"}), do: :ok

  defp validate_tool_choice(%{"tool_choice" => value}) do
    {:error,
     Error.new(:unsupported_model_param, "Z.ai GLM-5.2 currently supports only automatic tool choice", %{
       provider: :zai,
       model: @model,
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
    |> Enum.filter(&(&1 in ["functions", "function_call", "max_completion_tokens"]))
    |> Enum.map(fn
      "functions" -> :functions
      "function_call" -> :function_call
      "max_completion_tokens" -> :max_completion_tokens
    end)
  end

  defp put_optional(body, _key, nil), do: body
  defp put_optional(body, _key, []), do: body
  defp put_optional(body, key, value), do: Map.put(body, key, value)
end
