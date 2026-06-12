defmodule BeamWeaver.Agent.Protocol.ReqClient do
  @moduledoc "Req-backed Agent Protocol client used by async DeepAgents subagents."

  @behaviour BeamWeaver.Agent.Protocol.Client

  @impl true
  def start_task(subagent, payload, _opts) do
    request(:post, subagent, "/runs", json: payload)
  end

  @impl true
  def check_task(subagent, task_id, _opts) do
    request(:get, subagent, "/runs/#{URI.encode(to_string(task_id))}")
  end

  @impl true
  def update_task(subagent, task_id, message, _opts) do
    request(:post, subagent, "/runs/#{URI.encode(to_string(task_id))}/input", json: %{message: message})
  end

  @impl true
  def cancel_task(subagent, task_id, _opts) do
    request(:post, subagent, "/runs/#{URI.encode(to_string(task_id))}/cancel")
  end

  defp request(method, subagent, path, opts \\ [])

  defp request(method, %{url: url, headers: headers}, path, opts)
       when is_binary(url) do
    request_opts =
      opts
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, endpoint(url, path))
      |> Keyword.put(:headers, headers || %{})

    case Req.request(request_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(_method, _subagent, _path, _opts), do: {:error, :missing_url}

  defp endpoint(url, path), do: String.trim_trailing(url, "/") <> path

  defp normalize_body(body) when is_map(body), do: body
  defp normalize_body(body) when is_binary(body), do: BeamWeaver.JSON.decode!(body)
  defp normalize_body(_body), do: %{}
end
