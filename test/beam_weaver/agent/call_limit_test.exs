defmodule BeamWeaver.Agent.CallLimitTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.ModelCallLimit
  alias BeamWeaver.Agent.Middleware.ToolCallLimit
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.FakeChatModel

  defmodule LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up an order."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped."}
  end

  defmodule ThreadModelLimitAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["First answer.", "Second answer.", "Third answer."]
    middleware [{ModelCallLimit, thread_limit: 2, exit_behavior: :end}]
  end

  defmodule RunModelLimitAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["First answer.", "Second answer.", "Third answer."]
    middleware [{ModelCallLimit, run_limit: 1, exit_behavior: :end}]
  end

  defmodule ThreadToolLimitAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses: [
        FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
        "A-1001 shipped.",
        FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1002"}),
        "I can't look up more orders."
      ]

    tools [LookupOrder]
    middleware [{ToolCallLimit, tool_name: "lookup_order", thread_limit: 1}]
  end

  defmodule LongRunAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses:
        List.duplicate(FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}), 11) ++
          ["Done after eleven lookups."]

    tools [LookupOrder]
    middleware [{ModelCallLimit, run_limit: 20}, {ToolCallLimit, run_limit: 20}]
  end

  defp thread(id), do: [checkpointer: Checkpoint.ETS.new(), config: %{"configurable" => %{"thread_id" => id}}]

  defp last_text(result), do: result.messages |> List.last() |> Message.text()

  test "the thread model call count carries over between runs on a thread" do
    opts = thread("model-thread")

    assert {:ok, first} = ThreadModelLimitAgent.invoke(%{messages: ["One?"]}, opts)
    assert last_text(first) == "First answer."
    refute Map.has_key?(first, :thread_model_call_count)

    assert {:ok, second} = ThreadModelLimitAgent.invoke(%{messages: ["Two?"]}, opts)
    assert last_text(second) == "Second answer."

    assert {:ok, third} = ThreadModelLimitAgent.invoke(%{messages: ["Three?"]}, opts)
    assert last_text(third) == "Model call limits exceeded: thread limit (2/2)"
  end

  test "the run model call count starts again with every run" do
    opts = thread("model-run")

    for {question, answer} <- [{"One?", "First answer."}, {"Two?", "Second answer."}, {"Three?", "Third answer."}] do
      assert {:ok, result} = RunModelLimitAgent.invoke(%{messages: [question]}, opts)
      assert last_text(result) == answer
    end
  end

  test "the thread tool call count carries over between runs on a thread" do
    opts = thread("tool-thread")

    assert {:ok, first} = ThreadToolLimitAgent.invoke(%{messages: ["Where is A-1001?"]}, opts)
    assert ["Order A-1001 shipped."] = for(%{role: :tool} = message <- first.messages, do: Message.text(message))

    assert {:ok, second} = ThreadToolLimitAgent.invoke(%{messages: ["And A-1002?"]}, opts)

    assert ["Order A-1001 shipped.", "Tool call limit exceeded. Do not call 'lookup_order' again."] =
             for(%{role: :tool} = message <- second.messages, do: Message.text(message))
  end

  test "limits have no default, so a run limit over 10 works on its own" do
    assert %ToolCallLimit{thread_limit: nil, run_limit: 20} = ToolCallLimit.new(run_limit: 20)
    assert %ModelCallLimit{thread_limit: nil, run_limit: 20} = ModelCallLimit.new(run_limit: 20)

    assert {:ok, result} = LongRunAgent.invoke(%{messages: ["Look it up eleven times."]})
    assert last_text(result) == "Done after eleven lookups."
    assert Enum.count(result.messages, &(&1.role == :tool)) == 11
  end

  test "a limit message lists only the limits that were reached" do
    middleware = ModelCallLimit.new(thread_limit: 10, run_limit: 2, exit_behavior: :end)

    assert %{messages: [message]} =
             ModelCallLimit.before_model(middleware, %{thread_model_call_count: 2, run_model_call_count: 2}, nil)

    assert Message.text(message) == "Model call limits exceeded: run limit (2/2)"
  end
end

defmodule BeamWeaver.Agent.CallLimitSQLiteTest do
  # The SQLite repo has a single connection, shared with other suites.
  use ExUnit.Case, async: false

  alias BeamWeaver.Agent.CallLimitTest.ThreadModelLimitAgent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Test.LiveSQLite
  alias BeamWeaver.Test.SQLiteRepo

  test "the thread count survives a checkpointer that stores JSON" do
    checkpoints = LiveSQLite.unique_table("bw_call_limit_checkpoints")
    writes = LiveSQLite.unique_table("bw_call_limit_writes")

    version =
      LiveSQLite.migrate(
        repo: SQLiteRepo,
        adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]
      )

    on_exit(fn ->
      LiveSQLite.drop_tables([writes, checkpoints])
      LiveSQLite.clear_migration(version)
    end)

    saver = BeamWeaver.Checkpoint.Ecto.new(repo: SQLiteRepo, checkpoints_table: checkpoints, writes_table: writes)
    opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "sqlite-thread"}}]

    assert {:ok, _first} = ThreadModelLimitAgent.invoke(%{messages: ["One?"]}, opts)
    assert {:ok, _second} = ThreadModelLimitAgent.invoke(%{messages: ["Two?"]}, opts)
    assert {:ok, third} = ThreadModelLimitAgent.invoke(%{messages: ["Three?"]}, opts)

    assert third.messages |> List.last() |> Message.text() == "Model call limits exceeded: thread limit (2/2)"
  end
end
