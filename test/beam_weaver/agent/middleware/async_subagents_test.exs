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

  defmodule TrackingClient do
    @behaviour BeamWeaver.Agent.Protocol.Client

    @impl true
    def start_task(_subagent, _payload, _opts), do: {:ok, %{}}

    @impl true
    def check_task(subagent, task_id, _opts) do
      send(subagent.headers.parent, {:checked_async_task, task_id})
      {:ok, %{status: "success"}}
    end

    @impl true
    def update_task(_subagent, _task_id, _message, _opts), do: {:ok, %{}}

    @impl true
    def cancel_task(_subagent, _task_id, _opts), do: {:ok, %{}}
  end

  defp middleware do
    AsyncSubagents.new(subagents: [%{name: "researcher", client: LiveSuccessClient, graph_id: "g", url: "http://x"}])
  end

  defp tracking_middleware do
    AsyncSubagents.new(
      subagents: [
        %{
          name: "researcher",
          client: TrackingClient,
          graph_id: "g",
          url: "http://x",
          headers: %{parent: self()}
        }
      ]
    )
  end

  defp start_tool(middleware) do
    Enum.find(AsyncSubagents.tools(middleware), &(&1.name == "start_async_task"))
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

  test "start task generates stable fallback IDs and native trace metadata when remote IDs are missing" do
    tool = start_tool(middleware())

    assert %Command{update: %{async_tasks: tasks, messages: [message]}} =
             run(tool, %{
               state: %{},
               tool_call_id: "call-start",
               subagent_type: "researcher",
               description: "collect sources"
             })

    assert [{task_id, task}] = Map.to_list(tasks)
    assert String.starts_with?(task_id, "async-")
    assert task.thread_id == task_id
    assert task.run_id == task_id
    assert task.description == "collect sources"

    assert message.tool_call_id == "call-start"

    assert message.metadata.async_subagent == %{
             id: task_id,
             task_id: task_id,
             subagent_name: "researcher",
             graph_id: "g",
             thread_id: task_id,
             run_id: task_id,
             status: "running"
           }
  end

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

  test "list task refresh skips terminal tasks and refreshes only active tasks" do
    tool = list_tool(tracking_middleware())

    input = %{
      state: %{
        async_tasks: %{
          "done-1" => %{id: "done-1", task_id: "done-1", subagent_name: "researcher", status: "success"},
          "run-1" => %{id: "run-1", task_id: "run-1", subagent_name: "researcher", status: "running"}
        }
      },
      tool_call_id: "call-list",
      status_filter: "all"
    }

    assert %Command{update: %{async_tasks: tasks, messages: [message]}} = run(tool, input)

    assert_received {:checked_async_task, "run-1"}
    refute_received {:checked_async_task, "done-1"}
    assert tasks["done-1"].status == "success"
    assert tasks["run-1"].status == "success"

    assert Enum.any?(message.metadata.async_subagents, &(&1.task_id == "done-1"))
    assert Enum.any?(message.metadata.async_subagents, &(&1.task_id == "run-1" and &1.status == "success"))
  end
end
