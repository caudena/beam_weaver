defmodule BeamWeaver.Agent.Protocol.Client do
  @moduledoc """
  Minimal Agent Protocol client behaviour for async subagents: start, check, update and cancel remote runs.

  Every callback gets `parent:` in its opts, which says which agent made the
  call (see `t:parent/0`). The caller of the parent's run sets its thread
  config, so a client that acts on these values checks them first.
  """

  alias BeamWeaver.Agent.Subagent.AsyncSpec

  @typedoc """
  The agent behind a client call:

    * `:thread_id` - the parent's thread, from its run's config; `nil` without one
    * `:run_id` - the parent's run; `nil` outside a run
    * `:tool_call_id` - the async tool call that makes this call
    * `:subagent_name` - the subagent's `name` as the parent declared it
    * `:trace_id`, `:trace_run_id` - the parent's trace and the trace run of
      the tool call, to nest the subagent's trace under; `nil` when tracing is off
  """
  @type parent :: %{
          thread_id: String.t() | nil,
          run_id: String.t() | nil,
          tool_call_id: String.t() | nil,
          subagent_name: String.t(),
          trace_id: String.t() | nil,
          trace_run_id: String.t() | nil
        }

  @callback start_task(AsyncSpec.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback check_task(AsyncSpec.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback update_task(AsyncSpec.t(), String.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback cancel_task(AsyncSpec.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}

  def start_task(client, subagent, payload, opts), do: client.start_task(subagent, payload, opts)

  def check_task(client, subagent, task_id, opts), do: client.check_task(subagent, task_id, opts)

  def update_task(client, subagent, task_id, message, opts),
    do: client.update_task(subagent, task_id, message, opts)

  def cancel_task(client, subagent, task_id, opts),
    do: client.cancel_task(subagent, task_id, opts)
end
