defmodule BeamWeaver.Agent.HumanInTheLoopNewMessageTest.Model do
  # Answers a user message listed in `turns` with its tool calls, any other
  # user message with "ok: <text>", and tool results with "done".
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message

  defstruct [:parent, turns: %{}]

  @impl true
  def invoke(%__MODULE__{parent: parent, turns: turns}, messages, _opts) do
    send(parent, {:model_request, Enum.map(messages, &{&1.role, Message.text(&1)})})

    case List.last(messages) do
      %Message{role: :user} = message ->
        text = Message.text(message)

        case Map.fetch(turns, text) do
          {:ok, calls} -> {:ok, Message.assistant("", tool_calls: calls)}
          :error -> {:ok, Message.assistant("ok: " <> text)}
        end

      _tool_result ->
        {:ok, Message.assistant("done")}
    end
  end
end

defmodule BeamWeaver.Agent.HumanInTheLoopNewMessageTest.Scenario do
  import ExUnit.Assertions

  alias BeamWeaver.Agent, as: BWAgent
  alias BeamWeaver.Agent.HumanInTheLoopNewMessageTest.Model
  alias BeamWeaver.Agent.Middleware.HumanInTheLoop
  alias BeamWeaver.Core.{Message, Tool}

  @email %{id: "call-email", name: "send_email", args: %{"to" => "alice@example.com"}}
  @lookup %{id: "call-lookup", name: "lookup", args: %{"query" => "alice"}}

  def email, do: @email
  def lookup, do: @lookup

  def agent(turns, middleware_opts, build_opts \\ []) do
    {:ok, agent} =
      [
        model: %Model{parent: self(), turns: turns},
        tools: [tool("send_email"), tool("lookup")],
        middleware: [HumanInTheLoop.new(middleware_opts)],
        checkpointer: BeamWeaver.Checkpoint.ETS.new()
      ]
      |> Keyword.merge(build_opts)
      |> BWAgent.build()

    {agent, [config: %{"configurable" => %{"thread_id" => "new-message-#{System.unique_integer([:positive])}"}}]}
  end

  defp tool(name) do
    parent = self()

    Tool.from_function!(
      name: name,
      description: "Run #{name}.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"to" => %{"type" => "string"}, "query" => %{"type" => "string"}}
      },
      handler: fn args, _opts ->
        send(parent, {:ran, name, args})
        "#{name} done"
      end
    )
  end

  def cancelled(call),
    do: "Tool call #{call.name} with id #{call.id} was not run: a new message came in while it waited for review."

  def history(messages), do: Enum.map(messages, &{&1.role, Message.text(&1)})

  # With one pause per call, the cancelled call's answer is saved after the
  # new message. A breakpoint before the model stops the run there, so the
  # model node reads the answer back from the checkpointer before it moves
  # the answer up to its turn.
  def per_call_answer_read_back(checkpointer) do
    {agent, opts} =
      agent(%{"Email Alice." => [@lookup, @email]}, [interrupt_on: %{"send_email" => true}, interrupt_mode: :per_call],
        checkpointer: checkpointer,
        interrupt_before: [:model]
      )

    assert {:interrupted, %{timing: :before}} = BWAgent.invoke(agent, %{messages: ["Email Alice."]}, opts)
    assert {:interrupted, %{value: %{type: "tool_approval"}}} = BWAgent.resume(agent, nil, opts)
    assert {:interrupted, %{timing: :before}} = BWAgent.invoke(agent, %{messages: ["Stop."]}, opts)

    assert {:ok, snapshot} = BWAgent.get_state(agent, opts)

    assert %Message{status: "error", metadata: %{error_type: :review_cancelled}} =
             Enum.find(snapshot.values.messages, &match?(%Message{tool_call_id: "call-email"}, &1))

    assert {:ok, result} = BWAgent.resume(agent, nil, opts)

    expected = [
      user: "Email Alice.",
      assistant: "",
      tool: "lookup done",
      tool: cancelled(@email),
      user: "Stop."
    ]

    assert_receive {:model_request, ^expected}
    assert history(result.messages) == expected ++ [assistant: "ok: Stop."]

    assert {:ok, snapshot} = BWAgent.get_state(agent, opts)
    assert history(snapshot.values.messages) == history(result.messages)
  end
end

