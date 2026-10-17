defmodule BeamWeaver.XAI.Client.ResponseDecoder do
  @moduledoc false

  # xAI speaks the OpenAI wire format; only headers and naming differ.

  alias BeamWeaver.OpenAI.Client.ResponseDecoder, as: OpenAIDecoder
  alias BeamWeaver.XAI.Messages

  @header_fields [
    request_id: "x-request-id",
    x_ratelimit_limit_requests: "x-ratelimit-limit-requests",
    x_ratelimit_limit_tokens: "x-ratelimit-limit-tokens",
    x_ratelimit_remaining_requests: "x-ratelimit-remaining-requests",
    x_ratelimit_remaining_tokens: "x-ratelimit-remaining-tokens",
    x_zero_data_retention: "x-zero-data-retention",
    x_metrics_e2e_ms: "x-metrics-e2e-ms",
    x_metrics_mean_itl_ms: "x-metrics-mean-itl-ms",
    x_metrics_ttft_ms: "x-metrics-ttft-ms"
  ]

  def json(result, opts), do: OpenAIDecoder.json(result, opts, config())
  def text_stream(result), do: OpenAIDecoder.text_stream(result, config())
  def responses_stream_map(result, opts), do: OpenAIDecoder.responses_stream_map(result, opts, config())
  def lifecycle_events(result), do: OpenAIDecoder.lifecycle_events(result, config())
  def typed_events(result), do: OpenAIDecoder.typed_events(result, config())

  def chat_completions_stream_response(result, opts),
    do: OpenAIDecoder.chat_completions_stream_response(result, opts, config())

  # Ends a live Chat Completions stream with the complete reply, decoded like
  # a reply from `XAI.Client.chat_completions/3`.
  def finish_chat_completions_typed_events(state, response, opts) do
    OpenAIDecoder.finish_chat_completions_typed_events(
      state,
      response,
      opts,
      config(),
      &Messages.chat_completions_to_message/1
    )
  end

  defp config do
    %{
      provider: :xai,
      provider_name: "xAI",
      header_fields: @header_fields,
      context_overflow?: nil,
      error_type: &error_type/3
    }
  end

  # xAI documents a wrong API key as a 400.
  defp error_type(400, _provider_error, "Incorrect API key" <> _rest), do: :authentication
  defp error_type(_status, _provider_error, _message), do: nil
end
