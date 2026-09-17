# Long-term memory as records in a BeamWeaver.Memory store.
#
# Memories are ordinary store items: a namespace per user, a key, and a map.
# The agent creates, replaces, and deletes them through three small tools that
# get the store and the run context injected; the application reads and edits
# the same records with `BeamWeaver.Memory`. Nothing here is a file.
#
# What the agent knows at the start of a conversation is loaded from the store
# into the system prompt by a prompt function, so no tool call is needed to
# recall it.
#
#   mix run examples/long_term_memory.exs            # BeamWeaver.Memory.ETS, lives as long as the VM
#
#   export BEAM_WEAVER_POSTGRES_URL=postgres://localhost/beam_weaver_examples
#   mix run examples/long_term_memory.exs --ecto     # BeamWeaver.Memory.Ecto; run it twice, the memories stay
#   mix run examples/long_term_memory.exs --ecto --reset
#
# The tools and the agent are the same for both stores.

Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Agent
alias BeamWeaver.Agent.Middleware.DynamicPrompt
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support
alias BeamWeaver.Memory

defmodule BeamWeaver.Examples.LongTermMemory.Scope do
  @moduledoc false

  # Ownership comes from the run context, never from the model.
  def namespace(%{user_id: user_id}), do: ["users", user_id, "memories"]
  def namespace(%{"user_id" => user_id}), do: ["users", user_id, "memories"]

  def arg(input, key), do: Map.get(input, key) || Map.get(input, Atom.to_string(key))
end

defmodule BeamWeaver.Examples.LongTermMemory.SaveMemory do
  use BeamWeaver.Tool

  alias BeamWeaver.Examples.LongTermMemory.Scope

  name("save_memory")

  description(
    "Remember one fact or preference about the user. Use a short stable key such as preferred_language; saving under an existing key replaces that memory."
  )

  injected(:store, :store, type: :object)
  injected(:context, :context, type: :object)

  schema do
    field(:key, :string, required: true)
    field(:content, :string, required: true)
  end

  def invoke(_tool, input, _opts) do
    namespace = input |> Scope.arg(:context) |> Scope.namespace()

    case BeamWeaver.Memory.put(Scope.arg(input, :store), namespace, Scope.arg(input, :key), %{
           "content" => Scope.arg(input, :content)
         }) do
      {:ok, item} -> {:ok, "Saved #{item.key}."}
      {:error, error} -> {:error, error}
    end
  end
end

defmodule BeamWeaver.Examples.LongTermMemory.SearchMemories do
  use BeamWeaver.Tool

  alias BeamWeaver.Examples.LongTermMemory.Scope

  name("search_memories")
  description("List what is remembered about the user, optionally only the memories containing a word or phrase.")

  injected(:store, :store, type: :object)
  injected(:context, :context, type: :object)

  schema do
    field(:query, :string, required: false)
  end

  def invoke(_tool, input, _opts) do
    namespace = input |> Scope.arg(:context) |> Scope.namespace()
    opts = if Scope.arg(input, :query) in [nil, ""], do: [limit: 20], else: [query: Scope.arg(input, :query), limit: 20]

    {:ok,
     input |> Scope.arg(:store) |> BeamWeaver.Memory.search(namespace, opts) |> Map.new(&{&1.key, &1.value["content"]})}
  end
end

defmodule BeamWeaver.Examples.LongTermMemory.DeleteMemory do
  use BeamWeaver.Tool

  alias BeamWeaver.Examples.LongTermMemory.Scope

  name("delete_memory")
  description("Forget one memory by its key.")

  injected(:store, :store, type: :object)
  injected(:context, :context, type: :object)

  schema do
    field(:key, :string, required: true)
  end

  def invoke(_tool, input, _opts) do
    namespace = input |> Scope.arg(:context) |> Scope.namespace()
    :ok = BeamWeaver.Memory.delete(Scope.arg(input, :store), namespace, Scope.arg(input, :key))
    {:ok, "Deleted #{Scope.arg(input, :key)}."}
  end
end

