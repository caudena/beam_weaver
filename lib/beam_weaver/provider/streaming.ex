defmodule BeamWeaver.Provider.Streaming do
  @moduledoc false

  alias BeamWeaver.Provider.SSE
  alias BeamWeaver.Provider.StreamFailure
  alias BeamWeaver.Provider.StreamValidator
  alias BeamWeaver.Stream
  alias BeamWeaver.Transport
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  @type error_decoder :: (Transport.result() -> {:ok, term()} | {:error, term()})
  @type parser ::
          ([map()] -> [term()])
          | ([map()], term() -> {[term()], term()})

  # A stream stops at an event that reports a failure (see `StreamFailure`),
  # and the call fails with the error `error_decoder` makes of a response with
  # the HTTP status of that failure and its body. The events before it are a
  # reply cut short, never a complete one. `opts[:provider]` names the
  # provider that sent the stream.

  @spec live_sse(
          module(),
          Request.t(),
          keyword(),
          keyword(),
          parser(),
          error_decoder()
        ) ::
          Enumerable.t()
  def live_sse(transport, %Request{} = request, transport_opts, opts, parser, error_decoder)
      when (is_function(parser, 1) or is_function(parser, 2)) and
             is_function(error_decoder, 1) do
    provider = Keyword.get(opts, :provider)

    Stream.live_resource(
      fn sink ->
        result =
          Transport.stream_reduce(
            transport,
            request,
            transport_opts,
            %{buffer: "", validation: StreamValidator.new(opts), parser: nil, failure: nil},
            fn
              %{validation: %StreamValidator{error: nil}, failure: nil} = state, chunk ->
                with {:ok, events, buffer} <- parse_chunk(state.buffer, chunk, opts),
                     {events, failure} = StreamFailure.split(events, provider),
                     {:ok, items, parser_state} <- parse_items(parser, events, state.parser),
                     {:ok, validation} <-
                       StreamValidator.push(state.validation, items, transport_bytes: byte_size(chunk)) do
                  emit_items(items, sink)
                  %{buffer: buffer, validation: validation, parser: parser_state, failure: failure}
                else
                  {:error, error} ->
                    {:error, _error, validation} = StreamValidator.reject(state.validation, error)
                    %{state | validation: validation}

                  {:error, _error, validation} ->
                    %{state | validation: validation}
                end

              state, _chunk ->
                state
            end
          )

        case result do
          {:ok, %Response{status: status} = response, state} when status in 200..299 ->
            close_sse(state, response, sink, opts, parser, error_decoder)

          {:ok, %Response{} = response, _state} ->
            notify_response(response, opts)
            decode_stream_error({:ok, response}, error_decoder)

          {:error, error, _state} ->
            decode_stream_error({:error, error}, error_decoder)
        end
      end,
      timeout: Keyword.get(opts, :stream_timeout, :infinity),
      producer_supervisor: Keyword.get(opts, :producer_supervisor)
    )
  end

  @spec collect(module(), Request.t(), keyword(), error_decoder(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def collect(transport, %Request{} = request, transport_opts, decoder, opts \\ [])
      when is_function(decoder, 1) do
    maximum = Keyword.get(transport_opts, :max_response_bytes, 16 * 1024 * 1024)

    result =
      Transport.stream_reduce(transport, request, transport_opts, {[], 0}, fn
        {_chunks, :too_large} = state, _chunk ->
          state

        {chunks, bytes}, chunk ->
          bytes = bytes + byte_size(chunk)
          if bytes <= maximum, do: {[chunk | chunks], bytes}, else: {[], :too_large}
      end)

    case result do
      {:ok, %Response{status: status}, {_chunks, :too_large}} when status in 200..299 ->
        {:error, BeamWeaver.Core.Error.new(:invalid_provider_response, "provider response is too large")}

      {:ok, %Response{status: status} = response, {chunks, _bytes}} when status in 200..299 ->
        body =
          chunks
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        case body |> SSE.events() |> StreamFailure.split(Keyword.get(opts, :provider)) do
          {_events, nil} -> decoder.({:ok, %{response | body: body}})
          {_events, failure} -> decoder.({:ok, failed_response(response, failure)})
        end

      {:ok, %Response{} = response, _state} ->
        decoder.({:ok, response})

      {:error, error, _state} ->
        decoder.({:error, error})
    end
  end

  # The transport closed after a 200 response. Unless the stream reported a
  # failure, its last event may still be in the buffer, without the blank line
  # that ends it.
  defp close_sse(%{failure: {_status, _body} = failure}, response, _sink, opts, _parser, error_decoder),
    do: fail_sse(failure, response, opts, error_decoder)

  defp close_sse(state, response, sink, opts, parser, error_decoder) do
    with :ok <- StreamValidator.finish(state.validation),
         {:ok, events, _buffer} <- parse_chunk(state.buffer, "\n\n", opts) do
      case StreamFailure.split(events, Keyword.get(opts, :provider)) do
        {events, nil} -> complete_sse(events, state, response, sink, opts, parser)
        {_events, failure} -> fail_sse(failure, response, opts, error_decoder)
      end
    end
  end

  defp complete_sse(events, state, response, sink, opts, parser) do
    with {:ok, items, parser_state} <- parse_items(parser, events, state.parser),
         {:ok, final_items} <- finalize_parser(parser_state, response, opts),
         items = items ++ final_items,
         {:ok, validation} <- push_final(state.validation, items),
         :ok <- StreamValidator.finish(validation) do
      emit_items(items, sink)
      notify_response(response, opts)
      :ok
    end
  end

  defp fail_sse(failure, %Response{} = response, opts, error_decoder) do
    notify_response(response, opts)
    decode_stream_error({:ok, failed_response(response, failure)}, error_decoder)
  end

  defp failed_response(%Response{} = response, {status, body}), do: %{response | status: status, body: body}

  # Stateful wire formats without a separate terminal SSE event finalize only
  # after a clean transport close, never after a reported failure. Partial
  # chunks must never invoke this hook.
  defp finalize_parser(state, response, opts) do
    case Keyword.get(opts, :parser_finalizer) do
      fun when is_function(fun, 2) -> fun.(state, response)
      fun when is_function(fun, 1) -> fun.(state)
      nil -> {:ok, []}
    end
  end

  defp emit_items(items, sink) when is_list(items), do: Enum.each(items, sink)

  defp parse_chunk(buffer, chunk, opts) do
    {events, buffer} = SSE.process_chunk(buffer, chunk, strict: Keyword.get(opts, :strict_sse, false))
    {:ok, events, buffer}
  rescue
    exception -> {:error, BeamWeaver.Core.Error.new(:invalid_provider_stream, Exception.message(exception))}
  end

  defp parse_items(parser, events, state) do
    if is_function(parser, 2) do
      case parser.(events, state) do
        {items, next_state} -> {:ok, List.wrap(items), next_state}
        other -> {:error, {:invalid_stateful_parser_result, other}}
      end
    else
      {:ok, List.wrap(parser.(events)), state}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp push_final(validation, items) do
    case StreamValidator.push(validation, items) do
      {:ok, validation} -> {:ok, validation}
      {:error, error, _validation} -> {:error, error}
    end
  end

  defp notify_response(%Response{} = response, opts) do
    case Keyword.get(opts, :on_response) do
      callback when is_function(callback, 1) -> callback.(response)
      _callback -> :ok
    end
  end

  defp decode_stream_error(result, error_decoder) do
    case error_decoder.(result) do
      {:error, error} -> {:error, error}
      {:ok, _value} -> :ok
      other -> {:error, other}
    end
  end
end
