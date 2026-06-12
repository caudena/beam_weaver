defmodule BeamWeaver.Transport.ReqFinch do
  @moduledoc """
  Live transport implementation using Req and Finch.
  """

  @behaviour BeamWeaver.Transport

  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  @impl true
  def request(%Request{} = request, opts) do
    request
    |> req_options(opts)
    |> Req.request()
    |> normalize_result()
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
    request
    |> req_options(opts)
    |> Keyword.put(:into, stream_handler(acc, reducer))
    |> Req.request()
    |> normalize_stream_reduce_result(acc)
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
    [
      method: request.method,
      url: request.url,
      headers: request.headers,
      finch: Keyword.get(opts, :finch, BeamWeaver.Transport.Finch),
      receive_timeout: Keyword.get(opts, :timeout, Keyword.get(request.options, :timeout, 15_000)),
      retry: false
    ]
    |> maybe_put_finch_private(opts)
    |> maybe_put_body(request)
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

  defp stream_handler(acc, reducer) do
    fn
      {:data, data}, {request, response} when response.status in 200..299 ->
        acc = reducer.(Map.get(response.private, :beam_weaver_stream_acc, acc), data)

        {:cont, {request, put_in(response.private[:beam_weaver_stream_acc], acc)}}

      {:data, data}, {request, response} ->
        {:cont, {request, append_body(response, data)}}
    end
  end

  defp append_body(%Req.Response{body: body} = response, data) when is_binary(body) do
    %{response | body: body <> data}
  end

  defp append_body(%Req.Response{} = response, data) do
    %{response | body: IO.iodata_to_binary([response.body || "", data])}
  end

  defp normalize_result({:ok, %Req.Response{} = response}) do
    {:ok,
     Response.new(
       status: response.status,
       headers: response.headers,
       body: response.body,
       metadata: %{source: :live}
     )}
  end

  defp normalize_result({:error, error}) do
    {:error,
     Error.new(:transport_failure, "transport request failed", %{
       reason: inspect(error)
     })}
  end

  defp normalize_stream_reduce_result({:ok, %Req.Response{status: status} = response}, acc)
       when status in 200..299 do
    stream_acc = Map.get(response.private, :beam_weaver_stream_acc, acc)

    response =
      response
      |> Map.update!(:private, &Map.delete(&1, :beam_weaver_stream_acc))
      |> Map.put(:body, "")

    {:ok, transport_response(response), stream_acc}
  end

  defp normalize_stream_reduce_result({:ok, %Req.Response{} = response}, acc),
    do: {:ok, transport_response(response), acc}

  defp normalize_stream_reduce_result({:error, error}, acc) do
    {:error,
     Error.new(:transport_failure, "transport request failed", %{
       reason: inspect(error)
     }), acc}
  end

  defp transport_response(%Req.Response{} = response) do
    Response.new(
      status: response.status,
      headers: response.headers,
      body: response.body,
      metadata: %{source: :live}
    )
  end
end
