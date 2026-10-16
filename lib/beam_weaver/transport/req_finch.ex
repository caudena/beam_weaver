defmodule BeamWeaver.Transport.ReqFinch do
  @moduledoc """
  Live transport implementation using Req and Finch.

  It forwards validated `:connect_options` to Req and enforces
  `:max_response_bytes` while streaming both successful and error responses.
  `:stream_idle_timeout` controls the maximum wait between response chunks,
  while `:total_timeout` bounds the complete request. The legacy `:timeout`
  option remains the fallback for both limits.

  ## Connection pools

  Requests share one connection pool per origin, kept while the application
  runs, which suits the few origins of the provider APIs you call. These
  requests run on isolated pools instead, each shared only by requests to the
  same origin with the same connection settings:

    * every `BeamWeaver.Transport.Safe` request, since its URL may come from a
      user or a model;
    * a request that sets `:mint_connect_options`, HTTP connection options
      which Req does not expose directly;
    * a request to an IPv6 address, such as `http://[::1]:4000`, unless it
      passes its own `:finch`.

  BeamWeaver keeps at most 16 isolated pools. A request that needs a new one
  closes the least recently used pool with no request in flight, or waits for
  one within its `:total_timeout`, and a pool closes after 60 seconds without
  requests. BeamWeaver reads both limits from your config when it starts:

      config :beam_weaver, :transport,
        max_isolated_pools: 32,
        isolated_pool_idle_timeout: 30_000

  Send requests to URLs from users or models through
  `BeamWeaver.Transport.Safe`: it checks them against a URL policy, and keeps
  their connections out of the shared pool.
  """

  @behaviour BeamWeaver.Transport

  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.IsolatedPools
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  @shared_finch BeamWeaver.Transport.Finch

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
      |> send_request()
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

    uri = URI.parse(request.url)

    [
      method: request.method,
      url: request.url,
      headers: put_ipv6_host(request.headers, uri),
      finch:
        opts
        |> Keyword.get(:finch, @shared_finch)
        |> normalize_finch_options(),
      receive_timeout: stream_idle_timeout,
      request_timeout: total_timeout,
      retry: false,
      decode_body: false,
      redirect: false
    ]
    |> maybe_put_raw_response(opts)
    |> put_pool(opts, connect_timeout, ipv6_address?(uri))
    |> maybe_put_finch_private(opts)
    |> maybe_put_body(request)
  end

  # Req would start a Finch instance, named by new atoms, for every distinct
  # set of pool options and never stop it. Isolated pools are bounded instead.
  defp send_request(options) do
    case Keyword.get(options, :finch) do
      {:isolated, pool_options} ->
        IsolatedPools.run(options[:url], pool_options, options[:request_timeout], fn finch, time_left ->
          options
          |> Keyword.merge(finch: finch, request_timeout: time_left)
          |> Req.request()
        end)

      _finch ->
        Req.request(options)
    end
  end

  defp normalize_finch_options(nil), do: nil
  defp normalize_finch_options(name) when is_atom(name), do: [name: name]
  defp normalize_finch_options(options) when is_list(options), do: options
  defp normalize_finch_options(options), do: options

  # The shared pool opens IPv4 sockets with Finch's default settings. HTTP
  # connection options, and an IPv6 address on the shared pool, get an
  # isolated pool built for them; `:connect_options` alone get the pool Req
  # starts for them.
  defp put_pool(options, opts, connect_timeout, ipv6?) do
    connect_options = list_option(opts, :connect_options)

    connect_options =
      if is_integer(connect_timeout) and connect_timeout > 0 do
        Keyword.put_new(connect_options, :timeout, connect_timeout)
      else
        connect_options
      end

    mint_connect_options = list_option(opts, :mint_connect_options)

    cond do
      mint_connect_options != [] or (ipv6? and options[:finch] == [name: @shared_finch]) ->
        pool_options = isolated_pool_options(connect_options, mint_connect_options, ipv6?)
        Keyword.put(options, :finch, {:isolated, pool_options})

      connect_options != [] ->
        options
        |> Keyword.delete(:finch)
        |> Keyword.put(:connect_options, connect_options)

      true ->
        options
    end
  end

  defp list_option(opts, key) do
    case Keyword.get(opts, key) do
      options when is_list(options) -> options
      _other -> []
    end
  end

  defp isolated_pool_options(connect_options, mint_connect_options, ipv6?) do
    # As Req does for the pools it starts: an IPv6 address needs an IPv6 socket.
    inet6 = if ipv6?, do: [inet6: true], else: []

    transport_options =
      Keyword.merge(
        Keyword.take(connect_options, [:timeout]) ++ inet6,
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

  # `URI` drops the brackets around an IPv6 address, and a host name has no `:`.
  defp ipv6_address?(%URI{host: host}), do: is_binary(host) and String.contains?(host, ":")

  # For an IPv6 address Req sends a Host header without the port. Send the one
  # Mint would: the bracketed address, and the port unless it's the default.
  defp put_ipv6_host(headers, %URI{scheme: scheme, host: host, port: port} = uri) do
    cond do
      not ipv6_address?(uri) or Enum.any?(headers, fn {name, _value} -> String.downcase(name) == "host" end) ->
        headers

      {scheme, port} in [{"http", 80}, {"https", 443}] ->
        [{"host", "[#{host}]"} | headers]

      true ->
        [{"host", "[#{host}]:#{port}"} | headers]
    end
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

  defp normalize_stream_reduce_result({:error, %Error{} = error}, acc), do: {:error, error, acc}

  # Mint stops reading at `max_header_list_size`, before Req builds a response.
  defp normalize_stream_reduce_result(
         {:error, %Req.HTTPError{reason: {:max_header_list_size_exceeded, _size, _maximum}}},
         acc
       ) do
    {:error, Error.new(:response_headers_too_large, "transport response headers exceeded the configured byte limit"),
     acc}
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
