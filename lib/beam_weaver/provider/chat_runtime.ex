defmodule BeamWeaver.Provider.ChatRuntime do
  @moduledoc false

  # The invoke/stream flow behind `use BeamWeaver.Provider.ChatModel`; `module`
  # is the provider chat model implementing that behaviour.

  alias BeamWeaver.Stream, as: BWStream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Sink

  def invoke(module, model, messages, opts) do
    opts = put_response_header_opt(model, opts)

    with {:ok, body} <- module.request_body(model, messages, Keyword.put(opts, :stream, false)),
         {:ok, response} <- module.send_request(:invoke, model, body, opts),
         {:ok, message} <- module.decode_response(response, opts) do
      module.parse_response(model, message, opts)
    end
  end

  def stream(module, model, messages, opts) do
    with {:ok, body} <- module.request_body(model, messages, Keyword.put(opts, :stream, true)) do
      module.send_request(:stream, model, body, opts)
    end
  end

  def stream_response(module, model, messages, opts) do
    opts = put_response_header_opt(model, opts)

    with {:ok, body} <- module.request_body(model, messages, Keyword.put(opts, :stream, true)),
         {:ok, response} <- module.send_request(:stream_response, model, body, opts),
         {:ok, message} <- module.decode_response(response, opts) do
      module.parse_response(model, message, opts)
    end
  end

  def stream_events(module, source, model, messages, opts) do
    with {:ok, body} <- module.request_body(model, messages, Keyword.put(opts, :stream, true)),
         {:ok, events} <- module.send_request(:stream_events, model, body, opts) do
      mux_typed_events(events, source, module.stream_metadata(model, body, opts), opts)
    end
  end

  def stream_exact_events(module, source, model, body, opts) when is_binary(body) do
    with {:ok, events} <- module.send_request(:exact_stream_events, model, body, opts) do
      mux_typed_events(events, source, Keyword.get(opts, :exact_request_metadata, %{}), opts)
    end
  end

  defp put_response_header_opt(%{include_response_headers: include?}, opts),
    do: Keyword.put_new(opts, :include_response_headers, include?)

  # The mux reads the provider's events in a producer of its own. Its `Debug`
  # events for that producer's start and stop are not part of the model call,
  # so the typed stream leaves them out, as Anthropic's and Gemini's, which
  # have no mux, do; a run streaming the call has its own.
  def mux_typed_events(events, source, metadata, opts) do
    stream =
      [
        {:sink, source,
         fn sink ->
           Enum.each(events, &Sink.emit(sink, put_stream_metadata(&1, metadata)))
           :ok
         end}
      ]
      |> BWStream.mux(
        run_id: Keyword.get(opts, :run_id),
        graph: Keyword.get(opts, :graph),
        namespace: Keyword.get(opts, :namespace, []),
        metadata: metadata,
        heartbeat: Keyword.get(opts, :heartbeat),
        max_buffer: Keyword.get(opts, :max_buffer, 256),
        overflow: Keyword.get(opts, :overflow, :block),
        timeout: Keyword.get(opts, :stream_timeout, :infinity),
        cancel_timeout: Keyword.get(opts, :cancel_timeout, 100),
        producer_supervisor: Keyword.get(opts, :producer_supervisor)
      )
      |> Stream.reject(&producer_event?/1)

    {:ok, stream}
  end

  defp producer_event?(%Envelope{event: %Events.Debug{payload: %{type: type}}}),
    do: type in [:producer_start, :producer_stop]

  defp producer_event?(_envelope), do: false

  def put_stream_metadata(%Envelope{} = envelope, metadata) do
    %{envelope | metadata: Map.merge(envelope.metadata || %{}, metadata)}
  end

  def put_stream_metadata(event, metadata) do
    BWStream.envelope(event, metadata: metadata)
  end
end
