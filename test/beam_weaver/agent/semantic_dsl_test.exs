defmodule BeamWeaver.Agent.SemanticDSLTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware.PromptCaching
  alias BeamWeaver.Agent.Middleware.ToolCallLimit
  alias BeamWeaver.Agent.Subagent.Spec, as: SubagentSpec
  alias BeamWeaver.Agent.StructuredOutput.ToolStrategy
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Channels.LastValue

  defmodule EchoModel do
    @behaviour ChatModel
    defstruct []

    @impl true
    def invoke(%__MODULE__{}, _messages, _opts) do
      {:ok, Message.assistant("ok")}
    end
  end

  defmodule SearchTool do
    use BeamWeaver.Tool

    name("search")
    description("Search records.")

    injected(:state, :state, type: :object)

    schema do
      field(:query, :string, required: true)
    end

    def invoke(_tool, %{"query" => query}, _opts), do: {:ok, "result: #{query}"}
  end

  defmodule FactsSchema do
    use BeamWeaver.Schema

    title("facts_output")
    description("Extracted facts.")
    strict(true)

    field(:facts, {:array, :string}, required: true)
  end

  defmodule SpecialistAgent do
    use Agent

    name("specialist")
    description("Handle specialist work.")
    model(%EchoModel{})

    tools do
      tool(SearchTool)
    end

    middleware do
      use PromptCaching
    end

    system_prompt("Do specialist work.")
    response_schema(FactsSchema, name: "facts_output", strategy: :tool)
  end

  defmodule SupervisorAgent do
    use Agent

    name("supervisor")
    model(%EchoModel{})

    subagents do
      subagent(SpecialistAgent, capture_output: :facts_output)
    end
  end

  defmodule AsyncSupervisorAgent do
    use Agent

    name("async_supervisor")
    model(%EchoModel{})

    async_subagents do
      async_subagent("remote_researcher",
        description: "Run remote research.",
        graph_id: "research_graph",
        url: "https://agents.example.com"
      )
    end
  end

  defmodule GraphWorkflow do
    use Agent

    graph do
      state do
        channel(:summary, merge: :last)
        channel(:framework, merge: :map)
      end

      node(:summary, fn _state -> %{summary: "summary"} end, output: :summary)
      node(:meddic, fn _state -> %{framework: %{meddic: "ok"}} end)
      node(:bant, fn _state -> %{framework: %{bant: "ok"}} end)
      node(:action, fn _state -> %{action: "done"} end)

      edge(start(), :summary)
      edge(:summary, :meddic)
      edge(:summary, :bant)
      join([:meddic, :bant], :action)
      edge(:action, finish())
    end
  end

  test "tools block compiles to tool declarations and hides injected fields" do
    spec = SpecialistAgent.__beam_weaver_agent_spec__()

    assert [SearchTool] = spec.tools
    assert %{state: :state} = Tool.injected(%SearchTool{})
    refute Map.has_key?(Tool.input_schema(%SearchTool{}).properties, :state)
  end

  test "middleware block compiles in declaration order" do
    spec = SpecialistAgent.__beam_weaver_agent_spec__()

    assert [PromptCaching] = spec.middleware
  end

  test "response_schema builds a structured output strategy from a schema module" do
    %ToolStrategy{schema_specs: [schema]} = SpecialistAgent.__beam_weaver_agent_spec__().response_format

    assert schema.name == "facts_output"
    assert schema.json_schema["additionalProperties"] == false
    assert schema.json_schema["required"] == ["facts"]

    assert schema.json_schema["properties"]["facts"] == %{
             "type" => "array",
             "items" => %{"type" => "string"}
           }
  end

  test "response_schema strategy accepts atoms only" do
    assert_raise ArgumentError, ~s/unknown response_schema strategy "tool"/, fn ->
      Agent.__response_schema__(FactsSchema, name: "facts_output", strategy: "tool")
    end
  end

  test "graph state channel merge accepts atoms only" do
    assert_raise ArgumentError, ~s/unknown graph state channel merge "map"/, fn ->
      apply(Agent, :__add_graph_channel__, [Graph.new(), :summary, "map", []])
    end
  end

  test "subagent spec options accept atom keys only" do
    assert_raise ArgumentError, ~s/subagent spec options must use atom keys, got "name"/, fn ->
      SubagentSpec.new(%{"name" => "researcher"})
    end
  end

  test "schema DSL field names accept atoms only" do
    assert_raise CompileError, ~r/schema field names must be literal atoms/, fn ->
      Code.compile_quoted(
        quote do
          defmodule BeamWeaver.Agent.SemanticDSLTest.StringSchemaField do
            use BeamWeaver.Schema
            field("facts", {:array, :string})
          end
        end
      )
    end
  end

  test "agent context schema field names accept atoms only" do
    assert_raise CompileError, ~r/agent schema keys must be literal atoms/, fn ->
      Code.compile_quoted(
        quote do
          defmodule BeamWeaver.Agent.SemanticDSLTest.StringContextSchemaField do
            use BeamWeaver.Agent

            context_schema do
              field("workspace_id", :integer)
            end
          end
        end
      )
    end
  end

  test "module subagents preserve child config and parent capture options" do
    [subagent] = SupervisorAgent.__beam_weaver_agent_spec__().subagents

    assert subagent.name == "specialist"
    assert subagent.description == "Handle specialist work."
    assert subagent.tools == [SearchTool]
    assert subagent.middleware == [PromptCaching]
    assert subagent.capture_output == :facts_output
  end

  test "async subagents block compiles to async specs" do
    [subagent] = AsyncSupervisorAgent.__beam_weaver_agent_spec__().async_subagents

    assert subagent.name == "remote_researcher"
    assert subagent.description == "Run remote research."
    assert subagent.graph_id == "research_graph"
    assert subagent.url == "https://agents.example.com"
    assert subagent.client == BeamWeaver.Agent.Protocol.ReqClient
  end

  test "graph block compiles state channels, nodes, edges, and joins" do
    graph = GraphWorkflow.graph()

    assert %LastValue{} = graph.channels[:summary]
    assert %BinaryOperatorAggregate{} = graph.channels[:framework]
    assert Map.has_key?(graph.nodes, "summary")
    assert "summary" in graph.entry_points
    assert MapSet.member?(graph.finish_points, "action")
    assert [%{upstream: ["meddic", "bant"], target: "action"}] = graph.waiting_edges
  end

  defmodule MiddlewareWithOptsAgent do
    use Agent

    model(%EchoModel{})

    middleware do
      use ToolCallLimit, run_limit: 1
    end
  end

  test "middleware block accepts options" do
    assert [{ToolCallLimit, [run_limit: 1]}] = MiddlewareWithOptsAgent.__beam_weaver_agent_spec__().middleware
  end
end