defmodule BeamWeaver.Examples.LongTermMemory.Postgres do
  @moduledoc false

  defmodule Repo do
    use Ecto.Repo, otp_app: :beam_weaver, adapter: Ecto.Adapters.Postgres
  end

  defmodule CreateMemoryTable do
    use Ecto.Migration

    # In an application this is an ordinary migration file.
    def up, do: BeamWeaver.Migrations.up(adapters: [{:memory, table: "beam_weaver_example_memories"}])
    def down, do: BeamWeaver.Migrations.down(adapters: [{:memory, table: "beam_weaver_example_memories"}], version: 1)
  end

  def store do
    url =
      BeamWeaver.Config.get([:examples, :postgres_url]) ||
        raise "set BEAM_WEAVER_POSTGRES_URL to a PostgreSQL database, for example postgres://localhost/beam_weaver_examples"

    # The example keeps its own migrations table, so it can share a database with an application schema.
    Application.put_env(:beam_weaver, Repo,
      url: url,
      pool_size: 2,
      log: false,
      migration_source: "beam_weaver_example_migrations"
    )

    {:ok, _pid} = Repo.start_link()
    Ecto.Migrator.up(Repo, 2026_01_01_000001, CreateMemoryTable, log: false)

    BeamWeaver.Memory.Ecto.new(repo: Repo, table: "beam_weaver_example_memories")
  end
end

alias BeamWeaver.Examples.LongTermMemory.{DeleteMemory, Postgres, SaveMemory, Scope, SearchMemories}

args = System.argv()
store = if "--ecto" in args, do: Postgres.store(), else: Memory.ETS.new()
ada = ["users", "ada", "memories"]

show = fn label ->
  IO.puts("\n#{label}")

  case Memory.search(store, ada, limit: 50) do
    [] -> IO.puts("  (none)")
    items -> Enum.each(items, &IO.puts("  #{&1.key}: #{&1.value["content"]}"))
  end
end

if "--reset" in args do
  :ok = Memory.delete_many(store, ada, Memory.yield_keys(store, ada))
  show.("Memories of ada after the reset:")
  System.halt(0)
end

instructions = """
You are a personal assistant. Save what the user tells you about themselves with save_memory, one memory per fact, \
and remove a memory with delete_memory when they ask you to forget it. Keep every answer to one or two sentences.
"""

# Runs before every model call: the prompt always carries the memories as they are in the store right now.
prompt = fn _state, runtime ->
  memories =
    runtime.store
    |> Memory.search(Scope.namespace(runtime.context), limit: 50)
    |> Enum.map_join("\n", &"- #{&1.key}: #{&1.value["content"]}")

  instructions <> "\nWhat you remember about this user:\n" <> if(memories == "", do: "(nothing yet)", else: memories)
end

{:ok, agent} =
  Agent.build(
    name: "long_term_memory",
    model: Support.model(),
    model_opts: [timeout: 120_000],
    store: store,
    tools: [SaveMemory, SearchMemories, DeleteMemory],
    middleware: [{DynamicPrompt, prompt: prompt}]
  )

converse = fn user_id, text ->
  {:ok, %{messages: messages}} =
    Agent.invoke(agent, %{messages: [Message.user(text)]}, context: %{user_id: user_id}, run_timeout: 240_000)

  calls =
    for %Message{role: :assistant, tool_calls: calls} <- messages,
        call <- calls,
        do: "#{call.name}(#{inspect(call.args)})"

  IO.puts("\n[#{user_id}] #{text}")
  Enum.each(calls, &IO.puts("  tool: #{&1}"))
  IO.puts("  agent: #{messages |> List.last() |> Message.text()}")
end

show.("Memories of ada before this run:")

# Every call is a new conversation; what carries over is in the store.
converse.("ada", "I'm vegetarian and I live in Lisbon. Please remember both.")
converse.("ada", "Suggest a dinner for tonight.")
converse.("bob", "Suggest a dinner for tonight.")

# The application works on the same records: find one by its text and replace it, then add another.
city_key =
  case Memory.search(store, ada, query: "lisbon", limit: 1) do
    [%Memory.Item{key: key}] -> key
    [] -> "city"
  end

{:ok, _item} =
  Memory.put(store, ada, city_key, %{"content" => "Lives in Porto (moved from Lisbon)."},
    metadata: %{"source" => "profile form"}
  )

{:ok, _item} = Memory.put(store, ada, "allergy", %{"content" => "Allergic to peanuts."})
show.("Memories of ada after the application edited them:")

converse.("ada", "Where do I live, and is there anything you should avoid cooking for me?")
converse.("ada", "Please forget where I live.")

show.("Memories of ada at the end:")

IO.puts(
  "\nbob has #{length(Memory.search(store, ["users", "bob", "memories"]))} memories; namespaces: #{inspect(Memory.list_namespaces(store, prefix: ["users"]))}"
)
