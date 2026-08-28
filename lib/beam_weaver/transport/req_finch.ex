defmodule BeamWeaver.Transport.ReqFinch do
  @moduledoc """
  Live transport implementation using Req and Finch.

  It forwards validated `:connect_options` to Req and enforces
  `:max_response_bytes` while streaming both successful and error responses.
  `:mint_connect_options` supplies HTTP connection options which Req does not
  expose directly; when present, they are installed on a request-scoped Finch
  pool together with the validated connection options.
  `:stream_idle_timeout` controls the maximum wait between response chunks,
  while `:total_timeout` bounds the complete request. The legacy `:timeout`
  option remains the fallback for both limits.
  """

  @behaviour BeamWeaver.Transport

  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  @impl true
  def request(%Request{} = request, opts) do
    case stream_reduce(request, opts, [], fn chunks, chunk -> [chunk | chunks] end) do
      {:ok, %Response{status: status} = response, chunks} when status in 200..299 ->
        {:ok, %{response | body: chunks |> Enum.reverse() |> IO.iodata_to_binary()}}

      {:ok, %Response{} = response, _chunks} ->
        {:ok, response}

      {:error, %Error{} = error, _chunks} ->
        {:error, error}
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
    maximum = Keyword.get(opts, :max_response_bytes, 5_000_000)

    if is_integer(maximum) and maximum > 0 do
      request
      |> req_options(opts)
      |> Keyword.put(:into, stream_handler(acc, reducer, maximum))
      |> Req.request()
      |> normalize_stream_reduce_result(acc)
    else
      {:error, Error.new(:invalid_transport_options, "max_response_bytes must be a positive integer"), acc}
    end
  rescue
    exception ->
      error =
        Error.new(:transport_failure, "transport request failed", %{
          reason: Exception.message(exception),
          exception: inspect(exception.__struct__)
        })

      {:error, error, acc}
  catch
    kind, reason ->
      error =
        Error.new(:transport_failure, "transport request failed", %{
          kind: kind,
          reason: inspect(reason)
        })

      {:error, error, acc}
  end

  @doc false
  def req_options(%Request{} = request, opts \\ []) do
    legacy_timeout = Keyword.get(opts, :timeout, Keyword.get(request.options, :timeout, 15_000))

    connect_timeout =
      Keyword.get(opts, :connect_timeout, Keyword.get(request.options, :connect_timeout))

    stream_idle_timeout =
      Keyword.get(
        opts,
        :stream_idle_timeout,
        Keyword.get(request.options, :stream_idle_timeout, legacy_timeout)
      )

    total_timeout =
      Keyword.get(
        opts,
        :total_timeout,
        Keyword.get(request.options, :total_timeout, legacy_timeout)
      )

    [
      method: request.method,
      url: request.url,
      headers: request.headers,
      finch:
        opts
        |> Keyword.get(:finch, BeamWeaver.Transport.Finch)
        |> normalize_finch_options(),
      receive_timeout: stream_idle_timeout,
      request_timeout: total_timeout,
      retry: false,
      redirect: false
    ]
    |> maybe_put_raw_response(opts)
    |> maybe_put_connect_options(opts, connect_timeout)
    |> maybe_put_finch_private(opts)
    |> maybe_put_body(request)
  end

  defp normalize_finch_options(nil), do: nil
  defp normalize_finch_options(name) when is_atom(name), do: [name: name]
  defp normalize_finch_options(options) when is_list(options), do: options
  defp normalize_finch_options(options), do: options

  defp maybe_put_connect_options(options, opts, connect_timeout) do
    connect_options =
      case Keyword.get(opts, :connect_options) do
        connect_options when is_list(connect_options) -> connect_options
        _other -> []
      end

    connect_options =
      if is_integer(connect_timeout) and connect_timeout > 0 do
        Keyword.put_new(connect_options, :timeout, connect_timeout)
      else
        connect_options
      end

    mint_connect_options =
      case Keyword.get(opts, :mint_connect_options) do
        mint_connect_options when is_list(mint_connect_options) -> mint_connect_options
        _other -> []
      end

    case {connect_options, mint_connect_options} do
      {[_option | _rest], []} ->
        options
        |> Keyword.delete(:finch)
        |> Keyword.put(:connect_options, connect_options)

      {connect_options, [_option | _rest]} ->
        options
        |> Keyword.delete(:connect_options)
        |> Keyword.put(:finch, finch_pool_options(connect_options, mint_connect_options))

      {[], []} ->
        options
    end
  end

  defp finch_pool_options(connect_options, mint_connect_options) do
    transport_options =
      Keyword.merge(
        Keyword.take(connect_options, [:timeout]),
        Keyword.get(connect_options, :transport_opts, [])
      )

    connection_options =
      connect_options
      |> Keyword.take([:hostname, :proxy, :proxy_headers, :client_settings])
      |> maybe_put_transport_options(transport_options)
      |> Keyword.merge(mint_connect_options)

    []
    |> maybe_put_protocols(Keyword.get(connect_options, :protocols))
    |> Keyword.put(:conn_opts, connection_options)
  end

  defp maybe_put_transport_options(options, []), do: options

  defp maybe_put_transport_options(options, transport_options),
    do: Keyword.put(options, :transport_opts, transport_options)

  defp maybe_put_protocols(options, nil), do: options
  defp maybe_put_protocols(options, protocols), do: Keyword.put(options, :protocols, protocols)

  defp maybe_put_raw_response(options, opts) do
    if Keyword.get(opts, :raw_response?, false) do
      options
      |> Keyword.put(:raw, true)
      |> Keyword.put(:decode_body, false)
    else
      options
    end
  end

  defp maybe_put_finch_private(options, opts) do
    private =
      opts
      |> Keyword.get(:finch_private)
      |> normalize_private()
      |> maybe_put_beam_weaver_metadata(Keyword.get(opts, :beam_weaver_http_metadata))

    if private == [] do
      options
    else
      Keyword.put(options, :finch_private, private)
    end
  end

  defp normalize_private(nil), do: []
  defp normalize_private(private) when is_map(private), do: Map.to_list(private)
  defp normalize_private(private) when is_list(private), do: private

  defp maybe_put_beam_weaver_metadata(private, nil), do: private

  defp maybe_put_beam_weaver_metadata(private, metadata) when is_map(metadata) do
    Keyword.update(private, :beam_weaver, metadata, &merge_metadata(&1, metadata))
  end

  defp maybe_put_beam_weaver_metadata(private, _metadata), do: private

  defp merge_metadata(existing, metadata) when is_map(existing), do: Map.merge(existing, metadata)
  defp merge_metadata(_existing, metadata), do: metadata

  defp maybe_put_body(options, %Request{json: json}) when not is_nil(json) do
    Keyword.put(options, :json, json)
  end

  defp maybe_put_body(options, %Request{body: body}) when not is_nil(body) do
    Keyword.put(options, :body, body)
  end

  defp maybe_put_body(options, _request), do: options

  defp stream_handler(acc, reducer, maximum) do
    fn
      {:data, data}, {request, response} when response.status in 200..299 ->
        bytes = Map.get(response.private, :beam_weaver_response_bytes, 0) + byte_size(data)

        if bytes <= maximum do
          acc = reducer.(Map.get(response.private, :beam_weaver_stream_acc, acc), data)

          response =
            response
            |> put_in([Access.key(:private), :beam_weaver_stream_acc], acc)
            |> put_in([Access.key(:private), :beam_weaver_response_bytes], bytes)

          {:cont, {request, response}}
        else
          response = put_in(response.private[:beam_weaver_response_too_large], true)
          {:halt, {request, response}}
        end

      {:data, data}, {request, response} ->
        bytes = Map.get(response.private, :beam_weaver_response_bytes, 0) + byte_size(data)

        if bytes <= maximum do
          response =
            response
            |> append_body(data)
            |> put_in([Access.key(:private), :beam_weaver_response_bytes], bytes)

          {:cont, {request, response}}
        else
          response = put_in(response.private[:beam_weaver_response_too_large], true)
          {:halt, {request, response}}
        end
    end
  end

  defp append_body(%Req.Response{body: body} = response, data) when is_binary(body) do
    %{response | body: body <> data}
  end

  defp append_body(%Req.Response{} = response, data) do
    %{response | body: IO.iodata_to_binary([response.body || "", data])}
  end

  defp normalize_stream_reduce_result(
         {:ok, %Req.Response{private: %{beam_weaver_response_too_large: true}}},
         acc
       ) do
    {:error, Error.new(:response_too_large, "transport response exceeded the configured byte limit"), acc}
  end

  defp normalize_stream_reduce_result({:ok, %Req.Response{status: status} = response}, acc)
       when status in 200..299 do
    stream_acc = Map.get(response.private, :beam_weaver_stream_acc, acc)
    response_bytes = Map.get(response.private, :beam_weaver_response_bytes, 0)

    response =
      response
      |> Map.update!(:private, &Map.drop(&1, [:beam_weaver_stream_acc, :beam_weaver_response_bytes]))
      |> Map.put(:body, "")

    {:ok, transport_response(response, response_bytes), stream_acc}
  end

  defp normalize_stream_reduce_result({:ok, %Req.Response{} = response}, acc) do
    response_bytes = Map.get(response.private, :beam_weaver_response_bytes, byte_size(response.body || ""))
    {:ok, transport_response(response, response_bytes), acc}
  end

  defp normalize_stream_reduce_result({:error, error}, acc) do
    {:error,
     Error.new(:transport_failure, "transport request failed", %{
       reason: inspect(error)
     }), acc}
  end

  defp transport_response(%Req.Response{} = response, response_bytes) do
    Response.new(
      status: response.status,
      headers: response.headers,
      body: response.body,
      metadata: %{source: :live, wire_bytes: response_bytes}
    )
  end
end
