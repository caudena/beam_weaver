defmodule BeamWeaver.Provider.ChatRuntime do
  @moduledoc false

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.ChatModel.Options, as: ChatOptions
  alias BeamWeaver.Provider.ChatRuntime.Adapter
  alias BeamWeaver.Stream, as: BWStream
  alias BeamWeaver.Stream.Sink

  def async_invoke(opts, invoke_fun), do: Async.run_call(opts, invoke_fun)

  def async_batch(message_batches, opts, invoke_fun) when is_list(message_batches) do
    Async.batch_call(message_batches, opts, invoke_fun)
  end

  def async_stream(opts, stream_fun), do: Async.run_call(opts, stream_fun)

  def model_id(model), do: ChatOptions.model_id(model)

  def profile(model), do: ChatOptions.profile(model)

  def invoke(model, messages, opts, %Adapter{} = adapter) do
    call_opts = default_response_header_opt(model, opts)

    with {:ok, body} <-
           request_body(model, messages, Keyword.put(call_opts, :stream, false), adapter),
         {:ok, response} <- adapter.invoke.(model, body, call_opts),
         {:ok, message} <- adapter.decode.(response, call_opts) do
      parse_response(message, call_opts, adapter)
    end
  end

  def stream(model, messages, opts, %Adapter{} = adapter) do
    with {:ok, body} <- request_body(model, messages, Keyword.put(opts, :stream, true), adapter) do
      adapter.stream.(model, body, opts)
    end
  end

  def stream_response(model, messages, opts, %Adapter{} = adapter) do
    call_opts = default_response_header_opt(model, opts)

    with {:ok, body} <-
           request_body(model, messages, Keyword.put(call_opts, :stream, true), adapter),
         {:ok, response} <- adapter.stream_response.(model, body, call_opts),
         {:ok, message} <- adapter.decode.(response, call_opts) do
      parse_response(message, call_opts, adapter)
    end
  end

  def stream_events(model, messages, opts, %Adapter{stream_events: stream_events} = adapter)
      when is_function(stream_events, 3) do
    with {:ok, body} <- request_body(model, messages, Keyword.put(opts, :stream, true), adapter),
         {:ok, events} <- stream_events.(model, body, opts) do
      metadata = stream_metadata(model, body, opts, adapter)
      mux_typed_events(events, adapter.source, metadata, opts)
    end
  end

  def stream_events(_model, _messages, _opts, %Adapter{}) do
    {:error, Error.new(:unsupported_feature, "provider does not support typed stream events")}
  end

  def default_response_header_opt(%{include_response_headers: include_response_headers}, opts) do
    Keyword.put_new(opts, :include_response_headers, include_response_headers)
  end

  def mux_typed_events(events, source, metadata, opts) do
    stream =
      BWStream.mux(
        [
          {:sink, source,
           fn sink ->
             Enum.each(events, &Sink.emit(sink, put_stream_metadata(&1, metadata)))
             :ok
           end}
        ],
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

    {:ok, stream}
  end

  def put_stream_metadata(%BeamWeaver.Stream.Envelope{} = envelope, metadata) do
    %{envelope | metadata: Map.merge(envelope.metadata || %{}, metadata)}
  end

  def put_stream_metadata(event, metadata) do
    BWStream.envelope(event, metadata: metadata)
  end

  defp request_body(model, messages, opts, %Adapter{} = adapter),
    do: adapter.request.(model, messages, opts)

  defp parse_response(message, opts, %Adapter{} = adapter) do
    case adapter.parse do
      nil -> {:ok, message}
      parser -> parser.(message, opts)
    end
  end

  defp stream_metadata(model, body, opts, %Adapter{metadata: metadata}) when is_function(metadata, 3),
    do: metadata.(model, body, opts)
end
