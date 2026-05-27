defmodule BeamWeaver.Transport.Replay do
  @moduledoc """
  Transport implementation backed by replay cassettes.
  """

  @behaviour BeamWeaver.Transport

  alias BeamWeaver.Transport.Cassette
  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  @impl true
  def request(%Request{} = request, opts) do
    with {:ok, cassette} <- cassette(opts) do
      Cassette.match(cassette, request)
    end
  end

  @impl true
  def stream(%Request{} = request, opts, on_chunk) when is_function(on_chunk, 1) do
    case stream_reduce(request, opts, :ok, fn acc, chunk ->
           on_chunk.(chunk)
           acc
         end) do
      {:ok, response, _acc} -> {:ok, response}
      {:error, error, _acc} -> {:error, error}
    end
  end

  @impl true
  def stream_reduce(%Request{} = request, opts, acc, reducer) when is_function(reducer, 2) do
    case request(request, opts) do
      {:ok, %Response{status: status, body: body} = response}
      when status in 200..299 and is_binary(body) and body != "" ->
        acc =
          body
          |> chunks(Keyword.get(opts, :stream_chunk_size, byte_size(body)))
          |> Enum.reduce(acc, fn chunk, acc ->
            maybe_delay(Keyword.get(opts, :stream_delay, 0))
            reducer.(acc, chunk)
          end)

        {:ok, %{response | body: ""}, acc}

      {:ok, %Response{} = response} ->
        {:ok, response, acc}

      {:error, %Error{} = error} ->
        {:error, error, acc}
    end
  end

  defp cassette(opts) do
    cond do
      cassette = opts[:cassette] ->
        {:ok, cassette}

      path = opts[:cassette_path] ->
        Cassette.load(path)

      true ->
        {:error, Error.new(:missing_cassette, "replay transport requires :cassette or :cassette_path")}
    end
  end

  defp chunks(body, size) when is_integer(size) and size > 0 do
    do_chunks(body, size, [])
  end

  defp chunks(body, _size), do: [body]

  defp do_chunks("", _size, acc), do: Enum.reverse(acc)

  defp do_chunks(body, size, acc) do
    case body do
      <<chunk::binary-size(size), rest::binary>> -> do_chunks(rest, size, [chunk | acc])
      chunk -> Enum.reverse([chunk | acc])
    end
  end

  defp maybe_delay(delay) when is_integer(delay) and delay > 0, do: Process.sleep(delay)
  defp maybe_delay(_delay), do: :ok
end
