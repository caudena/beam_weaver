# Async subagents: hand a long job to an agent on another server, get a task id
# back at once, and check on the task later.
#
# `url:` points at an Agent Protocol server, and the default client talks HTTP
# to it. This example plugs in a local client that answers the way a server
# would, so it runs without one.
#
#   mix run examples/deepagents/async_subagent_server.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.AsyncSubagentServer.Client do
  # Stands in for the server: a task starts running and is done by the first check.
  @behaviour BeamWeaver.Agent.Protocol.Client

  @impl true
  def start_task(_subagent, _payload, _opts), do: {:ok, %{"thread_id" => "thread-42", "status" => "running"}}

  @impl true
  def check_task(_subagent, task_id, _opts) do
    {:ok,
     %{
       "thread_id" => task_id,
       "status" => "success",
       "result" => "A supervisor restarts a crashed child process; :one_for_one restarts only that child."
     }}
  end

  @impl true
  def update_task(_subagent, task_id, message, _opts),
    do: {:ok, %{"thread_id" => task_id, "status" => "running", "latest_update" => message}}

  @impl true
  def cancel_task(_subagent, task_id, _opts), do: {:ok, %{"thread_id" => task_id, "status" => "cancelled"}}
end

defmodule BeamWeaver.Examples.DeepAgents.AsyncSubagentServer do
  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Subagent.AsyncSpec
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    researcher =
      AsyncSpec.new(
        name: "remote-researcher",
        description: "Researches a topic in the background on a remote server.",
        graph_id: "researcher",
        url: "http://localhost:2024",
        client: BeamWeaver.Examples.DeepAgents.AsyncSubagentServer.Client
      )

    {:ok, agent} = Support.create(model: Support.model(), async_subagents: [researcher])

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{
        messages: [
          "Ask the remote researcher how OTP supervisors restart crashed processes. " <>
            "Then check the task once and tell me its id, status and result."
        ]
      })

    IO.puts(Message.text(List.last(messages)))
    Support.assert_tools_called!(messages, ["start_async_task", "check_async_task"])
  end
end

BeamWeaver.Examples.DeepAgents.AsyncSubagentServer.run()
