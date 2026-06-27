defmodule BeamWeaver.Agent.Protocol.ReqClient do
  @moduledoc "Req-backed Agent Protocol client used by async DeepAgents subagents."

  @behaviour BeamWeaver.Agent.Protocol.Client

  @impl true
  def start_task(subagent, payload, opts) do
    request(:post, subagent, "/runs", Keyword.put(opts, :json, payload))
  end

  @impl true
  def check_task(subagent, task_id, opts) do
    request(:get, subagent, "/runs/#{path_segment(task_id)}", opts)
  end

  @impl true
  def update_task(subagent, task_id, message, opts) do
    request(:post, subagent, "/runs/#{path_segment(task_id)}/input", Keyword.put(opts, :json, %{message: message}))
  end

  @impl true
  def cancel_task(subagent, task_id, opts) do
    request(:post, subagent, "/runs/#{path_segment(task_id)}/cancel", opts)
  end

  defp request(method, subagent, path, opts)

  defp request(method, %{url: url, headers: headers}, path, opts)
       when is_binary(url) do
    {request_fun, opts} = Keyword.pop(opts, :request_fun, &Req.request/1)

    request_opts =
      opts
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
