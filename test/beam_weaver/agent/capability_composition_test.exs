defmodule BeamWeaver.Agent.CapabilityCompositionTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models.FakeChatModel

  defp tool(name) do
    Tool.from_function!(
      name: name,
      description: "The #{name} tool.",
      input_schema: %{"type" => "object", "properties" => %{}},
      handler: fn _args, _opts -> name end
    )
  end

  defp offered_tools(opts), do: opts |> Keyword.fetch!(:tools) |> Enum.map(&Tool.name/1)

  test "exclude_tools still applies when the agent lists its own ToolSelection" do
    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{response: "done", parent: self()},
        tools: [tool("lookup_order"), tool("issue_refund"), tool("get_invoice")],
        exclude_tools: ["issue_refund"],
        tool_descriptions: %{"lookup_order" => "Find an order."},
        middleware: [{Middleware.ToolSelection, deny: ["get_invoice"]}]
      )

    assert {:ok, _state} = Agent.invoke(agent, %{messages: ["Where is my order?"]})
    assert_received {:fake_chat_model_call, _messages, opts}

    assert offered_tools(opts) == ["lookup_order"]
    assert [%Tool{description: "Find an order."}] = opts[:tools]
  end

  test "DynamicPrompt replaces the declared prompt and keeps the sections capabilities add" do
    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{response: "done", parent: self()},
        system_prompt: "Replaced.",
        filesystem: BeamWeaver.Filesystem.State.new(),
        middleware: [
          Middleware.TodoList,
          {Middleware.DynamicPrompt, prompt: fn _state, runtime -> "You help #{runtime.context.name}." end}
        ]
      )

    assert {:ok, _state} = Agent.invoke(agent, %{messages: ["Hi"]}, context: %{name: "Ada"})
    assert_received {:fake_chat_model_call, [system, _question], _opts}

    prompt = Message.text(system)
    assert String.starts_with?(prompt, "You help Ada.\n\n")
    assert prompt =~ "## Filesystem Tools"
    assert prompt =~ "write_todos"
    refute prompt =~ "Replaced."
  end

  test "the capability profile's prompt text follows the prompt DynamicPrompt builds" do
    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{response: "done", parent: self()},
        system_prompt: "Replaced.",
        capability_profile: BeamWeaver.Agent.CapabilityProfile.new(prompt_suffix: "Search with grep first."),
        middleware: [
          {Middleware.DynamicPrompt,
           prompt: fn request -> "You help Acme. (#{BeamWeaver.Agent.ModelRequest.system_prompt(request)})" end}
        ]
      )

    assert {:ok, _state} = Agent.invoke(agent, %{messages: ["Hi"]})
    assert_received {:fake_chat_model_call, [system, _question], _opts}

    assert Message.text(system) == "You help Acme. (Replaced.)\n\nSearch with grep first."
  end

  defmodule Triage do
    use BeamWeaver.Schema

    field :category, :string
  end

  test "the structured-response call after a tool loop keeps the DynamicPrompt prompt" do
    {:ok, agent} =
      Agent.build(
        model: "fake:chat",
        model_opts: [
          responses: [
            FakeChatModel.tool_call("lookup_order", %{}),
            "It shipped.",
            FakeChatModel.final(%{category: "shipping"})
          ],
          parent: self()
        ],
        tools: [tool("lookup_order")],
        response_format: BeamWeaver.Agent.StructuredOutput.tool(Triage),
        middleware: [{Middleware.DynamicPrompt, prompt: "You triage Acme tickets."}]
      )

    assert {:ok, %{structured_response: %{"category" => "shipping"}}} =
             Agent.invoke(agent, %{messages: ["Where is my order?"]})

    prompts =
      for _call <- 1..3 do
        assert_received {:fake_chat_model_call, [system | _messages], _opts}
        Message.text(system)
      end

    assert prompts == List.duplicate("You triage Acme tickets.", 3)
  end

  @tag :tmp_dir
  test "a Filesystem middleware listed to tune it works on the declared filesystem", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "policies"))
    File.write!(Path.join(tmp_dir, "policies/refunds.md"), "Damaged items get a full refund.\n")

    {:ok, agent} =
      Agent.build(
        model: "fake:chat",
        model_opts: [
          responses: [
            FakeChatModel.tool_call("read_file", %{"file_path" => "/policies/refunds.md"}),
            FakeChatModel.tool_call("write_file", %{"file_path" => "/policies/new.md", "content" => "x"}),
            "Done."
          ]
        ],
        filesystem: BeamWeaver.Filesystem.Local.new(root: tmp_dir),
        filesystem_permissions: [
          BeamWeaver.Filesystem.Permission.new(operations: [:write], paths: ["/policies/**"], mode: :deny)
        ],
        middleware: [{Middleware.Filesystem, tool_token_limit_before_evict: 5_000}]
      )

    assert {:ok, result} = Agent.invoke(agent, %{messages: ["What is the refund policy?"]})

    [read, write] = for %Message{role: :tool} = message <- result.messages, do: Message.text(message)
    assert read =~ "Damaged items get a full refund."
    assert write =~ "denied"
    refute File.exists?(Path.join(tmp_dir, "policies/new.md"))
  end

  @tag :tmp_dir
  test "a Memory middleware listed with its own options reads the declared filesystem", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "AGENTS.md"), "Ada prefers email.\n")

    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{response: "Noted.", parent: self()},
        filesystem: BeamWeaver.Filesystem.Local.new(root: tmp_dir),
        middleware: [{Middleware.Memory, memory: ["/AGENTS.md"]}]
      )

    assert {:ok, _state} = Agent.invoke(agent, %{messages: ["How should we contact Ada?"]})
    assert_received {:fake_chat_model_call, [system, _question], _opts}
    assert Message.text(system) =~ "Ada prefers email."
  end

  defp general_purpose_summarization(agent) do
    middleware = Enum.find(agent.spec.middleware, &match?(%Middleware.Subagents{}, &1))
    {:ok, %{agent: %Agent.Built{spec: child}}} = Middleware.Subagents.build_subagent(middleware, "general-purpose")
    Enum.find(child.middleware, &match?(%Middleware.Summarization{}, &1))
  end

  test "subagents summarize their conversations only when the agent does, with its settings" do
    worker = BeamWeaver.Agent.Subagent.Spec.new(name: "worker", description: "Works.", system_prompt: "Work.")
    build = &Agent.build(model: "fake:chat", subagents: [worker], compact_conversation: &1)

    {:ok, agent} = build.(summarization: false)
    assert general_purpose_summarization(agent) == nil

    {:ok, agent} = build.(true)
    assert %Middleware.Summarization{trigger: {:messages, 20}} = general_purpose_summarization(agent)

    {:ok, agent} = build.(summarization: [trigger: {:messages, 40}])
    assert %Middleware.Summarization{trigger: {:messages, 40}} = general_purpose_summarization(agent)

    {:ok, agent} = Agent.build(model: "fake:chat", subagents: [worker])
    assert general_purpose_summarization(agent) == nil
  end

  defmodule AppendLog do
    use BeamWeaver.Agent.Middleware

    @impl true
    def state_schema(_middleware) do
      %{
        log:
          BeamWeaver.Graph.channel(
            {BeamWeaver.Graph.Channels.BinaryOperatorAggregate, fn left, right -> left ++ right end},
            initial: []
          )
      }
    end

    @impl true
    def after_model(_middleware, _state, _runtime), do: %{log: ["model called"]}
  end

  test "a hook update equal to the current value still goes through the key's reducer" do
    {:ok, agent} =
      Agent.build(
        model: "fake:chat",
        model_opts: [responses: [FakeChatModel.tool_call("lookup_order", %{}), "Shipped."]],
        tools: [tool("lookup_order")],
        middleware: [AppendLog]
      )

    assert {:ok, state} = Agent.invoke(agent, %{messages: ["Where is my order?"]})
    assert state.log == ["model called", "model called"]
  end
end
