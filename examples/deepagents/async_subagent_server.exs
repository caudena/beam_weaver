Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.AsyncSubagentServer.Client do
  @behaviour BeamWeaver.Agent.Protocol.Client

  def start_task(_subagent, payload, _opts) do
    description =
      get_in(payload, [:input, :description]) || get_in(payload, ["input", "description"])

    {:ok,
     %{
       "thread_id" => "thread-demo",
       "run_id" => "run-demo",
       "status" => "running",
       "description" => description
     }}
  end

  def check_task(_subagent, task_id, _opts),
    do: {:ok, %{"thread_id" => task_id, "run_id" => "run-demo", "status" => "success"}}

  def update_task(_subagent, task_id, message, _opts),
    do: {:ok, %{"thread_id" => task_id, "status" => "running", "latest_update" => message}}

  def cancel_task(_subagent, task_id, _opts),
    do: {:ok, %{"thread_id" => task_id, "status" => "cancelled"}}
end

defmodule BeamWeaver.Examples.DeepAgents.AsyncSubagentServer do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Agent.Subagent.AsyncSpec
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    async_researcher =
      AsyncSpec.new(
        name: "remote-researcher",
        description: "Long-running hosted researcher exposed over Agent Protocol.",
        graph_id: "researcher",
        url: "http://localhost:2024",
        client: BeamWeaver.Examples.DeepAgents.AsyncSubagentServer.Client
      )

    {:ok, agent} =
      Support.create(
        model: Support.model("async_subagent_server: remote researcher registered"),
        async_subagents: [async_researcher]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("Register the async researcher.")]})

    IO.puts(Message.text(List.last(messages)))
  end
end

BeamWeaver.Examples.DeepAgents.AsyncSubagentServer.run()
