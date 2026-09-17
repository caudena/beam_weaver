defmodule BeamWeaver.Memory.AgentMemoryTest.Tools do
  @moduledoc false
  # Memory tools over the store, the way an application defines them: the store
  # and the run context are injected, the model only sees key, content, query.

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Memory

  def all, do: [save(), search(), delete()]

  defp save do
    Tool.from_function!(
      name: "save_memory",
      description: "Remember one fact about the user under a short key.",
      input_schema: schema(%{"key" => %{"type" => "string"}, "content" => %{"type" => "string"}}, ["key", "content"]),
      injected: [context: :context, store: :store],
      handler: fn input, _opts ->
        {:ok, item} = Memory.put(input.store, namespace(input.context), input["key"], %{"content" => input["content"]})
        "Saved #{item.key}."
      end
    )
  end

  defp search do
    Tool.from_function!(
      name: "search_memories",
      description: "List what is remembered about the user.",
      input_schema: schema(%{"query" => %{"type" => "string"}}, []),
      injected: [context: :context, store: :store],
      handler: fn input, _opts ->
        opts = if input["query"] in [nil, ""], do: [], else: [query: input["query"]]

        input.store
        |> Memory.search(namespace(input.context), opts)
        |> Enum.map_join("; ", &"#{&1.key}: #{&1.value["content"]}")
      end
    )
  end

  defp delete do
    Tool.from_function!(
      name: "delete_memory",
      description: "Forget one memory by its key.",
      input_schema: schema(%{"key" => %{"type" => "string"}}, ["key"]),
      injected: [context: :context, store: :store],
      handler: fn input, _opts ->
        :ok = Memory.delete(input.store, namespace(input.context), input["key"])
        "Deleted #{input["key"]}."
      end
    )
  end

  def namespace(%{user_id: user_id}), do: ["users", user_id, "memories"]

  defp schema(properties, required) do
    %{
      "type" => "object",
      "properties" => Map.merge(properties, %{"context" => %{"type" => "object"}, "store" => %{"type" => "object"}}),
      "required" => required ++ ["context", "store"]
    }
  end
end

defmodule BeamWeaver.Memory.AgentMemoryTest.ScriptedModel do
  @moduledoc false
  # Calls the memory tool the user's request asks for, then answers with the
  # tool result. Reports every system prompt it is called with.
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall

  defstruct [:parent]

  @impl true
  def invoke(%__MODULE__{parent: parent}, messages, _opts) do
    send(
      parent,
      {:system_prompt, messages |> Enum.filter(&(&1.role == :system)) |> Enum.map_join("\n", &Message.text/1)}
    )

    request = messages |> Enum.filter(&(&1.role == :user)) |> List.last() |> Message.text()
    tool_result = Enum.find(messages, &(&1.role == :tool))

    cond do
      tool_result -> {:ok, Message.assistant(Message.text(tool_result))}
      request =~ "Remember" -> call("save_memory", %{"key" => "diet", "content" => "Vegetarian."})
      request =~ "Forget" -> call("delete_memory", %{"key" => "diet"})
      request =~ "What do you remember" -> call("search_memories", %{"query" => "vegetarian"})
      true -> {:ok, Message.assistant("Hello.")}
    end
  end

  defp call(name, args),
    do: {:ok, Message.assistant("", tool_calls: [%ToolCall{id: "call-1", call_id: "call-1", name: name, args: args}])}
end

