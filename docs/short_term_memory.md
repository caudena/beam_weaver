# Short-Term Memory

Short-term memory is a thread's own history: the messages and other state of
one conversation, saved by a checkpointer after every step. Use it whenever a
conversation spans more than one call, so the agent knows what was already
said.

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat",
    responses: [
      "Hi Ada! Order A-1001 shipped on Monday.",
      "You're Ada, and you asked about order A-1001."
    ]

  system_prompt "You are Acme's support agent."
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:ok, _first} = MyApp.SupportAgent.invoke(%{messages: ["Hi, I'm Ada. Where is order A-1001?"]}, opts)
{:ok, second} = MyApp.SupportAgent.invoke(%{messages: ["Who am I, and what did I ask?"]}, opts)

Enum.map(second.messages, &BeamWeaver.Core.Message.text/1)
#=> ["Hi, I'm Ada. Where is order A-1001?", "Hi Ada! Order A-1001 shipped on Monday.",
#    "Who am I, and what did I ask?", "You're Ada, and you asked about order A-1001."]
```

The second call loaded the first exchange before it asked the model. The
checkpointer saves the thread after each step, and the `thread_id` in
`config:` says which thread to load.

## Threads

Each `thread_id` is its own conversation. A new id starts empty, and a call
without a checkpointer always starts fresh:

```elixir
other = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-43"}}]

{:ok, fresh} = MyApp.SupportAgent.invoke(%{messages: ["Hello!"]}, other)
length(fresh.messages)
#=> 2
```

Pick thread ids your application can find again, such as a support ticket's
id. Create the saver once, for example in your supervision tree, and pass it
on every call. An agent module can't declare an ETS saver: its declarations
are evaluated on every call, so `checkpointer BeamWeaver.Checkpoint.ETS.new()`
would give each call a new, empty table, and the module doesn't compile.
Declare `BeamWeaver.Checkpoint.Ecto`, or a function that returns the saver
you created once.

Data that belongs to the call rather than to the conversation, such as the
signed-in customer's id, goes in `context:` instead. See
[Runtime Context](runtime_context.md).

## Read a thread back

`get_state/1` returns the latest saved snapshot of a thread. Its `values` are
the state the next call will start from:

```elixir
{:ok, snapshot} = MyApp.SupportAgent.get_state(opts)
length(snapshot.values.messages)
#=> 4
```

A thread with no saved checkpoint returns `:error`:

```elixir
unknown = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-99"}}]
MyApp.SupportAgent.get_state(unknown)
#=> :error
```

To forget a conversation, delete its checkpoints:

```elixir
BeamWeaver.Checkpoint.delete_thread(saver, "ticket-43")
#=> :ok
```

Every step of a thread is kept, not only the latest one. You can list that
history, resume from an earlier step, or fork a thread; see
[Checkpoints and Time Travel](checkpoints.md).

## Long threads

Every model call sends the whole thread. A long thread gets slower and more
expensive with each turn, and in the end it no longer fits in the model's
context window. There are three ways to keep it short:

| Option | The model sees | The saved thread keeps |
| --- | --- | --- |
| Trim before each model call | The newest messages | Every message |
| Delete old messages | The newest messages | The newest messages |
| Summarize old messages | A summary and the newest messages | A summary and the newest messages |

The system prompt is not part of the thread, so none of these removes it.

### Trim before each model call

A middleware that wraps the model call can send the model a shorter list
while the thread keeps everything:

```elixir
defmodule MyApp.TrimHistory do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Messages.Utils

  # Send the model only the newest messages that fit in 2,000 tokens.
  @impl true
  def wrap_model_call(_middleware, request, handler) do
    {:ok, recent} = Utils.trim(request.messages, max_tokens: 2_000, start_on: :user)

    request
    |> ModelRequest.override(messages: recent)
    |> handler.()
  end
end
```

Add it to an agent with `middleware [MyApp.TrimHistory]`.
`BeamWeaver.Core.Messages.Utils.trim/2` keeps the newest messages that fit in
`max_tokens`, counting about four characters per token. `start_on: :user` makes
the kept part start with a user message, and it never keeps a tool result
without the call that asked for it:

```elixir
alias BeamWeaver.Core.Message
alias BeamWeaver.Core.Messages.Utils

messages = [
  Message.user("Where is order A-1001?"),
  Message.assistant("Order A-1001 shipped on Monday."),
  Message.user("When will it arrive?"),
  Message.assistant("It arrives on Thursday."),
  Message.user("Thanks!")
]

{:ok, recent} = Utils.trim(messages, max_tokens: 30, start_on: :user)
Enum.map(recent, &Message.text/1)
#=> ["When will it arrive?", "It arrives on Thursday.", "Thanks!"]
```

### Delete old messages

To drop old messages from the thread itself, update `messages` from a
`before_model` hook with a `BeamWeaver.Graph.Messages.remove/1` marker for
each message to delete, by its id:

```elixir
defmodule MyApp.KeepRecentMessages do
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Graph.Messages

  # Before each model call, delete all but the newest messages from the thread.
  # The kept part starts at a user message, so no tool result loses its call.
  @impl true
  def before_model(_middleware, %{messages: messages}, _runtime) when length(messages) > 4 do
    recent = messages |> Enum.take(-4) |> Enum.drop_while(&(&1.role != :user))
    %{messages: Enum.map(messages -- recent, &Messages.remove(&1.id))}
  end

  def before_model(_middleware, _state, _runtime), do: nil
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat",
    responses: [
      "Order A-1001 shipped on Monday.",
      "It arrives on Thursday.",
      "Yes, you can change it until Wednesday.",
      "You're welcome, Ada!"
    ]

  system_prompt "You are Acme's support agent."
  middleware [MyApp.KeepRecentMessages]
