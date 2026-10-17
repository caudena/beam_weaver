defmodule BeamWeaver.Agent.HumanInTheLoopTest do
  use ExUnit.Case, async: true

  # Upstream reference:

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

  defmodule PredicateReviewAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
      field(:review?, :boolean, required: true)
    end

    model(%ReviewModel{
      parent: :context,
      tool_calls: [
        %{id: "call-lookup", name: "lookup", args: %{"query" => "predicate"}}
      ]
    })

    tools(ReviewAgent.tools())

    middleware([
      {HumanInTheLoop,
       interrupt_on: %{
         "lookup" => %{
           :when => fn call, _state, runtime ->
             Map.get(runtime.context, :review?) == true and call.args["query"] == "predicate"
           end,
           allowed_decisions: [:approve, :reject]
         }
       },
       tools: ReviewAgent.tools()}
    ])
  end

  defmodule FirstModeAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%ReviewModel{
      parent: :context,
      tool_calls: [
        %{id: "call-lookup", name: "lookup", args: %{"query" => "first"}},
        %{id: "call-audit", name: "audit", args: %{"value" => "second"}}
      ]
    })

    tools(__MODULE__.tools())

    middleware([
      {HumanInTheLoop,
       interrupt_mode: :first,
       interrupt_on: %{
         "lookup" => true,
         "audit" => true
       },
       tools: __MODULE__.tools()}
    ])

    def tools do
      ReviewAgent.tools() ++
        [
          Tool.from_function!(
            name: "audit",
            description: "Audit a value",
            input_schema: %{
              "type" => "object",
              "required" => ["value"],
              "properties" => %{"value" => %{"type" => "string"}}
            },
            injected: %{"context" => :context},
            handler: fn %{"value" => value, "context" => context}, _opts ->
              send(context.parent, {:audit_executed, value})
              "audit:#{value}"
            end
          )
        ]
    end
  end

  defmodule RuleMapAgent do
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

    tools(ReviewAgent.tools())
    interrupt_on(%{"lookup" => %{description: "Check the lookup"}})
  end

  defmodule RedirectAgent do
    use BeamWeaver.Agent

    context_schema do
      field(:parent, :any, required: true)
    end

    model(%ReviewModel{
      parent: :context,
      tool_calls: [%{id: "call-lookup", name: "lookup", args: %{"query" => "raw"}}]
    })

    tools(__MODULE__.tools())
    middleware([{HumanInTheLoop, interrupt_on: %{"lookup" => true}, edit_notice: nil}])

    def tools do
      [
        hd(ReviewAgent.tools()),
        Tool.from_function!(
          name: "archive_search",
          description: "Search the order archive",
          input_schema: %{"type" => "object", "properties" => %{"order_id" => %{"type" => "string"}}},
          handler: fn %{"order_id" => order_id}, _opts -> "archived:#{order_id}" end
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

  test "an edit keeps the model's call and runs the reviewer's, with a notice" do
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

    assert %Message{role: :assistant, tool_calls: [model_call]} =
             Enum.find(messages, &match?(%Message{id: "ai-hitl"}, &1))

    assert model_call.id == "call-lookup"
    assert model_call.args == %{"query" => "raw"}

    assert %Message{name: "lookup", content: content} =
             Enum.find(messages, &match?(%Message{role: :tool, tool_call_id: "call-lookup"}, &1))

    assert content =~ ~r/^Note: a human reviewer replaced this tool call before it ran\./
    assert content =~ ~s(Executed instead: lookup with arguments {"query":"edited"}.\n\nTool response:\nlookup:edited)
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
          {"hitl-reject", %{type: "reject", message: "no"}, "error",
           "User rejected the tool call for `lookup` with reason: no"},
          {"hitl-reject-bare", %{type: "reject"}, "error",
           "User rejected the tool call for `lookup` with id call-lookup. The tool was not executed. " <>
             "Do not retry this tool call unless the user explicitly requests it."},
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

    assert Enum.any?(
             messages,
             &match?(
               %Message{role: :tool, content: "User rejected the tool call for `lookup` with reason: blocked"},
               &1
             )
           )

    assert_receive {:auto_executed, "free"}
    refute_received {:lookup_executed, "blocked"}
  end

  test "HITL when predicate can skip review without blocking tool execution" do
    assert {:ok, %{messages: messages}} =
             PredicateReviewAgent.invoke(%{messages: [Message.user("lookup")]},
               checkpointer: CheckpointETS.new(),
               config: thread("hitl-predicate-skip"),
               context: %{parent: self(), review?: false}
             )

    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "lookup:predicate"}, &1))
    assert_receive {:lookup_executed, "predicate"}

    assert {:interrupted, interrupt} =
             PredicateReviewAgent.invoke(%{messages: [Message.user("lookup")]},
               checkpointer: CheckpointETS.new(),
               config: thread("hitl-predicate-review"),
               context: %{parent: self(), review?: true}
             )

    assert [%{name: "lookup"}] = interrupt.value.action_requests
  end

  test "HITL first interrupt mode reviews only the first matching tool call" do
    checkpointer = CheckpointETS.new()
    config = thread("hitl-first-mode")

    assert {:interrupted, interrupt} =
             FirstModeAgent.invoke(%{messages: [Message.user("both")]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert [%{name: "lookup"}] = interrupt.value.action_requests

    assert {:ok, %{messages: messages}} =
             FirstModeAgent.resume(%{decisions: [%{type: "approve"}]},
               checkpointer: checkpointer,
               config: config,
               context: %{parent: self()}
             )

    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "lookup:first"}, &1))
    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "audit:second"}, &1))
    assert_receive {:lookup_executed, "first"}
    assert_receive {:audit_executed, "second"}
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

  test "a rule map without allowed_decisions still pauses and allows every decision" do
    opts = [checkpointer: CheckpointETS.new(), config: thread("hitl-rule-map"), context: %{parent: self()}]

    assert {:interrupted, interrupt} = RuleMapAgent.invoke(%{messages: [Message.user("lookup")]}, opts)

    assert %{
             action_requests: [%{name: "lookup", description: "Check the lookup"}],
             review_configs: [%{allowed_decisions: ["approve", "edit", "reject", "respond"]}]
           } = interrupt.value

    refute_received {:lookup_executed, _query}

    assert {:ok, %{messages: messages}} =
             RuleMapAgent.resume_review([HITL.decision(:respond, message: "answered")], opts)

    assert Enum.any?(messages, &match?(%Message{role: :tool, content: "answered"}, &1))
  end

  test "interrupt_on rules that can't be read raise instead of turning review off" do
    for interrupt_on <- [
          %{"lookup" => %{allowed_decisions: []}},
          %{"lookup" => %{allowed_decisions: [:approve, :maybe]}},
          %{"lookup" => %{"allowed_decisions" => ["approve", "skip"]}},
          %{"lookup" => "yes"},
          ["lookup"]
        ] do
      assert_raise ArgumentError, fn -> HumanInTheLoop.new(interrupt_on: interrupt_on) end
    end

    assert %HumanInTheLoop{interrupt_on: %{"lookup" => %{allowed_decisions: [:approve, :reject]}}} =
             HumanInTheLoop.new(interrupt_on: [lookup: %{"allowed_decisions" => ["approve", "reject"]}])
  end

  test "edited arguments are checked against the tool's own input schema" do
    opts = [checkpointer: CheckpointETS.new(), config: thread("hitl-edit-tool-schema"), context: %{parent: self()}]

    assert {:interrupted, _interrupt} = RuleMapAgent.invoke(%{messages: [Message.user("lookup")]}, opts)

    edit = HITL.decision(:edit, edited_action: %{name: "lookup", args: %{"query" => 123}})

    assert {:error, %Error{type: :invalid_human_decision}} = RuleMapAgent.resume_review([edit], opts)
    refute_received {:lookup_executed, _query}

    edit = HITL.decision(:edit, edited_action: %{name: "lookup", args: %{"query" => "edited"}})

    assert {:ok, %{messages: messages}} = RuleMapAgent.resume_review([edit], opts)
    assert %Message{role: :assistant, content: "final: " <> answer} = List.last(messages)
    assert String.ends_with?(answer, "Tool response:\nlookup:edited")
    assert_receive {:lookup_executed, "edited"}
  end

  test "a refused decision keeps the review pending, so one valid resume completes the run" do
    opts = [checkpointer: CheckpointETS.new(), config: thread("hitl-retry-after-refusal"), context: %{parent: self()}]

    assert {:interrupted, interrupt} = ReviewAgent.invoke(%{messages: [Message.user("lookup")]}, opts)

    bad_edit = HITL.decision(:edit, edited_action: %{name: "lookup", args: %{"query" => 123}})
    assert {:error, %Error{type: :invalid_human_decision}} = ReviewAgent.resume_review([bad_edit], opts)

    assert {:ok, snapshot} = ReviewAgent.get_state(opts)
    assert [%{id: pending_id}] = snapshot.interrupts
    assert pending_id == interrupt.id

    assert {:ok, %{messages: messages}} = ReviewAgent.resume_review([HITL.decision(:approve)], opts)
    assert %Message{role: :assistant, content: "final: lookup:raw"} = List.last(messages)
    assert_receive {:lookup_executed, "raw"}
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

  # The result answers the model's call, so it keeps that call's name, which
  # providers such as Gemini match against the call.
  test "an edit may run another tool, and edit_notice: nil adds no notice" do
    opts = [checkpointer: CheckpointETS.new(), config: thread("hitl-redirect"), context: %{parent: self()}]

    assert {:interrupted, _interrupt} = RedirectAgent.invoke(%{messages: [Message.user("lookup")]}, opts)

    edit = HITL.decision(:edit, edited_action: %{name: "archive_search", args: %{"order_id" => "A-1"}})
    assert {:ok, %{messages: messages}} = RedirectAgent.resume_review([edit], opts)

    assert %Message{name: "lookup", content: "archived:A-1"} =
             Enum.find(messages, &match?(%Message{role: :tool, tool_call_id: "call-lookup"}, &1))

    refute_received {:lookup_executed, _query}
  end

  test "a turn with nothing to review clears an earlier turn's edits" do
    middleware = HumanInTheLoop.new(interrupt_on: %{"lookup" => true})
    edits = %{"call-1" => %{name: "lookup", args: %{"query" => "edited"}}}
    turn = Message.assistant("", tool_calls: [%{id: "call-1", name: "other", args: %{}}])

    assert %{hitl_edited_tool_calls: %{}} =
             HumanInTheLoop.after_model(middleware, %{messages: [turn], hitl_edited_tool_calls: edits}, nil)

    assert nil == HumanInTheLoop.after_model(middleware, %{messages: [turn], hitl_edited_tool_calls: %{}}, nil)
  end

  defp thread(id), do: %{"configurable" => %{"thread_id" => id}}
end
