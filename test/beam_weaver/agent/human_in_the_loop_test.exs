defmodule BeamWeaver.Agent.HumanInTheLoopTest do
  use ExUnit.Case, async: true

  # Upstream reference:
  # - langchain/libs/langchain_v1/tests/unit_tests/agents/middleware/implementations/test_human_in_the_loop.py
  # - langgraph/libs/langgraph/langgraph/types.py::interrupt

  alias BeamWeaver.Agent.HITL
  alias BeamWeaver.Agent.Middleware.HumanInTheLoop
  alias BeamWeaver.Agent.Middleware.HumanInTheLoop.Decision
  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool

  defmodule ReviewModel do
    @behaviour ChatModel

    defstruct [:parent, tool_calls: []]

    @impl true
    def invoke(%__MODULE__{parent: parent, tool_calls: tool_calls}, messages, opts) do
      parent = parent(parent, opts)
      send(parent, {:hitl_model_call, Enum.map(messages, &{&1.role, &1.content})})

      tool_messages = Enum.filter(messages, &match?(%Message{role: :tool}, &1))

      if tool_messages == [] do
        {:ok, Message.assistant("", id: "ai-hitl", tool_calls: tool_calls)}
      else
        content =
          tool_messages
          |> Enum.map_join("|", & &1.content)

        {:ok, Message.assistant("final: #{content}")}
      end
    end

    defp parent(:context, opts), do: opts |> Keyword.get(:context, %{}) |> Map.get(:parent)
    defp parent(parent, _opts), do: parent
  end

  defmodule ReviewAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%ReviewModel{
      parent: :context,
      tool_calls: [
        %{id: "call-lookup", name: "lookup", args: %{"query" => "raw"}}
      ]
    })

    tools(__MODULE__.tools())

    middleware([
      {HumanInTheLoop,
       interrupt_on: %{
         "lookup" => %{
           allowed_decisions: [:approve, :edit, :reject, :respond],
           description: &__MODULE__.description/3,
           args_schema: %{
             "type" => "object",
             "required" => ["query"],
             "properties" => %{"query" => %{"type" => "string"}}
           }
         }
       },
       tools: __MODULE__.tools()}
    ])

    def description(tool_call, _state, runtime) do
      "Review #{tool_call.name || tool_call[:name]} for #{inspect(runtime.context.parent)}"
    end

    def tools do
      [
        Tool.from_function!(
          name: "lookup",
          description: "Lookup a query",
          input_schema: %{
            "type" => "object",
            "required" => ["query"],
            "properties" => %{"query" => %{"type" => "string"}}
          },
          injected: %{"context" => :context},
          handler: fn %{"query" => query, "context" => context}, _opts ->
            send(context.parent, {:lookup_executed, query})
            "lookup:#{query}"
          end
        )
      ]
    end
  end

  defmodule MixedReviewAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%ReviewModel{
      parent: :context,
      tool_calls: [
        %{id: "call-auto", name: "auto", args: %{"value" => "free"}},
        %{id: "call-lookup", name: "lookup", args: %{"query" => "blocked"}}
      ]
    })

    tools(__MODULE__.tools())

    middleware([
      {HumanInTheLoop, interrupt_on: %{"lookup" => %{allowed_decisions: [:reject]}}, tools: __MODULE__.tools()}
    ])

    def tools do
      [
        Tool.from_function!(
          name: "auto",
          description: "Auto-approved tool",
          input_schema: %{
            "required" => ["value"],
            "properties" => %{"value" => %{"type" => "string"}}
          },
          injected: %{"context" => :context},
          handler: fn %{"value" => value, "context" => context}, _opts ->
            send(context.parent, {:auto_executed, value})
            "auto:#{value}"
          end
        ),
        Tool.from_function!(
          name: "lookup",
          description: "Lookup a query",
          input_schema: %{
            "required" => ["query"],
            "properties" => %{"query" => %{"type" => "string"}}
          },
          injected: %{"context" => :context},
          handler: fn %{"query" => query, "context" => context}, _opts ->
            send(context.parent, {:lookup_executed, query})
            "lookup:#{query}"
          end
        )
      ]
    end
  end

  defmodule NoCheckpointAgent do
    use BeamWeaver.Agent

    model(%ReviewModel{
      parent: :context,
      tool_calls: [
        %{id: "call-lookup", name: "lookup", args: %{"query" => "raw"}}
      ]
    })

    tools(ReviewAgent.tools())
    middleware([{HumanInTheLoop, interrupt_on: %{"lookup" => true}, tools: ReviewAgent.tools()}])
  end

  test "HITL interrupts with a batched review request and approves tool execution" do
    checkpointer = CheckpointETS.new()
    config = thread("hitl-approve")

    assert {:interrupted, interrupt} =
             ReviewAgent.invoke(%{messages: [Message.user("lookup")]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert %{
             action_requests: [
               %{name: "lookup", args: %{"query" => "raw"}, description: description}
             ],
             review_configs: [
               %{
                 action_name: "lookup",
                 allowed_decisions: ["approve", "edit", "reject", "respond"],
                 args_schema: %{"required" => ["query"]}
               }
             ]
           } = interrupt.value

    assert description =~ "Review lookup"

    assert {:ok, %{messages: messages}} =
             ReviewAgent.resume(%{decisions: [%{type: "approve"}]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "lookup:raw"}, &1))
    assert %Message{role: :assistant, content: "final: lookup:raw"} = List.last(messages)
    assert_receive {:lookup_executed, "raw"}
  end

  test "edit decision preserves tool call ID and validates edited args" do
    checkpointer = CheckpointETS.new()
    config = thread("hitl-edit")

    assert {:interrupted, _interrupt} =
             ReviewAgent.invoke(%{messages: [Message.user("lookup")]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert {:ok, %{messages: messages}} =
             ReviewAgent.resume(
               %{
                 decisions: [
                   %{type: :edit, edited_action: %{name: "lookup", args: %{"query" => "edited"}}}
                 ]
               },
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert %Message{role: :assistant, tool_calls: [edited_call]} =
             Enum.find(messages, &match?(%Message{id: "ai-hitl"}, &1))

    assert edited_call.id == "call-lookup"
    assert edited_call.args == %{"query" => "edited"}
    assert_receive {:lookup_executed, "edited"}
  end

  test "typed HITL decisions are accepted at resume boundaries" do
    checkpointer = CheckpointETS.new()
    config = thread("hitl-typed-decision")

    assert {:interrupted, _interrupt} =
             ReviewAgent.invoke(%{messages: [Message.user("lookup")]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert {:ok, %{messages: messages}} =
             ReviewAgent.resume(
               %{decisions: [%Decision{type: :respond, message: "typed answer"}]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "typed answer"}, &1))
    refute_received {:lookup_executed, _query}
  end

  test "reject and respond create synthetic tool messages and do not execute reviewed tools" do
    for {thread_id, decision, expected_status, expected_content} <- [
          {"hitl-reject", %{type: "reject", message: "no"}, "error", "no"},
          {"hitl-respond", %{type: "respond", message: "human answer"}, "success", "human answer"}
        ] do
      checkpointer = CheckpointETS.new()
      config = thread(thread_id)

      assert {:interrupted, _interrupt} =
               ReviewAgent.invoke(%{messages: [Message.user("lookup")]},
                 checkpointer: checkpointer,
                 config: config,
                 context: %{parent: self()}
               )

      assert {:ok, %{messages: messages}} =
               ReviewAgent.resume(%{decisions: [decision]},
                 checkpointer: checkpointer,
                 config: config,
                 context: %{parent: self()}
               )

      assert %Message{
               role: :tool,
               content: ^expected_content,
               status: ^expected_status,
               tool_call_id: "call-lookup"
             } = Enum.find(messages, &match?(%Message{role: :tool}, &1))

      refute_received {:lookup_executed, _query}
    end
  end

  test "mixed auto-approved and rejected tool calls execute only unsatisfied pending calls" do
    checkpointer = CheckpointETS.new()
    config = thread("hitl-mixed")

    assert {:interrupted, _interrupt} =
             MixedReviewAgent.invoke(%{messages: [Message.user("mixed")]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert {:ok, %{messages: messages}} =
             MixedReviewAgent.resume(%{decisions: [%{type: "reject", message: "blocked"}]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "auto:free"}, &1))
    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "blocked"}, &1))
    assert_receive {:auto_executed, "free"}
    refute_received {:lookup_executed, "blocked"}
  end

  test "invalid decisions return tagged errors" do
    checkpointer = CheckpointETS.new()
    config = thread("hitl-invalid")

    assert {:interrupted, _interrupt} =
             ReviewAgent.invoke(%{messages: [Message.user("lookup")]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert {:error, %Error{type: :invalid_human_decision}} =
             ReviewAgent.resume(
               %{
                 decisions: [
                   %{type: "edit", edited_action: %{name: "lookup", args: %{"query" => 123}}}
                 ]
               },
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    checkpointer = CheckpointETS.new()
    config = thread("hitl-mismatch")

    assert {:interrupted, _interrupt} =
             ReviewAgent.invoke(%{messages: [Message.user("lookup")]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert {:error, %Error{type: :invalid_human_decision}} =
             ReviewAgent.resume(%{decisions: []},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )
  end

  test "HITL requires a checkpointer and pending interrupts are visible in state" do
    assert {:error, %Error{type: :missing_checkpointer}} =
             NoCheckpointAgent.invoke(%{messages: [Message.user("lookup")]},
               context: %{parent: self()}
             )

    checkpointer = CheckpointETS.new()
    config = thread("hitl-state")

    assert {:interrupted, interrupt} =
             ReviewAgent.invoke(%{messages: [Message.user("lookup")]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert {:ok, snapshot} =
             ReviewAgent.get_state(checkpointer: checkpointer, config: config)

    assert [pending] = snapshot.interrupts
    assert pending.id == interrupt.id
    assert pending.value.action_requests |> hd() |> Map.fetch!(:name) == "lookup"
  end

  test "framework-agnostic HITL review helpers format interrupts and resume decisions" do
    checkpointer = CheckpointETS.new()
    config = thread("hitl-review-helper")

    assert {:interrupted, interrupt} =
             ReviewAgent.invoke(%{messages: [Message.user("lookup")]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert {:ok, review} = HITL.from_interrupt(interrupt)
    assert %HITL.Review{id: id, action_requests: [%HITL.ActionRequest{name: "lookup"}]} = review
    assert is_binary(id)

    assert %{
             action_requests: [%{name: "lookup", args: %{"query" => "raw"}}],
             review_configs: [%{allowed_decisions: ["approve", "edit", "reject", "respond"]}]
           } = HITL.to_map(review)

    assert {:ok, %{messages: messages}} =
             ReviewAgent.resume_review([HITL.decision(:respond, message: "reviewed answer")],
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "reviewed answer"}, &1))
    refute_received {:lookup_executed, _query}
  end

  test "stream_events returns interrupt events for HITL pauses" do
    checkpointer = CheckpointETS.new()
    config = thread("hitl-stream")

    assert {:interrupted, interrupt} =
             ReviewAgent.stream_events(%{messages: [Message.user("lookup")]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert interrupt.value.action_requests |> hd() |> Map.fetch!(:name) == "lookup"
    assert Enum.any?(interrupt.events, &match?(%BeamWeaver.Stream.Envelope{}, &1))
  end

  defp thread(id), do: %{"configurable" => %{"thread_id" => id}}
end
