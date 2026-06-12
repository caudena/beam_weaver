defmodule BeamWeaver.Provider.Streaming do
  @moduledoc false

  alias BeamWeaver.Provider.SSE
  alias BeamWeaver.Stream
  alias BeamWeaver.Transport
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  @type error_decoder :: (Transport.result() -> {:ok, term()} | {:error, term()})

  @spec live_sse(
          module(),
          Request.t(),
          keyword(),
          keyword(),
          ([map()] -> [term()]),
          error_decoder()
        ) ::
          Enumerable.t()
  def live_sse(transport, %Request{} = request, transport_opts, opts, parser, error_decoder)
      when is_function(parser, 1) and is_function(error_decoder, 1) do
    Stream.live_resource(
      fn sink ->
        result =
          Transport.stream_reduce(transport, request, transport_opts, "", fn buffer, chunk ->
            {events, buffer} = SSE.process_chunk(buffer, chunk)
            emit_items(parser.(events), sink)
            buffer
          end)

        case result do
          {:ok, %Response{status: status}, buffer} when status in 200..299 ->
            {events, _buffer} = SSE.process_chunk(buffer, "\n\n")
            emit_items(parser.(events), sink)
            :ok

          {:ok, %Response{} = response, _buffer} ->
            decode_stream_error({:ok, response}, error_decoder)

          {:error, error, _buffer} ->
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
    result =
      Transport.stream_reduce(transport, request, transport_opts, [], fn chunks, chunk ->
        [chunk | chunks]
      end)

    case result do
      {:ok, %Response{status: status} = response, chunks} when status in 200..299 ->
        body =
          chunks
          |> Enum.reverse()
          |> IO.iodata_to_binary()

        decoder.({:ok, %{response | body: body}})

      {:ok, %Response{} = response, _chunks} ->
        decoder.({:ok, response})

      {:error, error, _chunks} ->
        decoder.({:error, error})
    end
  end

  defp emit_items(items, sink) when is_list(items), do: Enum.each(items, sink)
  defp emit_items(nil, _sink), do: :ok
  defp emit_items(item, sink), do: sink.(item)

  defp decode_stream_error(result, error_decoder) do
    case error_decoder.(result) do
      {:error, error} -> {:error, error}
      {:ok, _value} -> :ok
      other -> {:error, other}
    end
  end
end
