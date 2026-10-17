defmodule BeamWeaver.Agent.HumanInTheLoopPerCallTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent, as: BWAgent
  alias BeamWeaver.Agent.Middleware.HumanInTheLoop
  alias BeamWeaver.Core.{ChatModel, Error, Message, Tool}

  defmodule Model do
    @behaviour ChatModel
    defstruct [:parent]

    @calls [
      %{id: "call-email", name: "send_email", args: %{"to" => "alice@example.com"}},
      %{id: "call-delete", name: "delete_file", args: %{"path" => "report.txt"}},
      %{id: "call-lookup", name: "lookup", args: %{"query" => "weather"}}
    ]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, _opts) do
      send(parent, :model_called)

      case Enum.filter(messages, &match?(%Message{role: :tool}, &1)) do
        [] -> {:ok, Message.assistant("", tool_calls: @calls)}
        results -> {:ok, Message.assistant("seen #{length(results)} results")}
      end
    end
  end

  defp tool(name, field) do
    parent = self()

    Tool.from_function!(
      name: name,
      description: "Run #{name}.",
      input_schema: %{"type" => "object", "required" => [field], "properties" => %{field => %{"type" => "string"}}},
      handler: fn args, _opts ->
        send(parent, {:ran, name, args})
        "#{name} done"
      end
    )
  end

  defp agent(interrupt_on) do
    {:ok, agent} =
      BWAgent.build(
        model: %Model{parent: self()},
        tools: [tool("send_email", "to"), tool("delete_file", "path"), tool("lookup", "query")],
        middleware: [HumanInTheLoop.new(interrupt_on: interrupt_on, interrupt_mode: :per_call)],
        checkpointer: BeamWeaver.Checkpoint.ETS.new()
      )

    {agent, [config: %{"configurable" => %{"thread_id" => "per-call-#{System.unique_integer([:positive])}"}}]}
  end

  @gated %{"send_email" => true, "delete_file" => %{allowed_decisions: [:approve, :reject]}}

  defp approvals(%{interrupts: interrupts}), do: Map.new(interrupts, &{&1.value.name, &1})

  defp tool_results(result),
    do: for(%Message{role: :tool} = message <- result.messages, into: %{}, do: {message.name, Message.text(message)})

  test "each reviewed call pauses on its own, and the others run once" do
    {agent, opts} = agent(@gated)
    assert {:interrupted, interrupt} = BWAgent.invoke(agent, %{messages: [Message.user("Go.")]}, opts)
    assert_receive {:ran, "lookup", %{"query" => "weather"}}
    refute_received {:ran, _name, _args}

    approvals = approvals(interrupt)
    assert interrupt.id in Enum.map(interrupt.interrupts, & &1.id)

    assert %{
             type: "tool_approval",
             tool_call_id: "call-email",
             args: %{"to" => "alice@example.com"},
             allowed_decisions: ["approve", "edit", "reject", "respond"],
             args_schema: %{"required" => ["to"]}
           } = approvals["send_email"].value

    assert approvals["send_email"].value.description =~ "send_email"
    assert approvals["delete_file"].value.allowed_decisions == ["approve", "reject"]
    refute Map.has_key?(approvals["delete_file"].value, :args_schema)

    answers = %{
      approvals["send_email"].id => %{
        type: "edit",
        edited_action: %{name: "send_email", args: %{"to" => "bob@example.com"}}
      },
      approvals["delete_file"].id => %{type: "reject", message: "Keep the report."}
    }

    assert {:ok, result} = BWAgent.resume_review(agent, answers, opts)
    assert_receive {:ran, "send_email", %{"to" => "bob@example.com"}}
    refute_received {:ran, _name, _args}

    results = tool_results(result)

    assert results["send_email"] =~
             ~r/^Note: a human reviewer replaced this tool call.*bob@example.com.*send_email done$/s

    assert results["delete_file"] == "User rejected the tool call for `delete_file` with reason: Keep the report."
    assert results["lookup"] == "lookup done"
    assert Message.text(List.last(result.messages)) == "seen 3 results"
  end

  test "calls can be answered one at a time, and each runs once" do
    {agent, opts} = agent(@gated)
    assert {:interrupted, interrupt} = BWAgent.invoke(agent, %{messages: [Message.user("Go.")]}, opts)
    approvals = approvals(interrupt)

    assert {:interrupted, waiting} =
             BWAgent.resume_review(agent, %{approvals["delete_file"].id => %{type: "approve"}}, opts)

    assert [%{id: email_id, value: %{name: "send_email"}}] = waiting.interrupts
    assert email_id == approvals["send_email"].id
    assert_receive {:ran, "delete_file", %{"path" => "report.txt"}}

    assert {:ok, result} = BWAgent.resume_review(agent, HumanInTheLoop.Decision.__struct__(type: :approve), opts)
    assert_receive {:ran, "send_email", %{"to" => "alice@example.com"}}
    assert_receive {:ran, "lookup", _args}
    refute_received {:ran, _name, _args}
    assert map_size(tool_results(result)) == 3
  end

  test "an answer that doesn't fit fails the resume, and the call waits for another" do
    {agent, opts} = agent(@gated)
    assert {:interrupted, interrupt} = BWAgent.invoke(agent, %{messages: [Message.user("Go.")]}, opts)
    %{"send_email" => email, "delete_file" => delete} = approvals(interrupt)

    for {id, answer, message} <- [
          {email.id, %{type: "edit", edited_action: %{name: "delete_file", args: %{"path" => "x"}}}, "keep the tool"},
          {email.id, %{type: "edit", edited_action: %{name: "send_email", args: %{"to" => 5}}}, "to"},
          {delete.id, %{type: "edit", edited_action: %{name: "delete_file", args: %{"path" => "y"}}}, "not allowed"},
          {delete.id, "approve", "not allowed"}
        ] do
      assert {:error, %Error{type: :invalid_human_decision} = error} =
               BWAgent.resume_review(agent, %{id => answer}, opts)

      assert inspect(error) =~ message
    end

    refute_received {:ran, "send_email", _args}
    refute_received {:ran, "delete_file", _args}

    answers = %{email.id => %{type: "approve"}, delete.id => %{type: "approve"}}
    assert {:ok, result} = BWAgent.resume_review(agent, answers, opts)
    assert map_size(tool_results(result)) == 3
  end

  test "a call whose rule doesn't apply runs without review" do
    {agent, opts} = agent(%{"send_email" => %{when: fn call -> call.args["to"] != "alice@example.com" end}})
    assert {:ok, result} = BWAgent.invoke(agent, %{messages: [Message.user("Go.")]}, opts)
    assert map_size(tool_results(result)) == 3
  end

  test "the mode is checked when the middleware is built" do
    assert %HumanInTheLoop{interrupt_mode: :per_call} = HumanInTheLoop.new(interrupt_mode: "per_call")
    assert_raise ArgumentError, ~r/:per_call/, fn -> HumanInTheLoop.new(interrupt_mode: :each) end
  end
end
