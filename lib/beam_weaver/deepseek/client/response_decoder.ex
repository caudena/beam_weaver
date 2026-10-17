defmodule BeamWeaver.DeepSeek.Client.ResponseDecoder do
  @moduledoc false

  import BeamWeaver.MapShape, only: [reject_nil_values: 1]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.ResponseDecoder, as: ProviderResponseDecoder
  alias BeamWeaver.Transport.Response

  @header_fields [x_ds_trace_id: "x-ds-trace-id"]

  @doc false
  def json(result, opts) do
    with {:ok, decoded} <- ProviderResponseDecoder.json(result, decoder_opts(opts)) do
      {:ok, attach_result_headers(decoded, result, opts)}
    end
  end

  @doc false
  def stream_error({:ok, %Response{} = response}, opts),
    do: {:error, ProviderResponseDecoder.http_error(response, decoder_opts(opts))}

  def stream_error({:error, error}, opts),
    do: {:error, ProviderResponseDecoder.transport_error(error, decoder_opts(opts))}

  @doc false
  def chat_completions_stream_response(result, opts) do
    ProviderResponseDecoder.decode(result, decoder_opts(opts), fn response ->
      with {:ok, decoded} <- chat_completion_response(response.body) do
        {:ok, attach_headers(decoded, response, opts)}
      end
    end)
  end

  @doc false
  def responses_stream_response(result, opts) do
    ProviderResponseDecoder.decode(result, decoder_opts(opts), fn response ->
      {:ok, response.body |> BeamWeaver.OpenAI.Streaming.response() |> attach_headers(response, opts)}
    end)
  end

  @doc false
  def completions_stream_response(result, opts) do
    ProviderResponseDecoder.decode(result, decoder_opts(opts), fn response ->
      {:ok, response.body |> completion_response() |> attach_headers(response, opts)}
    end)
  end

  @doc false
  def anthropic_stream_response(result, opts) do
    ProviderResponseDecoder.decode(result, decoder_opts(opts), fn response ->
      {:ok, response.body |> BeamWeaver.Anthropic.Streaming.response() |> attach_headers(response, opts)}
    end)
  end

  defp chat_completion_response(body) do
    body
    |> BeamWeaver.Provider.SSE.events()
    |> reduce_chat_events(nil)
    |> chat_stream_response()
  end

  @doc false
  def reduce_chat_events(events, state) do
    Enum.reduce(events, state || %{response: %{}, choices: %{}}, &apply_chat_event/2)
  end

  @doc false
  def chat_stream_response(state) do
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

  defp attach_result_headers(decoded, {:ok, %Response{} = response}, opts), do: attach_headers(decoded, response, opts)

  defp attach_headers(decoded, %Response{headers: headers}, opts) when is_map(decoded) do
    decoded =
      ProviderResponseDecoder.attach_header_metadata(
        decoded,
        ProviderResponseDecoder.header_metadata(headers, @header_fields, request_id: :x_ds_trace_id)
      )

    if Keyword.get(opts, :include_response_headers, false) do
      decoded
      |> Map.put("_beamweaver_response_headers", Map.new(headers))
      |> Map.put("_beamweaver_response_header_list", Enum.map(headers, fn {name, value} -> [name, value] end))
    else
      decoded
    end
  end

  defp decoder_opts(opts) do
    [
      provider: :deepseek,
      provider_name: "DeepSeek",
      include_response_headers: Keyword.get(opts, :include_response_headers, false),
      request_id_header: "x-ds-trace-id",
      context_overflow?: &context_overflow?/3,
      error_type: &error_type/3
    ]
  end

  # DeepSeek's balance runs out with a 402, or with a code or message that
  # says so. Its other errors follow their HTTP status.
  @balance_codes ["insufficient_balance", "insufficient_quota", "quota_exceeded"]

  defp error_type(_status, provider_error, message) do
    code = ProviderResponseDecoder.error_field(provider_error, "code")
    type = ProviderResponseDecoder.error_field(provider_error, "type")

    if code in @balance_codes or type in @balance_codes or
         String.contains?(String.downcase(message), ["insufficient balance", "insufficient quota", "quota exceeded"]) do
      :billing_exhausted
    end
  end

  defp context_overflow?(400, provider_error, message) when is_binary(message) do
    code = ProviderResponseDecoder.error_field(provider_error, "code")

    code in ["context_length_exceeded", "prompt_too_long"] or
      String.contains?(String.downcase(message), [
        "context length",
        "context window",
        "maximum context",
        "input tokens exceed",
        "too many tokens"
      ])
  end

  defp context_overflow?(_status, _provider_error, _message), do: false

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
