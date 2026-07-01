defmodule BeamWeaver.OpenAI.Client.ResponseDecoder do
  @moduledoc false

  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.OpenAI.Streaming
  alias BeamWeaver.Provider.ResponseDecoder, as: ProviderResponseDecoder
  alias BeamWeaver.Transport.Response

  def json({:ok, %Response{} = response} = result, opts) do
    with {:ok, decoded} <- ProviderResponseDecoder.json(result, decoder_opts(opts)) do
      {:ok, attach_header_metadata(decoded, response.headers)}
    end
  end

  def json(result, opts), do: ProviderResponseDecoder.json(result, decoder_opts(opts))

  def text_stream({:ok, %Response{status: status, body: body}})
      when status in 200..299 do
    {:ok, Streaming.text_deltas(body)}
  end

  def text_stream({:ok, %Response{} = response}) do
    {:error, http_error(response)}
  end

  def text_stream({:error, error}) do
    {:error, transport_error(error)}
  end

  def responses_stream_map({:ok, %Response{status: status, body: body} = response}, opts)
      when status in 200..299 do
    {:ok, body |> Streaming.response() |> maybe_attach_response_headers(response, opts)}
  end

  def responses_stream_map({:ok, %Response{} = response}, _opts) do
    {:error, http_error(response)}
  end

  def responses_stream_map({:error, error}, _opts) do
    {:error, transport_error(error)}
  end

  def lifecycle_events({:ok, %Response{status: status, body: body}})
      when status in 200..299 do
    {:ok, Streaming.lifecycle_events(body)}
  end

  def lifecycle_events({:ok, %Response{} = response}) do
    {:error, http_error(response)}
  end

  def lifecycle_events({:error, error}) do
    {:error, transport_error(error)}
  end

  def typed_events({:ok, %Response{status: status, body: body}})
      when status in 200..299 do
    {:ok, Streaming.typed_events(body)}
  end

  def typed_events({:ok, %Response{} = response}) do
    {:error, http_error(response)}
  end

  def typed_events({:error, error}) do
    {:error, transport_error(error)}
  end

  def chat_completions_stream_response(
        {:ok, %Response{status: status, body: body} = response},
        opts
      )
      when status in 200..299 do
    with {:ok, message} <- ChatCompletions.Messages.stream_body_to_message(body) do
      metadata = message.response_metadata
      usage = metadata[:token_usage] || chat_completion_usage(message.usage_metadata)

      {:ok,
       %{
         "id" => message.id || metadata[:id],
         "model" => metadata[:model],
         "system_fingerprint" => metadata[:system_fingerprint],
         "service_tier" => metadata[:service_tier],
         "choices" => [
           %{
             "message" => %{
               "role" => "assistant",
               "content" => BeamWeaver.Core.Message.text(message),
               "tool_calls" => chat_completion_tool_calls(message.tool_calls)
             },
             "finish_reason" => message.status,
             "logprobs" => metadata[:logprobs]
           }
         ],
         "usage" => usage
       }
       |> reject_nil_values()
       |> maybe_attach_response_headers(response, opts)}
    end
  end

  def chat_completions_stream_response({:ok, %Response{} = response}, _opts) do
    {:error, http_error(response)}
  end

  def chat_completions_stream_response({:error, error}, _opts) do
    {:error, transport_error(error)}
  end

  defp decoder_opts(opts \\ []) do
    [
      provider: :openai,
      provider_name: "OpenAI",
      error_module: Error,
      include_response_headers: Keyword.get(opts, :include_response_headers, false),
      context_overflow?: &context_overflow?/3
    ]
  end

  defp maybe_attach_response_headers(decoded, %Response{} = response, opts) do
    decoded = attach_header_metadata(decoded, response.headers)

    if Keyword.get(opts, :include_response_headers, false),
      do: Map.put(decoded, "_beamweaver_response_headers", Map.new(response.headers)),
      else: decoded
  end

  defp attach_header_metadata(decoded, headers) when is_map(decoded) do
    metadata = header_metadata(headers)

    if map_size(metadata) > 0,
      do: Map.put(decoded, "_beamweaver_response_header_metadata", metadata),
      else: decoded
  end

  defp header_metadata(headers) do
    headers = response_headers(headers)

    decoded =
      %{
        request_id: headers["x-request-id"],
        openai_organization: headers["openai-organization"],
        openai_processing_ms: headers["openai-processing-ms"],
        openai_project: headers["openai-project"],
        openai_version: headers["openai-version"],
        x_ratelimit_limit_requests: headers["x-ratelimit-limit-requests"],
        x_ratelimit_limit_tokens: headers["x-ratelimit-limit-tokens"],
        x_ratelimit_remaining_requests: headers["x-ratelimit-remaining-requests"],
        x_ratelimit_remaining_tokens: headers["x-ratelimit-remaining-tokens"],
        x_ratelimit_reset_requests: headers["x-ratelimit-reset-requests"],
        x_ratelimit_reset_tokens: headers["x-ratelimit-reset-tokens"]
      }
      |> reject_empty_header_values()

    %{headers: decoded, request_id: decoded[:request_id]}
    |> reject_empty_header_values()
  end

  defp response_headers(headers) when is_list(headers) do
    Map.new(headers)
  end

  defp response_headers(_headers), do: %{}

  defp reject_empty_header_values(map) do
    Map.reject(map, fn
      {_key, value} when value in [nil, ""] -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      _entry -> false
    end)
  end

  defp http_error(%Response{} = response) do
    ProviderResponseDecoder.http_error(response, decoder_opts())
  end

  defp transport_error(error) do
    ProviderResponseDecoder.transport_error(error, decoder_opts())
  end

  defp context_overflow?(status, provider_error, message) do
    status == 400 and
      (error_field(provider_error, "code") == "context_length_exceeded" or
         context_overflow_message?(message))
  end

  defp context_overflow_message?(message) when is_binary(message) do
    normalized = String.downcase(message)

    String.contains?(normalized, "context window") or
      String.contains?(normalized, "context length") or
      String.contains?(normalized, "prompt is too long") or
      String.contains?(normalized, "input tokens exceed") or
      String.contains?(normalized, "too many tokens")
  end

  defp context_overflow_message?(_message), do: false

  defp error_field(%{} = error, field),
    do: BeamWeaver.MapAccess.get(error, field)

  defp error_field(_error, _field), do: nil

  defp chat_completion_tool_calls(tool_calls) do
    tool_calls
    |> List.wrap()
    |> Enum.map(fn call ->
      %{
        "id" => Map.get(call, :id) || Map.get(call, :call_id),
        "type" => "function",
        "function" => %{
          "name" => Map.get(call, :name),
          "arguments" => encode_arguments(Map.get(call, :arguments) || Map.get(call, :args))
        }
      }
    end)
  end

  defp encode_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_arguments(arguments), do: BeamWeaver.JSON.encode!(arguments || %{})

  defp chat_completion_usage(nil), do: nil

  defp chat_completion_usage(%{input_tokens: input, output_tokens: output, total_tokens: total}) do
    %{"prompt_tokens" => input, "completion_tokens" => output, "total_tokens" => total}
  end

  defp chat_completion_usage(usage) when is_map(usage), do: usage

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
