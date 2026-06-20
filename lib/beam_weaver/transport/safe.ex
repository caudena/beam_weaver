defmodule BeamWeaver.Transport.Safe do
  @moduledoc """
  URL-policy enforcing transport wrapper.

  This is the native BeamWeaver SSRF boundary: callers keep using the
  `BeamWeaver.Transport` behaviour, while this wrapper validates the original
  request URL and every followed redirect through `BeamWeaver.Transport.URLPolicy`.
  """

  @behaviour BeamWeaver.Transport

  alias BeamWeaver.Core.Error, as: CoreError
  alias BeamWeaver.Provider.Options, as: ProviderOptions
  alias BeamWeaver.Transport
  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response
  alias BeamWeaver.Transport.URLPolicy

  @redirect_statuses 300..399

  @impl true
  def request(%Request{} = request, opts) do
    policy = URLPolicy.new(Keyword.get(opts, :url_policy, opts))
    transport = ProviderOptions.default_transport(Keyword.get(opts, :transport))
    opts = Keyword.drop(opts, [:transport, :url_policy])

    with :ok <- validate_url(request.url, policy) do
      do_request(transport, request, opts, policy, 0)
    end
  end

  @impl true
  def stream(%Request{} = request, opts, on_chunk) when is_function(on_chunk, 1) do
    case stream_reduce(request, opts, :ok, fn acc, chunk ->
           on_chunk.(chunk)
           acc
         end) do
      {:ok, response, _acc} -> {:ok, response}
      {:error, %Error{} = error, _acc} -> {:error, error}
    end
  end

  @impl true
  def stream_reduce(%Request{} = request, opts, acc, reducer) when is_function(reducer, 2) do
    policy = URLPolicy.new(Keyword.get(opts, :url_policy, opts))
    transport = ProviderOptions.default_transport(Keyword.get(opts, :transport))
    opts = Keyword.drop(opts, [:transport, :url_policy])

    case validate_url(request.url, policy) do
      :ok -> do_stream_reduce(transport, request, opts, acc, reducer, policy, 0)
      {:error, %Error{} = error} -> {:error, error, acc}
    end
  end

  defp do_request(transport, %Request{} = request, opts, policy, redirect_count) do
    case Transport.request(transport, request, opts) do
      {:ok, %Response{} = response} ->
        maybe_follow_redirect(transport, request, response, opts, policy, redirect_count)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp maybe_follow_redirect(transport, request, response, opts, policy, redirect_count) do
    location = response.headers |> header("location") |> absolute_redirect_url(request.url)

    cond do
      response.status not in @redirect_statuses or is_nil(location) ->
        {:ok, response}

      not policy.follow_redirects? ->
        {:ok, response}

      redirect_count >= policy.max_redirects ->
        {:error,
         Error.new(:too_many_redirects, "transport exceeded the configured redirect limit", %{
           url: request.url,
           max_redirects: policy.max_redirects
         })}

      true ->
        with :ok <- validate_url(location, policy) do
          do_request(transport, %{request | url: location}, opts, policy, redirect_count + 1)
        end
    end
  end

  defp do_stream_reduce(transport, %Request{} = request, opts, acc, reducer, policy, redirect_count) do
    case Transport.stream_reduce(transport, request, opts, acc, reducer) do
      {:ok, %Response{} = response, result_acc} ->
        maybe_follow_redirect_stream(
          transport,
          request,
          response,
          opts,
          acc,
          result_acc,
          reducer,
          policy,
          redirect_count
        )

      {:error, %Error{} = error, error_acc} ->
        {:error, error, error_acc}
    end
  end

  defp maybe_follow_redirect_stream(
         transport,
         request,
         response,
         opts,
         original_acc,
         result_acc,
         reducer,
         policy,
         redirect_count
       ) do
    location = response.headers |> header("location") |> absolute_redirect_url(request.url)

    cond do
      response.status not in @redirect_statuses or is_nil(location) ->
        {:ok, response, result_acc}

      not policy.follow_redirects? ->
        {:ok, response, result_acc}

      redirect_count >= policy.max_redirects ->
        {:error,
         Error.new(:too_many_redirects, "transport exceeded the configured redirect limit", %{
           url: request.url,
           max_redirects: policy.max_redirects
         }), original_acc}

      true ->
        case validate_url(location, policy) do
          :ok ->
            do_stream_reduce(
              transport,
              %{request | url: location},
              opts,
              original_acc,
              reducer,
              policy,
              redirect_count + 1
            )

          {:error, %Error{} = error} ->
            {:error, error, original_acc}
        end
    end
  end

  defp validate_url(url, policy) do
    case URLPolicy.validate(url, policy) do
      {:ok, _url} ->
        :ok

      {:error, %CoreError{} = error} ->
        {:error, Error.new(error.type, error.message, error.details)}
    end
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
end
