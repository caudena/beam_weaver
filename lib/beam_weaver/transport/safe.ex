defmodule BeamWeaver.Transport.Safe do
  @moduledoc """
  URL-policy enforcing transport wrapper.

  This is the native BeamWeaver SSRF boundary: callers keep using the
  `BeamWeaver.Transport` behaviour, while this wrapper validates the original
  request URL and every followed redirect through `BeamWeaver.Transport.URLPolicy`.
  Set `pin_resolved?: true` in the URL policy to resolve once, connect to that
  exact address, and preserve the original Host header and TLS hostname. The
  response metadata records that frozen dial plan. Req/Finch does not expose
  the socket peer address or an exact write count, so transport failures remain
  ambiguous after dispatch; a completed response is the only write evidence.

  With the default transport, requests stay out of the connection pool that
  provider calls share, so URLs from users or models can't grow it. They run
  on isolated pools instead: a request reuses connections only with requests
  to the same origin with the same connection settings (for a pinned request,
  the same address and host name), and at most 16 of these pools exist (see
  `BeamWeaver.Transport.ReqFinch` to change the limit).

  Callers may independently set `:connect_timeout`, `:stream_idle_timeout`,
  and `:total_timeout`. The legacy `:timeout` remains the fallback for all
  three limits. `:max_request_header_bytes` and `:max_response_header_bytes`
  (65,536 bytes each by default) limit the request and response headers; a
  response over its limit fails with `:response_headers_too_large`.
  """

  @behaviour BeamWeaver.Transport

  alias BeamWeaver.Core.Error, as: CoreError
  alias BeamWeaver.Transport
  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response
  alias BeamWeaver.Transport.URLPolicy

  @default_maximum_header_bytes 65_536
  @cross_origin_redirect_headers ~w(accept content-type user-agent)

  @redirect_statuses 300..399

  @impl true
  def request(%Request{} = request, opts) do
    policy = URLPolicy.new(Keyword.get(opts, :url_policy, opts))
    transport = Transport.default(Keyword.get(opts, :transport))
    opts = transport_options(opts, policy)

    do_request(transport, request, opts, policy, 0)
  end

  @impl true
  def stream(%Request{} = request, opts, on_chunk) when is_function(on_chunk, 1),
    do: Transport.stream(__MODULE__, request, opts, on_chunk)

  @impl true
  def stream_reduce(%Request{} = request, opts, acc, reducer) when is_function(reducer, 2) do
    policy = URLPolicy.new(Keyword.get(opts, :url_policy, opts))
    transport = Transport.default(Keyword.get(opts, :transport))
    opts = transport_options(opts, policy)

    do_stream_reduce(transport, request, opts, acc, reducer, policy, 0)
  end

  defp do_request(transport, %Request{} = request, opts, policy, redirect_count) do
    with {:ok, wire_request, wire_opts, target} <- prepare_request(request, opts, policy),
         :ok <- before_dispatch(wire_opts) do
      case Transport.request(transport, wire_request, transport_wire_options(wire_opts)) do
        {:ok, %Response{} = response} ->
          with :ok <- validate_response_headers(response, opts) do
            case redirect(request, response, policy, redirect_count) do
              :none -> {:ok, annotate_target(response, target)}
              {:follow, redirect} -> do_request(transport, redirect, opts, policy, redirect_count + 1)
              error -> error
            end
          end

        {:error, %Error{} = error} ->
          {:error, post_dispatch_error(error)}
      end
    end
  end

  defp do_stream_reduce(transport, %Request{} = request, opts, acc, reducer, policy, redirect_count) do
    with {:ok, wire_request, wire_opts, target} <- prepare_request(request, opts, policy),
         :ok <- before_dispatch(wire_opts),
         {:ok, %Response{} = response, result_acc} <-
           Transport.stream_reduce(transport, wire_request, transport_wire_options(wire_opts), acc, reducer) do
      case validate_response_headers(response, opts) do
        :ok ->
          case redirect(request, response, policy, redirect_count) do
            :none -> {:ok, annotate_target(response, target), result_acc}
            {:follow, redirect} -> do_stream_reduce(transport, redirect, opts, acc, reducer, policy, redirect_count + 1)
            {:error, error} -> {:error, error, acc}
          end

        {:error, error} ->
          {:error, error, result_acc}
      end
    else
      {:error, %Error{} = error, error_acc} -> {:error, post_dispatch_error(error), error_acc}
      {:error, %Error{} = error} -> {:error, error, acc}
    end
  end

  defp redirect(request, response, policy, redirect_count) do
    location = response.headers |> header("location") |> absolute_redirect_url(request.url)

    cond do
      response.status not in @redirect_statuses or is_nil(location) or not policy.follow_redirects? ->
        :none

      redirect_count >= policy.max_redirects ->
        {:error,
         Error.new(:too_many_redirects, "transport exceeded the configured redirect limit", %{
           url: request.url,
           max_redirects: policy.max_redirects
         })}

      true ->
        {:follow, redirect_request(request, location)}
    end
  end

  defp before_dispatch(opts) do
    case Keyword.get(opts, :before_dispatch) do
      nil ->
        :ok

      callback when is_function(callback, 0) ->
        case callback.() do
          :ok ->
            :ok

          {:error, %Error{} = error} ->
            {:error, error}

          {:error, _reason} ->
            {:error, pre_dispatch_error(:dispatch_evidence_failed, "transport dispatch evidence failed")}

          _other ->
            {:error,
             pre_dispatch_error(:invalid_dispatch_callback, "transport dispatch callback returned an invalid result")}
        end

      _other ->
        {:error, pre_dispatch_error(:invalid_dispatch_callback, "transport dispatch callback is invalid")}
    end
  catch
    _kind, _reason ->
      {:error, pre_dispatch_error(:dispatch_evidence_failed, "transport dispatch evidence failed")}
  end

  defp transport_wire_options(opts), do: Keyword.delete(opts, :before_dispatch)

  defp prepare_request(request, opts, %{pin_resolved?: false} = policy) do
    with {:ok, canonical_url} <- policy_result(URLPolicy.validate(request.url, policy)),
         :ok <- validate_request_headers(request.headers, opts) do
      {:ok, %{request | url: canonical_url}, put_mint_connect_options(opts), nil}
    end
  end

  defp prepare_request(%Request{} = request, opts, policy) do
    with :ok <- validate_request_headers(request.headers, opts),
         {:ok, target} <- policy_result(URLPolicy.resolve_target(request.url, policy)) do
      uri = URI.parse(target.url)
      address = target.address |> :inet.ntoa() |> List.to_string()
      pinned_url = uri |> Map.put(:host, address) |> Map.put(:authority, nil) |> URI.to_string()
      headers = put_header(request.headers, "host", authority(target, uri.scheme))

      # A strict pinned request must be direct. Proxy and caller-supplied TLS
      # options would sever the binding between the validated address, Host,
      # SNI, and certificate verification. HTTP/1 is deliberate: Finch may
      # transparently replay an HTTP/2 request while a pool is draining.
      stream_idle_timeout =
        Keyword.get(opts, :stream_idle_timeout, Keyword.get(opts, :timeout, 15_000))

      connect_options = [
        hostname: target.host,
        protocols: [:http1],
        timeout: Keyword.get(opts, :connect_timeout, min(stream_idle_timeout, 5_000))
      ]

      wire_opts =
        opts
        |> Keyword.put(:connect_options, connect_options)
        |> put_mint_connect_options()
        |> Keyword.drop([:unix_socket, :inet6])

      {:ok, %{request | url: pinned_url, headers: headers}, wire_opts, target}
    end
  end

  defp policy_result({:error, %CoreError{} = error}),
    do: {:error, pre_dispatch_error(error.type, error.message, error.details)}

  defp policy_result(result), do: result

  # Mint enforces the response header limit while it reads the headers. HTTP
  # connection options also keep the request off the pool provider calls
  # share: `Transport.ReqFinch` runs it on a bounded, isolated pool, so URLs
  # from users or models can't grow the shared one.
  defp put_mint_connect_options(opts) do
    Keyword.put(opts, :mint_connect_options,
      max_header_list_size: Keyword.get(opts, :max_response_header_bytes, @default_maximum_header_bytes)
    )
  end

  defp annotate_target(response, nil), do: response

  defp annotate_target(%Response{} = response, target) do
    metadata =
      Map.merge(response.metadata, %{
        requested_url: target.url,
        requested_host: target.host,
        connected_address: target.address,
        connected_port: target.port,
        resolved_addresses: target.address_set,
        dial_plan_hash: dial_plan_hash(target),
        tls_hostname: target.host,
        host_authority: authority(target, URI.parse(target.url).scheme),
        peer_evidence: :response_from_pinned_literal,
        write_evidence: :response_observed
      })

    %{response | metadata: metadata}
  end

  defp put_header(headers, key, value) do
    [{key, value} | Enum.reject(headers, fn {name, _value} -> String.downcase(name) == key end)]
  end

  defp authority(target, scheme) do
    host = authority_host(target.host)
    if target.port == default_port(scheme), do: host, else: "#{host}:#{target.port}"
  end

  defp authority_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) == 8 -> "[#{host}]"
      _other -> host
    end
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp transport_options(opts, policy) do
    timeout = Keyword.get(opts, :timeout, policy.timeout)
    stream_idle_timeout = Keyword.get(opts, :stream_idle_timeout, timeout)
    total_timeout = Keyword.get(opts, :total_timeout, timeout)

    opts
    |> Keyword.drop([:transport, :url_policy, :unix_socket, :inet6])
    |> Keyword.put_new(:timeout, timeout)
    |> Keyword.put_new(:stream_idle_timeout, stream_idle_timeout)
    |> Keyword.put_new(:total_timeout, total_timeout)
    |> Keyword.put_new(:raw_response?, true)
    |> Keyword.put_new(:max_response_bytes, policy.max_bytes)
  end

  defp validate_request_headers(headers, opts) do
    maximum = Keyword.get(opts, :max_request_header_bytes, @default_maximum_header_bytes)

    case header_bytes(headers, maximum) do
      {:ok, _bytes} ->
        :ok

      {:error, :too_large} ->
        {:error,
         pre_dispatch_error(
           :request_headers_too_large,
           "transport request headers exceeded the configured byte limit"
         )}

      {:error, :invalid} ->
        {:error, pre_dispatch_error(:invalid_request_headers, "transport request headers are malformed")}
    end
  end

  defp validate_response_headers(%Response{headers: headers}, opts) do
    maximum = Keyword.get(opts, :max_response_header_bytes, @default_maximum_header_bytes)

    case header_bytes(headers, maximum) do
      {:error, :too_large} ->
        {:error,
         Error.new(:response_headers_too_large, "transport response headers exceeded the configured byte limit")}

      {:error, :invalid} ->
        {:error, Error.new(:invalid_response_headers, "transport returned malformed response headers")}

      {:ok, _bytes} ->
        :ok
    end
  end

  defp dial_plan_hash(target) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({target.url, target.host, target.port, target.address_set}, [:deterministic])
    )
    |> Base.encode16(case: :lower)
  end

  defp header_bytes(headers, maximum) when is_list(headers) and is_integer(maximum) and maximum > 0 do
    Enum.reduce_while(headers, {:ok, 0}, fn
      {name, value}, {:ok, acc} when is_binary(name) and is_binary(value) ->
        if valid_header_name?(name) and valid_header_value?(value) do
          next = acc + byte_size(name) + byte_size(value) + 4
          if next <= maximum, do: {:cont, {:ok, next}}, else: {:halt, {:error, :too_large}}
        else
          {:halt, {:error, :invalid}}
        end

      _header, _acc ->
        {:halt, {:error, :invalid}}
    end)
  end

  defp header_bytes(_headers, _maximum), do: {:error, :invalid}

  defp valid_header_name?(name) do
    name != "" and
      Enum.all?(:binary.bin_to_list(name), fn byte ->
        byte in ?0..?9 or byte in ?a..?z or byte in ?A..?Z or byte in ~c"!#$%&'*+-.^_`|~"
      end)
  end

  defp valid_header_value?(value) do
    not String.contains?(value, ["\r", "\n", <<0>>])
  end

  defp pre_dispatch_error(type, message, details \\ %{}) do
    Error.new(type, message, Map.merge(details, %{stage: :pre_dispatch, bytes_written: 0}))
  end

  defp post_dispatch_error(%Error{} = error) do
    details =
      error.details
      |> Map.put(:stage, :post_dispatch_unknown)
      |> Map.put(:bytes_written, :unknown)

    %{error | details: details}
  end

  defp header(headers, key) do
    Enum.find_value(headers, fn
      {header, value} when is_binary(header) ->
        if String.downcase(header) == key, do: value

      _other ->
        nil
    end)
  end

  defp absolute_redirect_url(nil, _base_url), do: nil
  defp absolute_redirect_url("http" <> _rest = url, _base_url), do: url

  defp absolute_redirect_url(location, base_url) when is_binary(location) do
    base_url
    |> URI.parse()
    |> URI.merge(location)
    |> URI.to_string()
  rescue
    _exception -> location
  end

  defp redirect_request(%Request{} = request, location) do
    headers =
      if same_origin?(request.url, location) do
        request.headers
      else
        Enum.filter(request.headers, fn {name, _value} ->
          String.downcase(name) in @cross_origin_redirect_headers
        end)
      end

    %{request | url: location, headers: headers}
  end

  defp same_origin?(left, right) do
    left = URI.parse(left)
    right = URI.parse(right)

    {left.scheme, left.host, left.port || default_port(left.scheme)} ==
      {right.scheme, right.host, right.port || default_port(right.scheme)}
  end
end
