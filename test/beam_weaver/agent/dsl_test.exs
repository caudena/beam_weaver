defmodule BeamWeaver.Agent.DSLTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Server
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool

  defmodule GreetingAgent do
    use BeamWeaver.Agent

    reducer(:messages, fn existing, update -> existing ++ List.wrap(update) end)
    node(:greet, &__MODULE__.greet/2)
    edge(BeamWeaver.Graph.start(), :greet)
    edge(:greet, BeamWeaver.Graph.end_node())

    def greet(state, runtime) do
      greeting = Map.get(runtime.context || %{}, :greeting, "hello")
      existing = Map.get(state, :messages, [])
      %{messages: existing ++ ["#{greeting}, #{state.name}"], done: true}
    end
  end

  defmodule ToolCallingModel do
    @behaviour ChatModel

    defstruct [:parent, timeout: 15_000]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      if parent, do: send(parent, {:model_call, Enum.map(messages, & &1.role), tool_names(opts)})

      case Enum.find(messages, &(&1.role == :tool)) do
        %Message{} = tool_message ->
          {:ok, Message.assistant("final: #{tool_message.content}")}

        nil ->
          {:ok,
           Message.assistant("",
             tool_calls: [
               %{id: "call-add", name: "adder", args: %{"a" => 2, "b" => 3}}
             ]
           )}
      end
    end

    defp tool_names(opts) do
      opts
      |> Keyword.get(:tools, [])
      |> Enum.map(&Tool.name/1)
    end
  end

  defmodule CalculatorAgent do
    use BeamWeaver.Agent

    model(__MODULE__.model())
    tools(__MODULE__.tools())
    system_prompt("You are a calculator.")

    def model, do: %ToolCallingModel{parent: self()}

    def tools do
      [
        Tool.from_function!(
          name: "adder",
          description: "Add two numbers",
          input_schema: %{"required" => ["a", "b"]},
          handler: fn %{"a" => a, "b" => b}, _opts -> a + b end
        )
      ]
    end
  end

  defmodule ExplicitTimeoutAgent do
    use BeamWeaver.Agent

    model(__MODULE__.model(), timeout: 30_000)
    tools([])

    def model, do: %ToolCallingModel{timeout: 1_000}
  end

  test "agent modules invoke through the generated graph" do
    assert {:ok, %{messages: ["hi, Ada"], done: true}} =
             GreetingAgent.invoke(%{name: "Ada"}, context: %{greeting: "hi"})
  end

  test "agent modules can be supervised and called through the server" do
    pid = start_supervised!({GreetingAgent, []})

    assert {:ok, %{messages: ["hello, Grace"], done: true}} =
             Server.invoke(pid, %{name: "Grace"})
  end

  test "duplicate DSL node names fail at compile time" do
    source = """
    defmodule DuplicateAgent do
      use BeamWeaver.Agent
      node :same, fn state -> state end
      node :same, fn state -> state end
      edge BeamWeaver.Graph.start(), :same
    end
    """

    assert_raise CompileError, ~r/duplicate BeamWeaver agent node names/, fn ->
      Code.compile_string(source)
    end
  end

  test "DSL agents must declare a start edge" do
    source = """
    defmodule NoEntrypointAgent do
      use BeamWeaver.Agent
      node :only, fn state -> state end
    end
    """

    assert_raise CompileError, ~r/must define an edge from Graph.start/, fn ->
      Code.compile_string(source)
    end
  end

  test "model/tools DSL builds a graph-backed ReAct loop" do
    assert {:ok, %{messages: messages}} =
             CalculatorAgent.invoke(%{messages: [Message.user("what is 2 + 3?")]})

    assert [
             %Message{role: :user, content: "what is 2 + 3?"},
             %Message{role: :assistant, tool_calls: [%{name: "adder"}]},
             %Message{role: :tool, content: "5", tool_call_id: "call-add", name: "adder"},
             %Message{role: :assistant, content: "final: 5"}
           ] = messages

    assert_receive {:model_call, [:system, :user], ["adder"]}
    assert_receive {:model_call, [:system, :user, :assistant, :tool], ["adder"]}
  end

  test "model/tools DSL uses the model timeout for the generated model node" do
    assert CalculatorAgent.graph().nodes["model"].timeout == 15_000
  end

  test "model/tools DSL timeout option overrides the generated model node timeout" do
    assert ExplicitTimeoutAgent.graph().nodes["model"].timeout == 30_000
  end

  test "runtime agent build uses model timeout for the generated model node" do
    assert {:ok, agent} =
             Agent.build(
               model: %ToolCallingModel{timeout: 22_000},
               tools: []
             )

    assert agent.compiled.graph.nodes["model"].timeout == 22_000
  end

  test "runtime agent build model_opts timeout overrides the model node timeout" do
    assert {:ok, agent} =
             Agent.build(
               model: %ToolCallingModel{timeout: 1_000},
               model_opts: [timeout: 45_000],
               tools: []
             )

    assert agent.compiled.graph.nodes["model"].timeout == 45_000
  end

  test "model/tools DSL cannot be mixed with manual graph nodes" do
    source = """
    defmodule MixedAgent do
      use BeamWeaver.Agent
      model :some_model
      node :manual, fn state -> state end
      edge BeamWeaver.Graph.start(), :manual
    end
    """

    assert_raise CompileError, ~r/model\/tools DSL builds its own graph/, fn ->
      Code.compile_string(source)
    end
  end
end