defmodule BeamWeaver.Memory.AgentMemoryTest.Scenario do
  @moduledoc false
  # One scenario for every store adapter: the agent and the application do
  # create, read, update, and delete on the same records.

  import ExUnit.Assertions

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware.DynamicPrompt
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Memory
  alias BeamWeaver.Memory.AgentMemoryTest.{ScriptedModel, Tools}

  @ada ["users", "ada", "memories"]

  def run(store) do
    prompt = fn _state, runtime ->
      memories =
        runtime.store
        |> Memory.search(Tools.namespace(runtime.context))
        |> Enum.map_join("\n", &"- #{&1.key}: #{&1.value["content"]}")

      "You are an assistant.\nKnown about the user:\n" <> memories
    end

    {:ok, agent} =
      Agent.build(
        model: %ScriptedModel{parent: self()},
        store: store,
        tools: Tools.all(),
        middleware: [{DynamicPrompt, prompt: prompt}]
      )

    # Create, through the agent's tool: the memory is a plain record in the store.
    assert reply(agent, "ada", "Remember that I am vegetarian.") == "Saved diet."

    assert {:ok, %Memory.Item{key: "diet", namespace: @ada, value: %{"content" => "Vegetarian."}}} =
             Memory.get(store, @ada, "diet")

    # Read: a new conversation of the same user has it in the prompt, another user's does not.
    assert prompt_of(agent, "ada") =~ "- diet: Vegetarian."
    refute prompt_of(agent, "bob") =~ "Vegetarian"
    assert reply(agent, "ada", "What do you remember about me?") == "diet: Vegetarian."

    # Update, by the application, on the same record.
    assert {:ok, _item} = Memory.put(store, @ada, "diet", %{"content" => "Vegan."})
    assert [%Memory.Item{key: "diet", value: %{"content" => "Vegan."}}] = Memory.search(store, @ada)
    assert prompt_of(agent, "ada") =~ "- diet: Vegan."

    # Delete, through the agent's tool.
    assert reply(agent, "ada", "Forget my diet.") == "Deleted diet."
    assert Memory.get(store, @ada, "diet") == :error
    refute prompt_of(agent, "ada") =~ "diet"
  end

  defp reply(agent, user_id, text) do
    assert {:ok, %{messages: messages}} =
             Agent.invoke(agent, %{messages: [Message.user(text)]}, context: %{user_id: user_id})

    messages |> List.last() |> Message.text()
  end

  defp prompt_of(agent, user_id) do
    flush()
    assert {:ok, _state} = Agent.invoke(agent, %{messages: [Message.user("Hello")]}, context: %{user_id: user_id})
    assert_receive {:system_prompt, prompt}
    prompt
  end

  defp flush do
    receive do
      {:system_prompt, _prompt} -> flush()
    after
      0 -> :ok
    end
  end
end

defmodule BeamWeaver.Memory.AgentMemoryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Memory.AgentMemoryTest.Scenario

  test "an agent and the application create, read, update, and delete memories in an ETS store" do
    Scenario.run(BeamWeaver.Memory.ETS.new())
  end
end

defmodule BeamWeaver.Memory.AgentMemoryPostgresTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias BeamWeaver.Memory.AgentMemoryTest.Scenario
  alias BeamWeaver.Test.LivePostgres
  alias BeamWeaver.Test.PostgresRepo

  setup do
    assert LivePostgres.available?()

    table = LivePostgres.unique_table("bw_agent_memory")
    version = LivePostgres.migrate(adapters: [{:memory, table: table}])

    on_exit(fn ->
      LivePostgres.drop_tables([table])
      LivePostgres.clear_migration(version)
    end)

    %{table: table}
  end

  test "an agent and the application create, read, update, and delete memories in Postgres", %{table: table} do
    Scenario.run(BeamWeaver.Memory.Ecto.new(repo: PostgresRepo, table: table))

    # The memories were rows; the scenario ends with the last one deleted.
    assert %{rows: [[0]]} = Ecto.Adapters.SQL.query!(PostgresRepo, "SELECT count(*) FROM #{table}", [])
  end

  test "a store handle created later reads the rows an earlier one wrote", %{table: table} do
    first = BeamWeaver.Memory.Ecto.new(repo: PostgresRepo, table: table)

    assert {:ok, _item} =
             BeamWeaver.Memory.put(first, ["users", "ada", "memories"], "city", %{"content" => "Lives in Lisbon."})

    later = BeamWeaver.Memory.Ecto.new(repo: PostgresRepo, table: table)

    assert [%BeamWeaver.Memory.Item{key: "city", value: %{"content" => "Lives in Lisbon."}}] =
             BeamWeaver.Memory.search(later, ["users", "ada", "memories"], query: "lisbon")
  end
end
