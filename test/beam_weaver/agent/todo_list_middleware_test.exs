defmodule BeamWeaver.Agent.TodoListMiddlewareTest do
  use ExUnit.Case, async: true

  # Upstream reference:
  # langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_todo.py

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware.TodoList
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool

  defmodule SequentialTodoModel do
    @behaviour ChatModel

    defstruct [:table, :parent, tool_calls: []]

    @impl true
    def invoke(%__MODULE__{} = model, messages, opts) do
      call = :ets.update_counter(model.table, :calls, 1, {:calls, 0})
      if model.parent, do: send(model.parent, {:todo_model_call, call, messages, opts})

      tool_calls = Enum.at(model.tool_calls, call - 1) || []
      content = if tool_calls == [], do: "done", else: ""
      {:ok, Message.assistant(content, tool_calls: tool_calls)}
    end
  end

  defmodule ContextModel do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, messages, opts) do
      opts
      |> Keyword.fetch!(:context)
      |> Map.fetch!(:model)
      |> ChatModel.invoke(messages, opts)
    end
  end

  defmodule TodoAgent do
    use BeamWeaver.Agent

    model(%ContextModel{})
    middleware([{TodoList, []}])
  end

  defmodule CustomTodoAgent do
    use BeamWeaver.Agent

    model(%ContextModel{})

    middleware([
      {TodoList, system_prompt: "call the todo tool", tool_description: "Custom todo tool description"}
    ])
  end

  test "initializes with a native todo tool and default prompt" do
    middleware = TodoList.new()

    assert middleware.system_prompt =~ "`todo`"
    assert [%BeamWeaver.Tools.Todo{} = tool] = TodoList.tools(middleware)
    assert Tool.name(tool) == "todo"
    assert Tool.description(tool) =~ "TODO"
  end

  test "custom prompt and tool description are used without mutating the original request" do
    middleware =
      TodoList.new(
        system_prompt: "Custom planning instructions",
        tool_description: "Custom todo tool description"
      )

    request = %ModelRequest{
      model: %SequentialTodoModel{},
      system_message: nil,
      messages: [Message.user("hello")],
      tools: [],
      state: %{},
      runtime: %{context: %{}},
      model_opts: []
    }

    assert {:ok, %ModelRequest{} = modified} =
             TodoList.wrap_model_call(middleware, request, fn request -> {:ok, request} end)

    assert %Message{role: :system, content: "Custom planning instructions"} =
             modified.system_message

    assert request.system_message == nil
    assert [%{description: "Custom todo tool description"}] = TodoList.tools(middleware)
  end

  test "appends todo instructions to an existing system message" do
    middleware = TodoList.new()

    request = %ModelRequest{
      model: %SequentialTodoModel{},
      system_message: Message.system("Original prompt"),
      messages: [Message.user("hello")],
      tools: [],
      state: %{},
      runtime: %{context: %{}},
      model_opts: []
    }

    assert {:ok, %ModelRequest{system_message: %Message{content: content}}} =
             TodoList.wrap_model_call(middleware, request, fn request -> {:ok, request} end)

    assert content =~ "Original prompt"
    assert content =~ "`todo`"
    assert request.system_message.content == "Original prompt"
  end

  test "agent installs the todo tool and updates todo state across tool calls" do
    table = :ets.new(:todo_list_agent, [:set, :public])

    model =
      model(table, [
        [todo_call("add", %{"action" => "add", "id" => "task-1", "text" => "Task 1"})],
        [
          todo_call("update", %{
            "action" => "update",
            "id" => "task-1",
            "text" => "Task 1 updated"
          })
        ],
        [todo_call("complete", %{"action" => "complete", "id" => "task-1"})],
        []
      ])

    assert {:ok, state} =
             Agent.invoke(TodoAgent, %{messages: [Message.user("plan this")]}, context: %{model: model})

    assert state.todos == [%{id: "task-1", text: "Task 1 updated", status: "complete"}]
    assert :ets.lookup(table, :calls) == [{:calls, 4}]
    assert length(state.messages) == 8

    assert_received {:todo_model_call, 1, [%Message{role: :system, content: prompt} | _], opts}
    assert prompt =~ "`todo`"
    assert Enum.map(Keyword.fetch!(opts, :tools), &Tool.name/1) == ["todo"]
  end

  test "custom todo middleware works in an agent" do
    table = :ets.new(:todo_list_custom_agent, [:set, :public])

    model =
      model(table, [
        [todo_call("add", %{"action" => "add", "id" => "custom", "text" => "Custom task"})],
        []
      ])

    assert {:ok, state} =
             Agent.invoke(CustomTodoAgent, %{messages: [Message.user("plan this")]}, context: %{model: model})

    assert state.todos == [%{id: "custom", text: "Custom task", status: "open"}]
    assert_received {:todo_model_call, 1, [%Message{role: :system, content: prompt} | _], opts}
    assert prompt =~ "call the todo tool"
    assert [%{description: "Custom todo tool description"}] = Keyword.fetch!(opts, :tools)
  end

  test "parallel todo tool calls are rejected with synthetic tool errors" do
    middleware = TodoList.new()

    state = %{
      messages: [
        Message.user("hello"),
        Message.assistant("",
          tool_calls: [
            todo_call("call-1", %{"action" => "add", "text" => "Task 1"}),
            todo_call("call-2", %{"action" => "add", "text" => "Task 2"})
          ]
        )
      ]
    }

    assert %{messages: [%Message{} = first, %Message{} = second]} =
             TodoList.after_model(middleware, state, nil)

    assert first.tool_call_id == "call-1"
    assert second.tool_call_id == "call-2"
    assert first.metadata.error_type == :parallel_todo_writes
    assert first.content =~ "should never be called multiple times"
  end

  test "parallel todo policy ignores unrelated tools and allows a single todo call" do
    middleware = TodoList.new()

    assert is_nil(
             TodoList.after_model(
               middleware,
               %{
                 messages: [
                   Message.assistant("",
                     tool_calls: [
                       %{id: "other", name: "lookup", args: %{}},
                       todo_call("call-1", %{"action" => "add", "text" => "Task 1"})
                     ]
                   )
                 ]
               },
               nil
             )
           )

    assert %{messages: messages} =
             TodoList.after_model(
               middleware,
               %{
                 messages: [
                   Message.assistant("",
                     tool_calls: [
                       %{id: "other", name: "lookup", args: %{}},
                       todo_call("call-1", %{"action" => "add", "text" => "Task 1"}),
                       todo_call("call-2", %{"action" => "add", "text" => "Task 2"})
                     ]
                   )
                 ]
               },
               nil
             )

    assert Enum.map(messages, & &1.tool_call_id) == ["call-1", "call-2"]
  end

  defp model(table, tool_calls) do
    %SequentialTodoModel{table: table, parent: self(), tool_calls: tool_calls}
  end

  defp todo_call(id, args) do
    %{id: id, name: "todo", args: args}
  end
end
