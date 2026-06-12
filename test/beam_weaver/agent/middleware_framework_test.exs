defmodule BeamWeaver.Agent.MiddlewareFrameworkTest do
  use ExUnit.Case, async: true

  # Native coverage for:

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.LastValue

  defmodule FrameworkModel do
    @behaviour ChatModel

    defstruct [:parent, two_tools?: false, tool_call?: false]

    @impl true
    def invoke(%__MODULE__{} = model, messages, opts) do
      tool_messages = Enum.filter(messages, &match?(%Message{role: :tool}, &1))
      send(parent(model.parent, opts), {:model_call, length(tool_messages)})

      cond do
        model.two_tools? and length(tool_messages) < 2 ->
          {:ok,
           Message.assistant("",
             tool_calls: [
               %{id: "call-#{length(tool_messages) + 1}", name: "echo", args: %{"value" => "yo"}}
             ]
           )}

        model.tool_call? and tool_messages == [] ->
          {:ok,
           Message.assistant("",
             tool_calls: [%{id: "call-1", name: "echo", args: %{"value" => "yo"}}]
           )}

        true ->
          {:ok, Message.assistant("final")}
      end
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule OrderOne do
    def name(_middleware), do: :order_one

    def before_model(_state, runtime) do
      send(runtime.context.parent, "OrderOne.before_model")
      nil
    end

    def wrap_model_call(request, handler) do
      send(request.runtime.context.parent, "OrderOne.wrap_model_call")
      handler.(request)
    end

    def after_model(_state, runtime) do
      send(runtime.context.parent, "OrderOne.after_model")
      nil
    end
  end

  defmodule OrderTwo do
    def name(_middleware), do: :order_two

    def before_model(_state, runtime) do
      send(runtime.context.parent, "OrderTwo.before_model")
      nil
    end

    def wrap_model_call(request, handler) do
      send(request.runtime.context.parent, "OrderTwo.wrap_model_call")
      handler.(request)
    end

    def after_model(_state, runtime) do
      send(runtime.context.parent, "OrderTwo.after_model")
      nil
    end
  end

  defmodule AgentHooks do
    def name(_middleware), do: :agent_hooks

    def before_agent(state, runtime) do
      send(runtime.context.parent, "before_agent")
      state
    end

    def before_model(_state, runtime) do
      send(runtime.context.parent, "before_model")
      nil
    end

    def after_model(_state, runtime) do
      send(runtime.context.parent, "after_model")
      nil
    end

    def after_agent(state, runtime) do
      send(runtime.context.parent, "after_agent")
      state
    end
  end

  defmodule JumpToEnd do
    def name(_middleware), do: :jump_to_end
    def can_jump_to(_middleware, :before_model), do: [:end]
    def can_jump_to(_middleware, _hook), do: []

    def before_model(_state, runtime) do
      send(runtime.context.parent, "jump_before_model")
      %{jump_to: :end}
    end
  end

  defmodule PrivateStateMiddleware do
    def name(_middleware), do: :private_state

    def state_schema(_middleware) do
      %{private_state: Graph.private_channel(LastValue)}
    end

    def before_model(_state, runtime) do
      send(runtime.context.parent, "private_before_model")
      %{private_state: "hidden"}
    end
  end

  defmodule RuntimeProbe do
    def name(_middleware), do: :runtime_probe

    def before_model(_state, runtime) do
      send(runtime.context.parent, {:runtime_before_model, runtime.node})
      nil
    end

    def wrap_model_call(request, handler) do
      send(request.runtime.context.parent, {:runtime_wrap_model, request.runtime.node})
      handler.(request)
    end

    def after_model(_state, runtime) do
      send(runtime.context.parent, {:runtime_after_model, runtime.node})
      nil
    end
  end

  defmodule AgentHookOne do
    def name(_middleware), do: :agent_hook_one

    def before_agent(_state, runtime) do
      send(runtime.context.parent, "before_1")
      nil
    end

    def after_agent(_state, runtime) do
      send(runtime.context.parent, "after_1")
      nil
    end
  end

  defmodule AgentHookTwo do
    def name(_middleware), do: :agent_hook_two

    def before_agent(_state, runtime) do
      send(runtime.context.parent, "before_2")
      %{messages: [Message.user("added by before_agent")]}
    end

    def after_agent(_state, runtime) do
      send(runtime.context.parent, "after_2")
      nil
    end
  end

  defmodule OrderAgent do
    use BeamWeaver.Agent

    model(%FrameworkModel{parent: :context, tool_call?: true})
    tools(__MODULE__.tools())
    middleware([OrderOne, OrderTwo])

    def tools, do: [echo_tool()]
    def echo_tool, do: BeamWeaver.Agent.MiddlewareFrameworkTest.echo_tool()
  end

  defmodule HooksAgent do
    use BeamWeaver.Agent

    model(%FrameworkModel{parent: :context, two_tools?: true})
    tools(__MODULE__.tools())
    middleware([AgentHooks])

    def tools, do: [BeamWeaver.Agent.MiddlewareFrameworkTest.echo_tool()]
  end

  defmodule JumpAgent do
    use BeamWeaver.Agent

    model(%FrameworkModel{parent: :context})
    middleware([JumpToEnd])
  end

  defmodule PrivateStateAgent do
    use BeamWeaver.Agent

    model(%FrameworkModel{parent: :context})
    middleware([PrivateStateMiddleware, RuntimeProbe])
  end

  defmodule MultiHookAgent do
    use BeamWeaver.Agent

    model(%FrameworkModel{parent: :context})
    middleware([AgentHookOne, AgentHookTwo])
  end

  test "model middleware order wraps every model call around tool execution" do
    assert {:ok, %{messages: messages}} =
             OrderAgent.invoke(%{messages: [Message.user("hello")]}, context: %{parent: self()})

    assert Enum.map(messages, & &1.role) == [:user, :assistant, :tool, :assistant]

    assert_receive "OrderOne.before_model"
    assert_receive "OrderTwo.before_model"
    assert_receive "OrderOne.wrap_model_call"
    assert_receive "OrderTwo.wrap_model_call"
    assert_receive "OrderTwo.after_model"
    assert_receive "OrderOne.after_model"
    assert_receive {:echo_tool, "yo"}
    assert_receive "OrderOne.before_model"
    assert_receive "OrderTwo.before_model"
    assert_receive "OrderOne.wrap_model_call"
    assert_receive "OrderTwo.wrap_model_call"
    assert_receive "OrderTwo.after_model"
    assert_receive "OrderOne.after_model"
  end

  test "agent hooks run once while model hooks run once per model iteration" do
    assert {:ok, %{messages: messages}} =
             HooksAgent.invoke(%{messages: [Message.user("hello")]}, context: %{parent: self()})

    assert Enum.map(messages, & &1.role) == [
             :user,
             :assistant,
             :tool,
             :assistant,
             :tool,
             :assistant
           ]

    assert_receive "before_agent"
    assert_receive "before_model"
    assert_receive "after_model"
    assert_receive {:echo_tool, "yo"}
    assert_receive "before_model"
    assert_receive "after_model"
    assert_receive {:echo_tool, "yo"}
    assert_receive "before_model"
    assert_receive "after_model"
    assert_receive "after_agent"
  end

  test "multiple agent hooks preserve order and before_agent state updates reach the model" do
    assert {:ok, %{messages: messages}} =
             MultiHookAgent.invoke(%{messages: [Message.user("original")]},
               context: %{parent: self()}
             )

    assert Enum.map(messages, & &1.content) == ["original", "added by before_agent", "final"]
    assert_receive "before_1"
    assert_receive "before_2"
    assert_receive {:model_call, 0}
    assert_receive "after_2"
    assert_receive "after_1"
  end

  test "middleware jump routes to end and jump_to remains ephemeral" do
    assert {:ok, state} =
             JumpAgent.invoke(%{messages: [Message.user("hello")]}, context: %{parent: self()})

    assert [%Message{role: :user, content: "hello"}] = state.messages
    refute Map.has_key?(state, :jump_to)
    assert_receive "jump_before_model"
    refute_receive {:model_call, _count}, 50
  end

  test "compiled agent graph exposes deterministic introspection for middleware routes" do
    assert {:ok, compiled} = BeamWeaver.Agent.compiled_graph(OrderAgent)

    graph = BeamWeaver.Graph.Compiled.get_graph(compiled)
    assert Map.has_key?(graph.nodes, "order_one.before_model")
    assert Map.has_key?(graph.nodes, "order_two.after_model")
    assert Map.has_key?(graph.nodes, "tools")

    mermaid = BeamWeaver.Graph.Compiled.draw_mermaid(compiled)
    assert mermaid =~ "graph TD"
    assert mermaid =~ "order_one.before_model"
    assert mermaid =~ "tools"
  end

  test "middleware private state is hidden from output and runtime is injected" do
    assert {:ok, state} =
             PrivateStateAgent.invoke(%{messages: [Message.user("hello")]},
               context: %{parent: self()}
             )

    refute Map.has_key?(state, :private_state)
    assert_receive "private_before_model"
    assert_receive {:runtime_before_model, "runtime_probe.before_model"}
    assert_receive {:runtime_wrap_model, "model"}
    assert_receive {:runtime_after_model, "runtime_probe.after_model"}
  end

  test "Task-backed async agent invocation uses the same middleware path" do
    assert {:ok, %{messages: messages}} =
             OrderAgent.async_invoke(%{messages: [Message.user("hello")]},
               context: %{parent: self()}
             )
             |> Async.await()

    assert Enum.map(messages, & &1.role) == [:user, :assistant, :tool, :assistant]
    assert_receive "OrderOne.before_model"
    assert_receive "OrderTwo.before_model"
    assert_receive "OrderOne.wrap_model_call"
  end

  def echo_tool do
    Tool.from_function!(
      name: "echo",
      description: "Echo a value.",
      input_schema: %{"type" => "object", "required" => ["value"]},
      injected: %{"tool_runtime" => :tool_runtime},
      handler: fn %{"value" => value}, opts ->
        send(opts[:tool_runtime].runtime.context.parent, {:echo_tool, value})
        String.upcase(value)
      end
    )
  end
end