defmodule BeamWeaver.Agent.HumanInTheLoopNewMessageTest do
  # A message sent to a thread whose tool calls wait for review cancels the
  # review: each waiting call is answered right after the assistant message
  # that made it, and the run goes on with the new message.
  use ExUnit.Case, async: true

  import BeamWeaver.Agent.HumanInTheLoopNewMessageTest.Scenario,
    only: [agent: 2, cancelled: 1, email: 0, history: 1, lookup: 0]

  alias BeamWeaver.Agent, as: BWAgent
  alias BeamWeaver.Agent.HITL
  alias BeamWeaver.Agent.HumanInTheLoopNewMessageTest.Scenario
  alias BeamWeaver.Core.{Error, Message}

  test "a new message cancels the pending review, and the model answers it" do
    {agent, opts} = agent(%{"Email Alice." => [email()]}, interrupt_on: %{"send_email" => true})

    assert {:interrupted, _interrupt} = BWAgent.invoke(agent, %{messages: ["Email Alice."]}, opts)
    assert_receive {:model_request, _first}

    assert {:ok, result} = BWAgent.invoke(agent, %{messages: ["Never mind, don't send it."]}, opts)

    expected = [
      user: "Email Alice.",
      assistant: "",
      tool: cancelled(email()),
      user: "Never mind, don't send it."
    ]

    assert_receive {:model_request, ^expected}
    assert history(result.messages) == expected ++ [assistant: "ok: Never mind, don't send it."]
    refute_received {:ran, _name, _args}

    assert %Message{name: "send_email", status: "error", metadata: %{status: "error", error_type: :review_cancelled}} =
             Enum.find(result.messages, &match?(%Message{role: :tool, tool_call_id: "call-email"}, &1))

    assert {:ok, snapshot} = BWAgent.get_state(agent, opts)
    assert history(snapshot.values.messages) == history(result.messages)
    assert snapshot.interrupts == []
    assert snapshot.next == []
  end

  test "a resume for the cancelled review changes nothing" do
    {agent, opts} = agent(%{"Email Alice." => [email()]}, interrupt_on: %{"send_email" => true})

    assert {:interrupted, _interrupt} = BWAgent.invoke(agent, %{messages: ["Email Alice."]}, opts)
    assert {:ok, result} = BWAgent.invoke(agent, %{messages: ["Never mind."]}, opts)
    assert_receive {:model_request, _first}
    assert_receive {:model_request, _second}

    assert {:ok, after_resume} = BWAgent.resume_review(agent, [HITL.decision(:approve)], opts)
    assert history(after_resume.messages) == history(result.messages)
    refute_received {:ran, _name, _args}
    refute_received {:model_request, _request}
  end

  test "a message added with update_state cancels the review, even when a decision follows" do
    {agent, opts} = agent(%{"Email Alice." => [email()]}, interrupt_on: %{"send_email" => true})

    assert {:interrupted, _interrupt} = BWAgent.invoke(agent, %{messages: ["Email Alice."]}, opts)
    config = Keyword.fetch!(opts, :config)
    assert {:ok, _config} = BeamWeaver.Graph.Compiled.update_state(agent.compiled, config, %{messages: ["Stop."]})

    assert {:ok, result} = BWAgent.resume_review(agent, [HITL.decision(:approve)], opts)
    refute_received {:ran, _name, _args}

    assert history(result.messages) == [
             user: "Email Alice.",
             assistant: "",
             tool: cancelled(email()),
             user: "Stop.",
             assistant: "ok: Stop."
           ]
  end

  test "every call of the turn is answered, also the ones that needed no review" do
    {agent, opts} = agent(%{"Email Alice." => [lookup(), email()]}, interrupt_on: %{"send_email" => true})

    assert {:interrupted, _interrupt} = BWAgent.invoke(agent, %{messages: ["Email Alice."]}, opts)
    assert {:ok, result} = BWAgent.invoke(agent, %{messages: ["Stop."]}, opts)

    assert history(result.messages) == [
             user: "Email Alice.",
             assistant: "",
             tool: cancelled(lookup()),
             tool: cancelled(email()),
             user: "Stop.",
             assistant: "ok: Stop."
           ]

    refute_received {:ran, _name, _args}
  end

  test "with one pause per call, a waiting call is answered after the results of its turn" do
    {agent, opts} =
      agent(%{"Email Alice." => [lookup(), email()]}, interrupt_on: %{"send_email" => true}, interrupt_mode: :per_call)

    assert {:interrupted, _interrupt} = BWAgent.invoke(agent, %{messages: ["Email Alice."]}, opts)
    assert_receive {:ran, "lookup", _args}
    assert_receive {:model_request, _first}

    assert {:ok, result} = BWAgent.invoke(agent, %{messages: ["Stop."]}, opts)

    expected = [
      user: "Email Alice.",
      assistant: "",
      tool: "lookup done",
      tool: cancelled(email()),
      user: "Stop."
    ]

    assert_receive {:model_request, ^expected}
    assert history(result.messages) == expected ++ [assistant: "ok: Stop."]
    refute_received {:ran, _name, _args}

    assert {:ok, snapshot} = BWAgent.get_state(agent, opts)
    assert history(snapshot.values.messages) == history(result.messages)
    assert snapshot.interrupts == []
  end

  test "the per-call answer moves up to its turn after the thread is read back" do
    Scenario.per_call_answer_read_back(BeamWeaver.Checkpoint.ETS.new())
  end

  test "after a cancelled review, the next turn's review is approved as usual" do
    bob = %{id: "call-bob", name: "send_email", args: %{"to" => "bob@example.com"}}

    {agent, opts} =
      agent(%{"Email Alice." => [email()], "Email Bob instead." => [bob]}, interrupt_on: %{"send_email" => true})

    assert {:interrupted, _interrupt} = BWAgent.invoke(agent, %{messages: ["Email Alice."]}, opts)
    assert {:interrupted, interrupt} = BWAgent.invoke(agent, %{messages: ["Email Bob instead."]}, opts)
    assert [%{args: %{"to" => "bob@example.com"}}] = interrupt.value.action_requests

    assert {:ok, result} = BWAgent.resume_review(agent, [HITL.decision(:approve)], opts)
    assert_receive {:ran, "send_email", %{"to" => "bob@example.com"}}
    refute_received {:ran, _name, _args}

    assert history(result.messages) == [
             user: "Email Alice.",
             assistant: "",
             tool: cancelled(email()),
             user: "Email Bob instead.",
             assistant: "",
             tool: "send_email done",
             assistant: "done"
           ]
  end

  test "a history passed in with an unanswered call still fails" do
    {agent, opts} = agent(%{}, interrupt_on: %{"send_email" => true})

    history = [
      Message.user("Email Alice."),
      Message.assistant("", tool_calls: [email()]),
      Message.user("Never mind.")
    ]

    assert {:error, %Error{type: :invalid_chat_history, details: %{missing_tool_calls: [%{id: "call-email"}]}}} =
             BWAgent.invoke(agent, %{messages: history}, opts)
  end
