defmodule BeamWeaver.Transport do
  @moduledoc """
  Provider transport boundary for live HTTP clients and replay-backed tests.
  """

  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  @type result :: {:ok, Response.t()} | {:error, Error.t()}
  @type stream_reduce_result :: {:ok, Response.t(), term()} | {:error, Error.t(), term()}

  @callback request(Request.t(), keyword()) :: result()
  @callback stream(Request.t(), keyword(), (binary() -> term())) :: result()
  @callback stream_reduce(Request.t(), keyword(), term(), (term(), binary() -> term())) ::
              stream_reduce_result()

  @optional_callbacks stream: 3, stream_reduce: 4

  @doc """
  Executes a transport request through `transport`.
  """
  @spec request(module(), Request.t(), keyword()) :: result()
  def request(transport, %Request{} = request, opts \\ []) do
    transport.request(request, opts)
  end

  @doc """
  Executes a streaming transport request through `transport`.

  Transports with native streaming call `on_chunk` for successful response
  chunks. Transports without native streaming fall back to `request/3` and emit
  the full 2xx response body as one chunk.
  """
  @spec stream(module(), Request.t(), keyword(), (binary() -> term())) :: result()
  def stream(transport, %Request{} = request, opts \\ [], on_chunk)
      when is_function(on_chunk, 1) do
    cond do
      function_exported?(transport, :stream_reduce, 4) ->
        case stream_reduce(transport, request, opts, :ok, fn acc, chunk ->
               on_chunk.(chunk)
               acc
             end) do
          {:ok, response, _acc} -> {:ok, response}
          {:error, error, _acc} -> {:error, error}
        end

      function_exported?(transport, :stream, 3) ->
        transport.stream(request, opts, on_chunk)

      true ->
        request_stream_fallback(transport, request, opts, on_chunk)
    end
  end

  @doc """
  Executes a streaming request while reducing successful response chunks.
  """
  @spec stream_reduce(
          module(),
          Request.t(),
          keyword(),
          term(),
          (term(), binary() -> term())
        ) :: stream_reduce_result()
  def stream_reduce(transport, %Request{} = request, opts \\ [], acc, reducer)
      when is_function(reducer, 2) do
    if function_exported?(transport, :stream_reduce, 4) do
      transport.stream_reduce(request, opts, acc, reducer)
    else
      case request(transport, request, opts) do
        {:ok, %Response{status: status, body: body} = response}
        when status in 200..299 and is_binary(body) and body != "" ->
          {:ok, response, reducer.(acc, body)}

        {:ok, %Response{} = response} ->
          {:ok, response, acc}

        {:error, %Error{} = error} ->
          {:error, error, acc}
      end
    end
  end

  defp request_stream_fallback(transport, request, opts, on_chunk) do
    case request(transport, request, opts) do
      {:ok, %Response{status: status, body: body} = response} when status in 200..299 ->
        if is_binary(body) and body != "", do: on_chunk.(body)
        {:ok, response}

      other ->
        other
    end
  end
end
