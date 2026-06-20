defmodule BeamWeaver.Agent.Middleware.AsyncSubagentsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.AsyncSubagents
  alias BeamWeaver.Graph.Command

  defmodule LiveSuccessClient do
    @behaviour BeamWeaver.Agent.Protocol.Client

    @impl true
    def start_task(_subagent, _payload, _opts), do: {:ok, %{}}

    @impl true
    def check_task(_subagent, _task_id, _opts), do: {:ok, %{status: "success"}}

    @impl true
    def update_task(_subagent, _task_id, _message, _opts), do: {:ok, %{}}

    @impl true
    def cancel_task(_subagent, _task_id, _opts), do: {:ok, %{}}
  end

  defp middleware do
    AsyncSubagents.new(subagents: [%{name: "researcher", client: LiveSuccessClient, graph_id: "g", url: "http://x"}])
  end

  defp list_tool(middleware) do
    Enum.find(AsyncSubagents.tools(middleware), &(&1.name == "list_async_tasks"))
  end

  defp state_with_running_task do
    %{
      async_tasks: %{
        "task-1" => %{
          id: "task-1",
          task_id: "task-1",
          subagent_name: "researcher",
          status: "running"
        }
      }
    }
  end

  defp run(tool, input), do: tool.handler.(input, [])

  test "success filter selects a task whose live status became success" do
    tool = list_tool(middleware())

    input = %{
      state: state_with_running_task(),
      tool_call_id: "call-1",
      status_filter: "success"
    }

    assert %Command{update: %{messages: [message]}} = run(tool, input)
    assert message.content =~ "task_id: task-1"
    assert message.content =~ "status: success"
  end

  test "running filter excludes a task that has completed remotely" do
    tool = list_tool(middleware())

    input = %{
      state: state_with_running_task(),
      tool_call_id: "call-2",
      status_filter: "running"
    }

    assert run(tool, input) == "No async subagent tasks tracked."
  end
end
