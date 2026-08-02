defmodule BeamWeaver.DeepSeek.Client.ResponseDecoder do
  @moduledoc false

  alias BeamWeaver.Core.Error, as: CoreError
  alias BeamWeaver.DeepSeek.Error
  alias BeamWeaver.Provider.ResponseDecoder, as: ProviderResponseDecoder
  alias BeamWeaver.Transport.Response

  @doc false
  def json({:ok, %Response{} = response} = result, opts) do
    result
    |> ProviderResponseDecoder.json(decoder_opts(opts))
    |> attach_result_headers(response, opts)
    |> normalize_error()
  end

  def json(result, opts) do
    result
    |> ProviderResponseDecoder.json(decoder_opts(opts))
    |> normalize_error()
  end

  @doc false
  def stream_error({:ok, %Response{} = response}, opts) do
    {:error, normalize_http_error(response, opts)}
  end

  def stream_error({:error, error}, opts) do
    {:error, ProviderResponseDecoder.transport_error(error, decoder_opts(opts))}
  end

  @doc false
  def chat_completions_stream_response(
        {:ok, %Response{status: status, body: body} = response},
        opts
      )
      when status in 200..299 do
    case chat_completion_response(body) do
      {:ok, decoded} ->
        {:ok, attach_headers(decoded, response, opts)}

      {:error, error} ->
        {:error,
         Error.new(
           Map.get(error, :type, :invalid_response),
           Map.get(error, :message, "DeepSeek chat-completions stream was invalid"),
           Map.get(error, :details, %{})
         )}
    end
  end

  def chat_completions_stream_response({:ok, %Response{} = response}, opts) do
    {:error, normalize_http_error(response, opts)}
  end

  def chat_completions_stream_response({:error, error}, opts) do
    {:error, ProviderResponseDecoder.transport_error(error, decoder_opts(opts))}
  end

  @doc false
  def responses_stream_response(
        {:ok, %Response{status: status, body: body} = response},
        opts
      )
      when status in 200..299 do
    decoded = BeamWeaver.OpenAI.Streaming.response(body)
    {:ok, attach_headers(decoded, response, opts)}
  end

  def responses_stream_response({:ok, %Response{} = response}, opts) do
    {:error, normalize_http_error(response, opts)}
  end

  def responses_stream_response({:error, error}, opts) do
    {:error, ProviderResponseDecoder.transport_error(error, decoder_opts(opts))}
  end

  @doc false
  def completions_stream_response(
        {:ok, %Response{status: status, body: body} = response},
        opts
      )
      when status in 200..299 do
    decoded = completion_response(body)
    {:ok, attach_headers(decoded, response, opts)}
  end

  def completions_stream_response({:ok, %Response{} = response}, opts) do
    {:error, normalize_http_error(response, opts)}
  end

  def completions_stream_response({:error, error}, opts) do
    {:error, ProviderResponseDecoder.transport_error(error, decoder_opts(opts))}
  end

  @doc false
  def anthropic_stream_response(
        {:ok, %Response{status: status, body: body} = response},
        opts
      )
      when status in 200..299 do
    decoded = BeamWeaver.Anthropic.Streaming.response(body)
    {:ok, attach_headers(decoded, response, opts)}
  end

  def anthropic_stream_response({:ok, %Response{} = response}, opts) do
    {:error, normalize_http_error(response, opts)}
  end

  def anthropic_stream_response({:error, error}, opts) do
    {:error, ProviderResponseDecoder.transport_error(error, decoder_opts(opts))}
  end

  defp chat_completion_response(body) do
    state =
      body
      |> BeamWeaver.Provider.SSE.events()
      |> Enum.reduce(%{response: %{}, choices: %{}}, &apply_chat_event/2)

    if map_size(state.choices) == 0 do
      {:error, Error.new(:invalid_response, "DeepSeek chat-completions stream had no choices")}
    else
      {:ok, finalize_chat_response(state)}
    end
  end

  defp apply_chat_event(%{"data" => data}, state) when is_map(data) do
    response = put_response_fields(state.response, data)

    choices =
      data
      |> Map.get("choices", [])
      |> Enum.reduce(state.choices, &apply_chat_choice/2)

    %{state | response: response, choices: choices}
  end

  defp apply_chat_event(_event, state), do: state

  defp apply_chat_choice(choice, choices) when is_map(choice) do
    index = choice["index"] || 0
    current = Map.get(choices, index, initial_chat_choice(index))
    delta = choice["delta"] || %{}

    current =
      current
      |> update_in([:message], &apply_chat_delta(&1, delta))
      |> update_in([:tool_calls], &apply_chat_tool_calls(&1, delta["tool_calls"]))
      |> Map.put(:finish_reason, choice["finish_reason"] || current.finish_reason)
      |> Map.put(:logprobs, merge_logprobs(current.logprobs, choice["logprobs"]))

    Map.put(choices, index, current)
  end

  defp apply_chat_choice(_choice, choices), do: choices

  defp initial_chat_choice(index) do
    %{index: index, message: %{}, tool_calls: %{}, finish_reason: nil, logprobs: nil}
  end

  defp apply_chat_delta(message, delta) when is_map(delta) do
    message
    |> put_present("role", delta["role"])
    |> append_string("content", delta["content"])
    |> append_string("reasoning_content", delta["reasoning_content"])
  end

  defp apply_chat_delta(message, _delta), do: message

  defp apply_chat_tool_calls(tool_calls, calls) when is_list(calls) do
    Enum.reduce(calls, tool_calls, fn call, acc ->
      index = call["index"] || 0
      current = Map.get(acc, index, %{"index" => index, "function" => %{}})
      function = call["function"] || %{}

      current =
        current
        |> put_present("id", call["id"])
        |> put_present("type", call["type"])
        |> update_in(["function"], fn current_function ->
          (current_function || %{})
          |> put_present("name", function["name"])
          |> append_string("arguments", function["arguments"])
        end)

      Map.put(acc, index, current)
    end)
  end

  defp apply_chat_tool_calls(tool_calls, _calls), do: tool_calls

  defp finalize_chat_response(%{response: response, choices: choices}) do
    Map.put(
      response,
      "choices",
      choices
      |> Enum.sort_by(fn {index, _choice} -> index end)
      |> Enum.map(fn {_index, choice} -> finalize_chat_choice(choice) end)
    )
  end

  defp finalize_chat_choice(choice) do
    message = Map.put_new(choice.message, "role", "assistant")

    message =
      if map_size(choice.tool_calls) == 0 do
        message
      else
        tool_calls =
          choice.tool_calls
          |> Enum.sort_by(fn {index, _call} -> index end)
          |> Enum.map(fn {_index, call} -> Map.delete(call, "index") end)

        Map.put(message, "tool_calls", tool_calls)
      end

    %{
      "index" => choice.index,
      "message" => message,
      "finish_reason" => choice.finish_reason,
      "logprobs" => choice.logprobs
    }
    |> reject_nil_values()
  end

  defp completion_response(body) do
    body
    |> BeamWeaver.Provider.SSE.events()
    |> Enum.reduce(%{response: %{}, choices: %{}}, &apply_completion_event/2)
    |> finalize_completion_response()
  end

  defp apply_completion_event(%{"data" => data}, state) when is_map(data) do
    response = put_response_fields(state.response, data)

    choices =
      data
      |> Map.get("choices", [])
      |> Enum.reduce(state.choices, &apply_completion_choice/2)

    %{state | response: response, choices: choices}
  end

  defp apply_completion_event(_event, state), do: state

  defp apply_completion_choice(choice, choices) when is_map(choice) do
    index = choice["index"] || 0

    Map.update(choices, index, normalize_completion_choice(choice), fn current ->
      current
      |> Map.update("text", choice["text"] || "", &(&1 <> (choice["text"] || "")))
      |> put_present("finish_reason", choice["finish_reason"])
      |> put_merged_logprobs(choice["logprobs"])
    end)
  end

  defp apply_completion_choice(_choice, choices), do: choices

  defp normalize_completion_choice(choice) do
    %{
      "index" => choice["index"] || 0,
      "text" => choice["text"] || "",
      "finish_reason" => choice["finish_reason"],
      "logprobs" => choice["logprobs"]
    }
    |> reject_nil_values()
  end

  defp finalize_completion_response(%{response: response, choices: choices}) do
    Map.put(
      response,
      "choices",
      choices
      |> Enum.sort_by(fn {index, _choice} -> index end)
      |> Enum.map(fn {_index, choice} -> choice end)
    )
  end

  defp put_response_fields(response, data) do
    response
    |> put_present("id", data["id"])
    |> put_present("object", data["object"])
    |> put_present("created", data["created"])
    |> put_present("model", data["model"])
    |> put_present("system_fingerprint", data["system_fingerprint"])
    |> put_present("service_tier", data["service_tier"])
    |> put_present("usage", data["usage"])
  end

  defp put_merged_logprobs(choice, nil), do: choice

  defp put_merged_logprobs(choice, incoming) do
    Map.update(choice, "logprobs", incoming, &merge_logprobs(&1, incoming))
  end

  defp merge_logprobs(current, nil), do: current
  defp merge_logprobs(nil, incoming), do: incoming

  defp merge_logprobs(current, incoming) when is_map(current) and is_map(incoming) do
    Map.merge(current, incoming, fn _key, left, right -> merge_logprob_value(left, right) end)
  end

  defp merge_logprobs(_current, incoming), do: incoming

  defp merge_logprob_value(left, right) when is_list(left) and is_list(right), do: left ++ right

  defp merge_logprob_value(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, nested_left, nested_right ->
      merge_logprob_value(nested_left, nested_right)
    end)
  end

  defp merge_logprob_value(_left, right), do: right

  defp append_string(map, _key, nil), do: map

  defp append_string(map, key, value) when is_binary(value) do
    Map.update(map, key, value, &(&1 <> value))
  end

  defp append_string(map, _key, _value), do: map

  defp attach_result_headers({:ok, decoded}, %Response{} = response, opts)
       when is_map(decoded) do
    {:ok, attach_headers(decoded, response, opts)}
  end

  defp attach_result_headers(result, _response, _opts), do: result

  defp attach_headers(decoded, %Response{headers: headers}, opts) when is_map(decoded) do
    decoded = attach_header_metadata(decoded, headers)

    if Keyword.get(opts, :include_response_headers, false) do
      decoded
      |> Map.put("_beamweaver_response_headers", Map.new(headers))
      |> Map.put(
        "_beamweaver_response_header_list",
        Enum.map(headers, fn {name, value} -> [name, value] end)
      )
    else
      decoded
    end
  end

  defp attach_header_metadata(decoded, headers) do
    metadata = header_metadata(headers)

    if map_size(metadata) > 0 do
      Map.put(decoded, "_beamweaver_response_header_metadata", metadata)
    else
      decoded
    end
  end

  defp header_metadata(headers) do
    trace_id = headers |> normalized_headers() |> Map.get("x-ds-trace-id")

    %{
      headers: reject_empty_values(%{x_ds_trace_id: trace_id}),
      request_id: trace_id
    }
    |> reject_empty_values()
  end

  defp normalized_headers(headers) when is_list(headers) do
    Map.new(headers, fn {name, value} -> {name |> to_string() |> String.downcase(), value} end)
  rescue
    _error -> %{}
  end

  defp normalized_headers(_headers), do: %{}

  defp normalize_http_error(response, opts) do
    response
    |> ProviderResponseDecoder.http_error(decoder_opts(opts))
    |> normalize_error_value()
  end

  defp normalize_error({:error, %Error{} = error}), do: {:error, normalize_error_value(error)}
  defp normalize_error({:error, %CoreError{} = error}), do: {:error, normalize_error_value(error)}
  defp normalize_error(other), do: other

  defp normalize_error_value(%{type: :context_overflow} = error), do: error

  defp normalize_error_value(%{type: :http_error, details: details} = error) do
    provider_error = details[:error] || details["error"] || %{}
    status = details[:status] || details["status"]
    code = error_field(provider_error, "code") || details[:code] || details["code"]
    error_type = error_field(provider_error, "type") || details[:error_type] || details["error_type"]

    type =
      cond do
        status == 401 -> :authentication_error
        insufficient_balance?(status, code, error_type, error.message) -> :quota_error
        status == 429 -> :rate_limit_error
        status == 503 -> :overloaded_error
        status in [400, 422] -> :invalid_request_error
        status in [500, 502, 504] -> :server_error
        true -> :http_error
      end

    %{error | type: type, details: normalize_retryable_details(details, type)}
  end

  defp normalize_error_value(error), do: error

  defp insufficient_balance?(status, code, error_type, message) do
    status == 402 or
      code in ["insufficient_balance", "insufficient_quota", "quota_exceeded"] or
      error_type in ["insufficient_balance", "insufficient_quota", "quota_exceeded"] or
      insufficient_balance_message?(message)
  end

  defp insufficient_balance_message?(message) when is_binary(message) do
    normalized = String.downcase(message)

    String.contains?(normalized, "insufficient balance") or
      String.contains?(normalized, "insufficient quota") or
      String.contains?(normalized, "quota exceeded")
  end

  defp insufficient_balance_message?(_message), do: false

  defp normalize_retryable_details(details, type)
       when type in [:authentication_error, :quota_error, :invalid_request_error] and is_map(details) do
    Map.put(details, :retryable, false)
  end

  defp normalize_retryable_details(details, _type), do: details

  defp decoder_opts(opts) do
    [
      provider: :deepseek,
      provider_name: "DeepSeek",
      error_module: Error,
      include_response_headers: Keyword.get(opts, :include_response_headers, false),
      request_id_header: "x-ds-trace-id",
      context_overflow?: &context_overflow?/3
    ]
  end

  defp context_overflow?(400, provider_error, message) when is_binary(message) do
    code = error_field(provider_error, "code")
    normalized = String.downcase(message)

    code in ["context_length_exceeded", "prompt_too_long"] or
      String.contains?(normalized, "context length") or
      String.contains?(normalized, "context window") or
      String.contains?(normalized, "maximum context") or
      String.contains?(normalized, "input tokens exceed") or
      String.contains?(normalized, "too many tokens")
  end

  defp context_overflow?(_status, _provider_error, _message), do: false

  defp error_field(%{} = error, field), do: BeamWeaver.MapAccess.get(error, field)
  defp error_field(_error, _field), do: nil

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp reject_empty_values(map) do
    Map.reject(map, fn
      {_key, value} when value in [nil, ""] -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      _entry -> false
    end)
  end
end
