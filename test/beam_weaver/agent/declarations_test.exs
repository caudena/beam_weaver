defmodule BeamWeaver.Agent.DeclarationsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.CapabilityProfile
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph
  alias BeamWeaver.Models.FakeChatModel

  defmodule Echo do
    use BeamWeaver.Tool

    name "echo"
    description "Echo a value."

    schema do
      field :value, :string
    end

    @impl true
    def invoke(_tool, %{"value" => value}, _opts), do: {:ok, value}
  end

  defmodule Sleepy do
    use BeamWeaver.Tool

    name "sleepy"
    description "Takes its time."

    @impl true
    def invoke(_tool, _args, _opts) do
      Process.sleep(1_000)
      {:ok, "awake"}
    end
  end

  defmodule WhoAmI do
    use BeamWeaver.Tool

    name "whoami"
    description "Report the caller."

    injected :context, :context

    @impl true
    def invoke(_tool, %{context: context}, _opts), do: {:ok, inspect(context, custom_options: [sort_maps: true])}
  end

  defmodule OrderToolkit do
    @behaviour BeamWeaver.ToolKit

    @impl true
    def tools(opts) do
      warehouse = Keyword.get(opts, :warehouse, "Berlin")

      [
        Tool.from_function!(
          name: "lookup_order",
          description: "Look up an order.",
          input_schema: %{"type" => "object", "properties" => %{}},
          handler: fn _args, _opts -> "Order A-1001 left #{warehouse}." end
        )
      ]
    end
  end

  defmodule ModelOptionsAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: [Process.get(:declarations_test_reply, "fixed when compiled")], parent: self()
  end

  defmodule ModelOptsAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model_opts responses: [FakeChatModel.tool_call("echo", %{"value" => "hi"}), Process.get(:declarations_test_reply)]
    model "fake:chat", responses: ["replaced by model_opts"], parent: self()
    tools [BeamWeaver.Agent.DeclarationsTest.Echo]
  end

  defmodule ToolkitAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat", responses: [FakeChatModel.tool_call("lookup_order", %{}), "done"]

    tools do
      tool BeamWeaver.Agent.DeclarationsTest.OrderToolkit, warehouse: "Lyon"
    end
  end

  defmodule BareToolkitAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat", responses: [FakeChatModel.tool_call("lookup_order", %{}), "done"]
    tools [BeamWeaver.Agent.DeclarationsTest.OrderToolkit]
  end

  defmodule ToolOptionsAgent do
    use BeamWeaver.Agent

    model "fake:chat"

    tools do
      tool BeamWeaver.Agent.DeclarationsTest.Echo, retries: 3
    end
  end

  defmodule NoToolsAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat", responses: [FakeChatModel.tool_call("lookup_order", %{}), "I can't look orders up."]
  end

  defmodule TimeoutsAgent do
    use BeamWeaver.Agent

    model "fake:chat"
    step_timeout 30_000
    run_timeout 60_000
    tool_timeout 10_000
  end

  defmodule RunTimeoutGraph do
    use BeamWeaver.Agent

    run_timeout 50

    def graph do
      Graph.new()
      |> Graph.add_node(:wait, fn _state -> Process.sleep(1_000) && %{} end, timeout: 5_000)
      |> Graph.add_edge(Graph.start(), :wait)
      |> Graph.add_edge(:wait, Graph.end_node())
    end
  end

  defmodule SlowToolAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat", responses: [FakeChatModel.tool_call("sleepy", %{}), "done"]
    tools [BeamWeaver.Agent.DeclarationsTest.Sleepy]
    tool_timeout 50
  end

  defmodule ToolTimeoutOptionAgent do
    use BeamWeaver.Agent

    model "fake:chat", tool_timeout: 50
  end

  defmodule ContextAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat", responses: [FakeChatModel.tool_call("whoami", %{}), "done"]
    tools [BeamWeaver.Agent.DeclarationsTest.WhoAmI]

    context_schema do
      field :customer_id, :string, required: true
      field :discount, :float
      field :renews_on, :date
      field :seen_at, {:nullable, :utc_datetime}
      field :tags, {:list, :atom}
    end
  end

  defmodule RuntimeFieldOptionsAgent do
    use BeamWeaver.Agent

    model "fake:chat"

    context_schema do
      field :plan, :atom, required: Process.get(:declarations_test_plan_required, false)
    end
  end

  defmodule BreakpointGraph do
    use BeamWeaver.Agent

    interrupts before: Process.get(:declarations_test_breakpoints, [])

    def graph do
      Graph.new()
      |> Graph.add_node(:check, fn _state -> %{} end)
      |> Graph.add_edge(Graph.start(), :check)
      |> Graph.add_edge(:check, Graph.end_node())
    end
  end

  defmodule MisspelledContextAgent do
    use BeamWeaver.Agent

    model "fake:chat"

    context_schema do
      field :plan, :strnig
    end
  end

  defmodule ProfileProbe do
    use BeamWeaver.Agent.Middleware

    @impl true
    def before_model(_middleware, _state, runtime) do
      send(runtime.context.parent, :profile_middleware_ran)
      nil
    end
  end

  defmodule ProfiledAgent do
    use BeamWeaver.Agent

    alias BeamWeaver.Agent.CapabilityProfile

    model "fake:chat", responses: ["done"], parent: self()
    system_prompt "You are Acme's support researcher."
    filesystem BeamWeaver.Filesystem.State.new()
    tool_descriptions %{"ls" => "List Acme's policy folders."}

    capability_profile CapabilityProfile.new(
                         prompt_suffix: "Search with grep before you read whole files.",
                         excluded_tools: ["glob"],
                         tool_descriptions: %{"grep" => "Search Acme's policy files.", "ls" => "ignored"},
                         middleware: [BeamWeaver.Agent.DeclarationsTest.ProfileProbe]
                       )
  end

  defmodule AutoProfileAgent do
    use BeamWeaver.Agent

    model "anthropic:claude-sonnet-4-6"
    system_prompt "You are Acme's support researcher."
    capability_profile :auto
  end

  describe "declarations are evaluated when the agent runs" do
    test "the options after model" do
      Process.put(:declarations_test_reply, "read when the agent ran")

      assert {:ok, result} = ModelOptionsAgent.invoke(%{messages: ["Hi"]})
      assert Message.text(List.last(result.messages)) == "read when the agent ran"
      assert_received {:fake_chat_model_call, _messages, _opts}
    end

    test "context_schema field options and interrupts" do
      assert {:ok, _result} = RuntimeFieldOptionsAgent.invoke(%{messages: ["Hi"]})

      Process.put(:declarations_test_plan_required, true)

      assert {:error, %Error{type: :invalid_context, details: %{field: :plan}}} =
               RuntimeFieldOptionsAgent.invoke(%{messages: ["Hi"]})

      Process.put(:declarations_test_breakpoints, [:check])
      assert {:ok, compiled} = Agent.compiled_graph(BreakpointGraph)
      assert compiled.interrupt_before == MapSet.new(["check"])
    end

    test "model_opts, merged over the options after model in any order" do
      Process.put(:declarations_test_reply, "Echoed.")

      assert {:ok, result} = ModelOptsAgent.invoke(%{messages: ["Echo hi"]})
      assert Enum.map(result.messages, &Message.text/1) == ["Echo hi", "", "hi", "Echoed."]
      assert_received {:fake_chat_model_call, _messages, _opts}
    end
  end

  describe "tools" do
    test "a toolkit expands into its tools, and options after it go to its tools/1" do
      assert {:ok, result} = ToolkitAgent.invoke(%{messages: ["Where is my order?"]})
      assert tool_result(result) == "Order A-1001 left Lyon."

      assert {:ok, result} = BareToolkitAgent.invoke(%{messages: ["Where is my order?"]})
      assert tool_result(result) == "Order A-1001 left Berlin."
    end

    test "options after a tool that is not a toolkit are an error" do
      assert {:error, %Error{type: :invalid_tool, details: %{options: [:retries]}}} =
               ToolOptionsAgent.invoke(%{messages: ["Hi"]})
    end

    test "a model that calls a tool the agent doesn't have gets an error back" do
      assert {:ok, result} = NoToolsAgent.invoke(%{messages: ["Where is my order?"]})
      assert tool_result(result) =~ "tool is not registered"
      assert Message.text(List.last(result.messages)) == "I can't look orders up."
    end
  end

  describe "timeouts" do
    test "step_timeout, run_timeout and tool_timeout are declarations" do
      assert {:ok, compiled} = Agent.compiled_graph(TimeoutsAgent)
      assert compiled.step_timeout == 30_000
      assert compiled.run_timeout == 60_000
      assert compiled.graph.nodes["tools"].fun.timeout == 10_000
    end

    test "a graph module's run_timeout stops the run" do
      assert {:error, %Error{type: :run_timeout}} = RunTimeoutGraph.invoke(%{})
    end

    test "tool_timeout limits each tool step" do
      assert {:ok, result} = SlowToolAgent.invoke(%{messages: ["Wake up"]})
      assert tool_result(result) =~ "timed out"
    end

    test "tool_timeout is not a model option" do
      assert {:error, %Error{type: :invalid_agent, details: %{option: :tool_timeout}}} =
               ToolTimeoutOptionAgent.invoke(%{messages: ["Hi"]})
    end
  end

  describe "context_schema" do
    test "declared fields under string keys reach tools under their atom keys" do
      context = %{
        "customer_id" => "cus_ada",
        "discount" => 0.1,
        "renews_on" => ~D[2026-11-01],
        "seen_at" => nil,
        "tags" => [:pro],
        "locale" => "fr"
      }

      assert {:ok, result} = ContextAgent.invoke(%{messages: ["Who am I?"]}, context: context)

      assert tool_result(result) ==
               ~s(%{:customer_id => "cus_ada", :discount => 0.1, :renews_on => ~D[2026-11-01], :seen_at => nil, :tags => [:pro], "locale" => "fr"})
    end

    test "built-in types check their values" do
      assert {:ok, _result} =
               ContextAgent.invoke(%{messages: ["Who am I?"]},
                 context: %{customer_id: "cus_ada", discount: 1, seen_at: ~U[2026-10-10 12:00:00Z]}
               )

      assert {:error, %Error{type: :invalid_context, details: %{field: :renews_on}}} =
               ContextAgent.invoke(%{messages: ["Who am I?"]},
                 context: %{customer_id: "cus_ada", renews_on: "2026-11-01"}
               )

      assert {:error, %Error{type: :invalid_context, details: %{field: :tags}}} =
               ContextAgent.invoke(%{messages: ["Who am I?"]}, context: %{customer_id: "cus_ada", tags: ["pro"]})
    end

    test "an unknown type is an error, not a check every value fails" do
      assert {:error, %Error{type: :invalid_agent, details: %{field: :plan, type: ":strnig"}}} =
               MisspelledContextAgent.invoke(%{messages: ["Hi"]}, context: %{plan: "pro"})
    end
  end

  describe "capability_profile" do
    test "applies the profile's prompt text, hidden tools, tool descriptions and middleware" do
      assert {:ok, _result} = ProfiledAgent.invoke(%{messages: ["Hi"]}, context: %{parent: self()})

      assert_received :profile_middleware_ran
      assert_received {:fake_chat_model_call, [system, _question], opts}

      assert Message.text(system) =~
               ~r/\AYou are Acme's support researcher.\n\nSearch with grep before you read whole files.\n\n/

      tools = Map.new(opts[:tools], &{Tool.name(&1), Tool.description(&1)})
      refute Map.has_key?(tools, "glob")
      assert tools["grep"] == "Search Acme's policy files."
      assert tools["ls"] == "List Acme's policy folders."
    end

    test ":auto applies the built-in profile of the agent's model" do
      assert {:ok, compiled} = Agent.compiled_graph(AutoProfileAgent)
      suffix = CapabilityProfile.get_capability_profile("anthropic:claude-sonnet-4-6").prompt_suffix

      assert compiled.graph.nodes["model"].fun.system_prompt ==
               "You are Acme's support researcher.\n\n" <> suffix
    end

    test "an unknown profile value is an error" do
      assert {:error, %Error{type: :invalid_agent}} =
               Agent.build(model: "fake:chat", capability_profile: "anthropic")
    end
  end

  defp tool_result(result), do: result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
end