end

opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-44"}}]

for question <- ["Where is order A-1001?", "When will it arrive?", "Can I change the address?"] do
  {:ok, _result} = MyApp.SupportAgent.invoke(%{messages: [question]}, opts)
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Thanks!"]}, opts)
Enum.map(result.messages, &BeamWeaver.Core.Message.text/1)
#=> ["Can I change the address?", "Yes, you can change it until Wednesday.",
#    "Thanks!", "You're welcome, Ada!"]
```

Deleted messages are gone from the next checkpoint on, so the agent can no
longer refer back to them. To replace the whole list at once instead, return
`%{messages: BeamWeaver.Graph.Overwrite.new(recent)}`;
`BeamWeaver.Graph.Messages.remove_all/0` followed by new messages does the
same.

### Summarize old messages

A summary keeps the gist of what was deleted. The summarization middleware
asks a model, usually a small and cheap one, to summarize the older messages
and keeps the newest ones as they are:

```elixir
defmodule MyApp.SummarizingAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  middleware [
    {BeamWeaver.Agent.Middleware.Summarization,
     model: "openai:gpt-5.4-mini", trigger: {:tokens, 50_000}, keep: {:messages, 20}}
  ]
end

{:ok, result} = MyApp.SummarizingAgent.invoke(%{messages: ["Reply with the word ready."]})
true = is_binary(result.messages |> List.last() |> BeamWeaver.Core.Message.text())
```

See [Context Management](context_management.md#summarize-old-messages) for
how it works and for the other ways to keep long runs inside the context
window.

## Keep extra keys in state

The state of a thread can hold more than messages. Pass another key with the
input and it is saved with the thread; a tool reads it by injecting
`{:state, key}`, which the model never sees:

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  injected :customer, {:state, :customer}

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id} = input, _opts) do
    {:ok, "Order #{order_id} for #{input.customer} shipped on Monday."}
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Order A-1001 shipped on Monday.",
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1002"}),
      "Order A-1002 shipped on Monday too."
    ]

  system_prompt "You are Acme's support agent."
  tools [MyApp.Tools.LookupOrder]
end

opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-45"}}]

{:ok, _first} = MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"], customer: "Ada"}, opts)
{:ok, second} = MyApp.SupportAgent.invoke(%{messages: ["And order A-1002?"]}, opts)

second.messages |> Enum.filter(&(&1.role == :tool)) |> List.last() |> BeamWeaver.Core.Message.text()
#=> "Order A-1002 for Ada shipped on Monday."
```

The second call didn't pass `customer`, but the thread still had it. Use atom
keys for extra state. A tool can also change state by returning a
`BeamWeaver.Graph.Command` (see [Tools](tools.md)), and middleware can declare
keys with their own merge rules (see [Middleware](middleware.md) and
[Graph State](graph_state.md)).

## Store threads in production

`Checkpoint.ETS` keeps threads in memory, so they are lost when the node
stops. In production, save them in Postgres or SQLite with
`Checkpoint.Ecto`:

Before running the database examples on this page, set `DATABASE_URL` to
an empty PostgreSQL database reserved for examples, then run this setup in
the same IEx session. The verification command creates a disposable database.

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
end

{:ok, _repo} = MyApp.Repo.start_link(url: System.fetch_env!("DATABASE_URL"), pool_size: 2, log: false)

defmodule MyApp.CreateAgentTables do
  use Ecto.Migration

  def up, do: BeamWeaver.Migrations.up(adapters: [:checkpoint, :memory, :cache])
  def down, do: BeamWeaver.Migrations.down(adapters: [:cache, :memory, :checkpoint])
end

:ok = Ecto.Migrator.up(MyApp.Repo, 1, MyApp.CreateAgentTables, log: false)
```

```elixir
saver = BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo)

MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]},
  checkpointer: saver,
  config: %{"configurable" => %{"thread_id" => "ticket-42"}}
)
```

The Ecto saver is a plain struct, so you can build it wherever you need it.
[Storage](storage.md) covers the migrations, and
[Checkpoints and Time Travel](checkpoints.md) covers thread history.

## Reference

- [`BeamWeaver.Checkpoint`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.html): reading and deleting saved threads
- [`BeamWeaver.Checkpoint.ETS`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.ETS.html): in-memory checkpointer for development and tests
- [`BeamWeaver.Checkpoint.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.Ecto.html): Postgres and SQLite checkpointer
- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): `invoke/3` and `get_state/2`
- [`BeamWeaver.Core.Messages.Utils`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.Messages.Utils.html): trimming and counting messages
- [`BeamWeaver.Graph.Messages`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Messages.html): removing messages from the thread by id
- [`BeamWeaver.Graph.Overwrite`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Overwrite.html): replacing a state key instead of merging into it
- [`BeamWeaver.Agent.Middleware.Summarization`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.Summarization.html): summarizing old messages
