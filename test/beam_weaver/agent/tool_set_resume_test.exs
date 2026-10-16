defmodule BeamWeaver.Agent.ToolSetResumeTest do
  # The tools node runs only the tools the model was offered on its latest
  # call. A run that continues from a checkpoint (after a review, a breakpoint
  # or a crash) gets the same tools as one that never paused.
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.HITL
  alias BeamWeaver.Agent.Middleware.ToolSelection
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models.FakeChatModel

  defp tool(name) do
    parent = self()

    Tool.from_function!(
      name: name,
      description: "The #{name} tool.",
      input_schema: %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}},
      handler: fn _args, _opts ->
        send(parent, {:tool_ran, name})
        "#{name} ran"
      end
    )
  end

  defp thread(id), do: [checkpointer: Checkpoint.ETS.new(), config: %{"configurable" => %{"thread_id" => id}}]

  defp tool_texts(state), do: for(%Message{role: :tool} = message <- state.messages, do: Message.text(message))

  test "a tool exclude_tools hides doesn't run after interrupt_before tools and resume" do
    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{responses: [FakeChatModel.tool_call("wipe_ledger", %{"id" => "1"}), "done"]},
        tools: [tool("lookup"), tool("wipe_ledger")],
        exclude_tools: ["wipe_ledger"],
        interrupt_before: [:tools]
      )

    opts = thread("breakpoint")
    assert {:interrupted, _interrupt} = Agent.invoke(agent, %{messages: ["Clean up."]}, opts)
    assert {:ok, state} = Agent.resume(agent, nil, opts)

    assert ["Tool error: tool is not registered" <> _] = tool_texts(state)
    refute_received {:tool_ran, "wipe_ledger"}
  end

  test "a tool exclude_tools hides doesn't run after a review of another tool" do
    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{
          responses: [
            FakeChatModel.tool_calls([{"lookup", %{"id" => "a"}}, {"wipe_ledger", %{"id" => "b"}}]),
            "done"
          ]
        },
        tools: [tool("lookup"), tool("wipe_ledger")],
        exclude_tools: ["wipe_ledger"],
        interrupt_on: %{"lookup" => true}
      )

    opts = thread("review")
    assert {:interrupted, _interrupt} = Agent.invoke(agent, %{messages: ["Clean up."]}, opts)
    assert {:ok, state} = Agent.resume_review(agent, [HITL.decision(:approve)], opts)

    assert ["lookup ran", "Tool error: tool is not registered" <> _] = tool_texts(state)
    assert_received {:tool_ran, "lookup"}
    refute_received {:tool_ran, "wipe_ledger"}
  end

  test "a tool that ToolSelection adds runs after a review" do
    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{responses: [FakeChatModel.tool_call("lookup", %{"id" => "1"}), "done"]},
        middleware: [{ToolSelection, tools: [tool("lookup")]}],
        interrupt_on: %{"lookup" => true}
      )

    opts = thread("added")
    assert {:interrupted, _interrupt} = Agent.invoke(agent, %{messages: ["Look it up."]}, opts)
    assert {:ok, state} = Agent.resume_review(agent, [HITL.decision(:approve)], opts)

    assert tool_texts(state) == ["lookup ran"]
  end

  test "the offered tools don't show in the result or the thread's state" do
    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{responses: [FakeChatModel.tool_call("lookup", %{"id" => "1"}), "done"]},
        tools: [tool("lookup")]
      )

    opts = thread("private")
    assert {:ok, state} = Agent.invoke(agent, %{messages: ["Look it up."]}, opts)
    assert {:ok, snapshot} = Agent.get_state(agent, opts)

    refute Map.has_key?(state, :tool_set_names)
    refute Map.has_key?(snapshot.values, :tool_set_names)
  end
end

defmodule BeamWeaver.Agent.ToolSetResumeSQLiteTest do
  # The SQLite repo has a single connection, shared with other suites.
  use ExUnit.Case, async: false

  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Test.LiveSQLite
  alias BeamWeaver.Test.SQLiteRepo

  test "the offered tools survive a checkpointer that stores JSON" do
    checkpoints = LiveSQLite.unique_table("bw_tool_set_checkpoints")
    writes = LiveSQLite.unique_table("bw_tool_set_writes")

    version =
      LiveSQLite.migrate(
        repo: SQLiteRepo,
        adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]
      )

    on_exit(fn ->
      LiveSQLite.drop_tables([writes, checkpoints])
      LiveSQLite.clear_migration(version)
    end)

    tool = fn name ->
      Tool.from_function!(
        name: name,
        description: "The #{name} tool.",
        input_schema: %{"type" => "object", "properties" => %{}},
        handler: fn _args, _opts -> "#{name} ran" end
      )
    end

    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{
          responses: [FakeChatModel.tool_calls([{"lookup", %{}}, {"wipe_ledger", %{}}]), "done"]
        },
        tools: [tool.("lookup"), tool.("wipe_ledger")],
        exclude_tools: ["wipe_ledger"],
        interrupt_before: [:tools]
      )

    saver = BeamWeaver.Checkpoint.Ecto.new(repo: SQLiteRepo, checkpoints_table: checkpoints, writes_table: writes)
    opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "sqlite-tools"}}]

    assert {:interrupted, _interrupt} = Agent.invoke(agent, %{messages: ["Clean up."]}, opts)
    assert {:ok, state} = Agent.resume(agent, nil, opts)

    assert ["lookup ran", "Tool error: tool is not registered" <> _] =
             for(%Message{role: :tool} = message <- state.messages, do: Message.text(message))
  end
end