end

defmodule BeamWeaver.Agent.HumanInTheLoopNewMessageSQLiteTest do
  # The SQLite repo has a single connection, shared with other suites.
  use ExUnit.Case, async: false

  alias BeamWeaver.Agent.HumanInTheLoopNewMessageTest.Scenario
  alias BeamWeaver.Test.LiveSQLite
  alias BeamWeaver.Test.SQLiteRepo

  test "the per-call answer survives a checkpointer that stores JSON" do
    checkpoints = LiveSQLite.unique_table("bw_review_cancel_checkpoints")
    writes = LiveSQLite.unique_table("bw_review_cancel_writes")

    version =
      LiveSQLite.migrate(
        repo: SQLiteRepo,
        adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]
      )

    on_exit(fn ->
      LiveSQLite.drop_tables([writes, checkpoints])
      LiveSQLite.clear_migration(version)
    end)

    Scenario.per_call_answer_read_back(
      BeamWeaver.Checkpoint.Ecto.new(repo: SQLiteRepo, checkpoints_table: checkpoints, writes_table: writes)
    )
  end
end

defmodule BeamWeaver.Agent.HumanInTheLoopNewMessagePostgresTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias BeamWeaver.Agent.HumanInTheLoopNewMessageTest.Scenario
  alias BeamWeaver.Test.LivePostgres
  alias BeamWeaver.Test.PostgresRepo

  test "the per-call answer survives Postgres checkpoints" do
    assert LivePostgres.available?()

    checkpoints = LivePostgres.unique_table("bw_review_cancel_checkpoints")
    writes = LivePostgres.unique_table("bw_review_cancel_writes")
    version = LivePostgres.migrate(adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}])

    on_exit(fn ->
      LivePostgres.drop_tables([writes, checkpoints])
      LivePostgres.clear_migration(version)
    end)

    Scenario.per_call_answer_read_back(
      BeamWeaver.Checkpoint.Ecto.new(repo: PostgresRepo, checkpoints_table: checkpoints, writes_table: writes)
    )
  end
end
