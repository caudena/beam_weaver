defmodule BeamWeaver.Agent.Protocol.ReqClient do
  @moduledoc """
  Req-backed Agent Protocol client used by async subagents.

  Starting and updating a task send the `parent:` reference as the run's
  `metadata`: the `subagent_name` and, when the parent has a thread, its
  `parent_thread_id`, merged with the metadata already in the body. Trace ids
  stay in this application.
  """

  @behaviour BeamWeaver.Agent.Protocol.Client

  alias BeamWeaver.MapShape

  @impl true
  def start_task(subagent, payload, opts) do
    request(:post, subagent, "/runs", Keyword.put(opts, :json, put_parent(payload, opts[:parent])))
  end

  @impl true
  def check_task(subagent, task_id, opts) do
    request(:get, subagent, "/runs/#{path_segment(task_id)}", opts)
  end

  @impl true
  def update_task(subagent, task_id, message, opts) do
    body = put_parent(%{message: message}, opts[:parent])
    request(:post, subagent, "/runs/#{path_segment(task_id)}/input", Keyword.put(opts, :json, body))
  end

  @impl true
  def cancel_task(subagent, task_id, opts) do
    request(:post, subagent, "/runs/#{path_segment(task_id)}/cancel", opts)
  end

  defp request(method, %{url: url, headers: headers}, path, opts)
       when is_binary(url) do
    {request_fun, opts} = Keyword.pop(opts, :request_fun, &Req.request/1)

    request_opts =
      opts
      |> Keyword.delete(:parent)
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, endpoint(url, path))
      |> Keyword.put(:headers, headers || %{})

    case request_fun.(request_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: normalize_body(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(_method, _subagent, _path, _opts), do: {:error, :missing_url}

  defp put_parent(body, nil), do: body

  defp put_parent(body, parent) do
    metadata =
      MapShape.reject_nil_values(%{subagent_name: parent[:subagent_name], parent_thread_id: parent[:thread_id]})

    Map.update(body, :metadata, metadata, &Map.merge(&1, metadata))
  end

  defp endpoint(url, path), do: String.trim_trailing(url, "/") <> path

  defp normalize_body(body) when is_map(body), do: body

  defp normalize_body(body) when is_binary(body) do
    case BeamWeaver.JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} -> %{"body" => decoded}
      {:error, _error} -> %{"body" => body}
    end
  end

  defp normalize_body(_body), do: %{}

  defp path_segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
