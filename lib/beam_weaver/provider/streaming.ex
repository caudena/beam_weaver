defmodule BeamWeaver.Provider.Streaming do
  @moduledoc false

  alias BeamWeaver.Provider.SSE
  alias BeamWeaver.Provider.StreamValidator
  alias BeamWeaver.Stream
  alias BeamWeaver.Transport
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  @type error_decoder :: (Transport.result() -> {:ok, term()} | {:error, term()})
  @type parser ::
          ([map()] -> [term()])
          | ([map()], term() -> {[term()], term()})

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
    Stream.live_resource(
      fn sink ->
        result =
          Transport.stream_reduce(
            transport,
            request,
            transport_opts,
            {"", StreamValidator.new(opts), nil},
            fn
              {buffer, %StreamValidator{error: nil} = validation, parser_state}, chunk ->
                {events, buffer} = SSE.process_chunk(buffer, chunk)

                with {:ok, items, parser_state} <- parse_items(parser, events, parser_state),
                     {:ok, validation} <-
                       StreamValidator.push(validation, items, transport_bytes: byte_size(chunk)) do
                  emit_items(items, sink)
                  {buffer, validation, parser_state}
                else
                  {:error, error} ->
                    {:error, _error, validation} = StreamValidator.reject(validation, error)
                    {buffer, validation, parser_state}

                  {:error, _error, validation} ->
                    {buffer, validation, parser_state}
                end

              state, _chunk ->
                state
            end
          )

        case result do
          {:ok, %Response{status: status} = response, {buffer, validation, parser_state}}
          when status in 200..299 ->
            {events, _buffer} = SSE.process_chunk(buffer, "\n\n")

            with :ok <- StreamValidator.finish(validation),
                 {:ok, items, _parser_state} <- parse_items(parser, events, parser_state),
                 {:ok, validation} <- push_final(validation, items),
                 :ok <- StreamValidator.finish(validation) do
              emit_items(items, sink)
              notify_response(response, opts)
              :ok
            end

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

  @spec collect(module(), Request.t(), keyword(), error_decoder()) ::
          {:ok, term()} | {:error, term()}
  def collect(transport, %Request{} = request, transport_opts, decoder)
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

        decoder.({:ok, %{response | body: body}})

      {:ok, %Response{} = response, _state} ->
        decoder.({:ok, response})

      {:error, error, _state} ->
        decoder.({:error, error})
    end
  end

  defp emit_items(items, sink) when is_list(items), do: Enum.each(items, sink)

  defp parse_items(parser, events, state) when is_function(parser, 2) do
    case parser.(events, state) do
      {items, next_state} -> {:ok, normalize_items(items), next_state}
      other -> {:error, {:invalid_stateful_parser_result, other}}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp parse_items(parser, events, state) when is_function(parser, 1) do
    {:ok, normalize_items(parser.(events)), state}
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_items(items), do: if(is_list(items), do: items, else: List.wrap(items))

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
