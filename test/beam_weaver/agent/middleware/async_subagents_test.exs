defmodule BeamWeaver.Agent.Middleware.AsyncSubagentsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware.AsyncSubagents
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Tracing

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

  # Sends the test process each call with its opts.
  defmodule ParentClient do
    @behaviour BeamWeaver.Agent.Protocol.Client

    @impl true
    def start_task(subagent, _payload, opts),
      do: reply(subagent, :start, opts, %{thread_id: "task-1", status: "running"})

    @impl true
    def check_task(subagent, task_id, opts), do: reply(subagent, :check, opts, %{thread_id: task_id, status: "running"})

    @impl true
    def update_task(subagent, task_id, _message, opts),
      do: reply(subagent, :update, opts, %{thread_id: task_id, status: "running"})

    @impl true
    def cancel_task(subagent, task_id, opts),
      do: reply(subagent, :cancel, opts, %{thread_id: task_id, status: "cancelled"})

    defp reply(subagent, call, opts, remote) do
      send(subagent.headers.test, {:client_call, call, opts})
      {:ok, remote}
    end
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

  defp check_tool(middleware) do
    Enum.find(AsyncSubagents.tools(middleware), &(&1.name == "check_async_task"))
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

  test "each task tool offers only its own arguments" do
    # Every tool offered all six arguments, and starting a task didn't require
    # a subagent_type.
    schemas =
      Map.new(AsyncSubagents.tools(middleware()), fn tool ->
        schema = Tool.input_schema(tool)
        {Tool.name(tool), {schema["properties"] |> Map.keys() |> Enum.sort(), schema["required"]}}
      end)

    assert schemas == %{
             "start_async_task" => {["description", "subagent_type"], ["subagent_type", "description"]},
             "check_async_task" => {["task_id"], ["task_id"]},
             "update_async_task" => {["message", "task_id"], ["task_id", "message"]},
             "cancel_async_task" => {["task_id"], ["task_id"]},
             "list_async_tasks" => {["status_filter"], []}
           }
  end

  test "checking and listing tasks warn that an earlier status may be out of date" do
    descriptions = Map.new(AsyncSubagents.tools(middleware()), &{Tool.name(&1), Tool.description(&1)})

    assert descriptions["check_async_task"] =~ "may be out of date"
    assert descriptions["list_async_tasks"] =~ "may be out of date"
  end

  test "adds no system prompt section unless given a system_prompt" do
    request = ModelRequest.new(system_prompt: "base")

    assert AsyncSubagents.wrap_model_call(middleware(), request, & &1) == request
  end

  test "a system_prompt adds a section listing the async subagents" do
    middleware =
      AsyncSubagents.new(
        subagents: [%{name: "researcher", description: "Researches.", client: LiveSuccessClient, graph_id: "g"}],
        system_prompt: "Start long research as an async task."
      )

    assert %ModelRequest{system_message: %Message{content: prompt}} =
             AsyncSubagents.wrap_model_call(middleware, ModelRequest.new(system_prompt: "base"), & &1)

    assert prompt =~ "base\n\nStart long research as an async task."
    assert prompt =~ "- researcher: Researches."
  end

  test "starting a task tells the model to hand the full task ID to the user and not poll" do
    description = middleware() |> start_tool() |> Tool.description()

    assert description =~ "runs in the background"
    assert description =~ "Give the user the full task ID"
    assert description =~ "never in a loop"
  end

  test "checking and listing refresh an interrupted task, which can be resumed on the server" do
    # Listing took `interrupted` as final and never asked the server again, so
    # a task resumed there stayed interrupted.
    interrupted = %{id: "task-1", task_id: "task-1", subagent_name: "researcher", status: "interrupted"}
    input = %{state: %{async_tasks: %{"task-1" => interrupted}}, tool_call_id: "call-1"}

    assert %Command{update: %{async_tasks: %{"task-1" => listed}}} = run(list_tool(tracking_middleware()), input)
    assert_received {:checked_async_task, "task-1"}
    assert listed.status == "success"

    assert %Command{update: %{async_tasks: %{"task-1" => checked}}} =
             run(check_tool(tracking_middleware()), Map.put(input, :task_id, "task-1"))

    assert_received {:checked_async_task, "task-1"}
    assert checked.status == "success"
  end

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
    # Only the refreshed task is written back.
    assert Map.keys(tasks) == ["run-1"]
    assert tasks["run-1"].status == "success"

    assert Enum.any?(message.metadata.async_subagents, &(&1.task_id == "done-1"))
    assert Enum.any?(message.metadata.async_subagents, &(&1.task_id == "run-1" and &1.status == "success"))
  end

  test "parallel task tools keep each other's changes" do
    # Each call wrote the whole `async_tasks` map, so the update of B wrote A
    # back as it was before the cancel, and the cancel was lost.
    calls =
      FakeChatModel.tool_calls([
        {"cancel_async_task", %{"task_id" => "A"}},
        {"update_async_task", %{"task_id" => "B", "message" => "More detail."}}
      ])

    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{responses: [calls, "Done."]},
        middleware: [
          AsyncSubagents.new(
            subagents: [%{name: "researcher", description: "Researches.", graph_id: "g", client: LiveSuccessClient}]
          )
        ]
      )

    running = fn id -> %{id: id, task_id: id, subagent_name: "researcher", status: "running"} end

    assert {:ok, result} =
             Agent.invoke(agent, %{
               messages: ["Cancel A and add detail to B."],
               async_tasks: %{"A" => running.("A"), "B" => running.("B")}
             })

    assert result.async_tasks["A"].status == "cancelled"
    assert [%{message: "More detail."}] = result.async_tasks["B"].updates
  end

  test "an async subagent needs a client or a url" do
    assert_raise ArgumentError, ~r/async subagent "researcher" needs a client or a url/, fn ->
      AsyncSubagents.new(subagents: [%{name: "researcher", description: "Researches.", graph_id: "g"}])
    end

    assert {:error, %BeamWeaver.Core.Error{type: :invalid_agent, message: message}} =
             Agent.build(
               model: %FakeChatModel{response: "Done."},
               async_subagents: [%{name: "researcher", description: "Researches.", graph_id: "g"}]
             )

    assert message =~ "needs a client or a url"
  end

  defp parent_middleware do
    AsyncSubagents.new(
      subagents: [
        %{name: "researcher", description: "Researches.", graph_id: "g", client: ParentClient, headers: %{test: self()}}
      ]
    )
  end

  test "every client call learns which thread, run, tool call and trace launched it" do
    # Every callback got `opts = []`, so a client couldn't tell which agent,
    # thread or tool call a task belonged to.
    responses = [
      FakeChatModel.tool_call("start_async_task", %{
        "subagent_type" => "researcher",
        "description" => "Collect sources."
      }),
      FakeChatModel.tool_call("check_async_task", %{"task_id" => "task-1"}),
      FakeChatModel.tool_call("update_async_task", %{"task_id" => "task-1", "message" => "Only this year."}),
      FakeChatModel.tool_call("list_async_tasks", %{}),
      FakeChatModel.tool_call("cancel_async_task", %{"task_id" => "task-1"}),
      "Done."
    ]

    {:ok, agent} = Agent.build(model: %FakeChatModel{responses: responses}, middleware: [parent_middleware()])

    {result, trace_id} =
      Tracing.with_run("support chat", fn ->
        result =
          Agent.invoke(agent, %{messages: ["Research refunds."]},
            config: %{"configurable" => %{"thread_id" => "ticket-42"}},
            run_id: "parent-run"
          )

        {result, Tracing.capture_context().trace_id}
      end)

    assert {:ok, result} = result
    tool_calls = for %Message{role: :tool} = message <- result.messages, do: {message.name, message.tool_call_id}

    for {call, {tool_name, tool_call_id}} <- Enum.zip([:start, :check, :update, :check, :cancel], tool_calls) do
      assert_received {:client_call, ^call, opts}

      assert %{
               thread_id: "ticket-42",
               run_id: "parent-run",
               tool_call_id: ^tool_call_id,
               subagent_name: "researcher",
               trace_id: ^trace_id,
               trace_run_id: trace_run_id
             } = opts[:parent]

      assert {:ok, %{name: ^tool_name, trace_id: ^trace_id}} = Tracing.get_run(trace_run_id)
    end
  end

  test "a parent run without a thread sends a nil thread_id" do
    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{
          responses: [
            FakeChatModel.tool_call("start_async_task", %{"subagent_type" => "researcher", "description" => "Collect."}),
            "Started."
          ]
        },
        middleware: [parent_middleware()]
      )

    assert {:ok, _result} = Agent.invoke(agent, %{messages: ["Research refunds."]}, run_id: "parent-run")

    assert_received {:client_call, :start, opts}
    assert %{thread_id: nil, run_id: "parent-run", subagent_name: "researcher"} = opts[:parent]
  end

  test "a tool called outside a run sends nil for the run and the trace" do
    input = %{state: %{}, tool_call_id: "call-1", subagent_type: "researcher", description: "Collect."}
    assert %Command{} = run(start_tool(parent_middleware()), input)

    assert_received {:client_call, :start, opts}

    assert opts[:parent] == %{
             thread_id: nil,
             run_id: nil,
             tool_call_id: "call-1",
             subagent_name: "researcher",
             trace_id: nil,
             trace_run_id: nil
           }
  end
end
