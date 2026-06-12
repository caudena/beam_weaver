defmodule BeamWeaver.Agent.Protocol.Client do
  @moduledoc "Minimal Agent Protocol client behaviour for async DeepAgents subagents."

  alias BeamWeaver.Agent.Subagent.AsyncSpec

  @callback start_task(AsyncSpec.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback check_task(AsyncSpec.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback update_task(AsyncSpec.t(), String.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback cancel_task(AsyncSpec.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}

  def start_task(nil, _subagent, _payload, _opts), do: {:ok, %{}}
  def start_task(client, subagent, payload, opts), do: client.start_task(subagent, payload, opts)

  def check_task(nil, _subagent, _task_id, _opts), do: {:ok, %{}}
  def check_task(client, subagent, task_id, opts), do: client.check_task(subagent, task_id, opts)

  def update_task(nil, _subagent, _task_id, _message, _opts), do: {:ok, %{}}

  def update_task(client, subagent, task_id, message, opts),
    do: client.update_task(subagent, task_id, message, opts)

  def cancel_task(nil, _subagent, _task_id, _opts), do: {:ok, %{}}

  def cancel_task(client, subagent, task_id, opts),
    do: client.cancel_task(subagent, task_id, opts)
end
