# Conversation History

A checkpointer saves the messages and state of one conversation. Reuse a
thread ID to continue that conversation; use a new ID to start another.
This is short-term memory. Preferences shared across conversations belong
in [Long-Term Memory](long_term_memory.md).

Complete [Installation](installation.md), then run these blocks in one IEx
session with OpenAI configured.

## Continue a thread

```elixir
defmodule MyApp.ConversationAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000
  system_prompt "Use facts the user supplied. Never invent order data."
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:ok, first} = MyApp.ConversationAgent.invoke(%{messages: ["My order ID is A-1001. Please remember it."]}, opts)
{:ok, second} = MyApp.ConversationAgent.invoke(%{messages: ["What is my order ID?"]}, opts)
true = length(second.messages) > length(first.messages)
answer = second.messages |> List.last() |> BeamWeaver.Core.Message.text()
true = answer =~ "A-1001"
```

Send only the new turn. Re-sending the full history can duplicate messages.
The second call loads saved state before invoking the model.

## Threads and ownership

The thread ID identifies stored state, not an authenticated user. Enforce
which caller can read, continue, fork or delete a thread in your application.
Serialize conflicting operations on the same thread when the workflow needs
one ordered conversation.

```elixir
other = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-43"}}]
{:ok, fresh} = MyApp.ConversationAgent.invoke(%{messages: ["Hello."]}, other)
2 = length(fresh.messages)
```

The saver above owns ETS tables in the process that creates it. They disappear
when that owner exits, not only when the whole node stops. Create a reusable
owner under supervision for in-memory applications. Use database storage when
history must survive a restart.

Agent declarations are evaluated per invocation. Do not construct a new ETS
saver inside `checkpointer`; pass the existing saver per call instead.
Trusted caller data belongs in [Runtime Context](runtime_context.md) and must
be supplied again on every call and resume.

## Read a thread back

```elixir
{:ok, snapshot} = MyApp.ConversationAgent.get_state(opts)
true = length(snapshot.values.messages) == length(second.messages)
:ok = BeamWeaver.Checkpoint.delete_thread(saver, "ticket-43")
:error = MyApp.ConversationAgent.get_state(other)
```

A snapshot holds `values` plus execution/checkpoint metadata. Reading it does
not make a model call. Checkpoints retain step history; deleting the thread
removes its checkpoint history. [Checkpoints](checkpoints.md) explains listing,
forking and editing snapshots.

## Keep extra keys in state

Application state can contain more than messages: ticket priority, collected
facts or progress. Input keys and tool `Graph.Command` updates can add these
values. Middleware can declare their channels and reducers.

Keep current identity and permissions in context, even if a thread remembers
a customer display name. Persisted conversational data is not a fresh
authorization decision. Use atom keys for agent state and string keys for
model-supplied tool arguments.

## Long threads

Without a context policy, successive calls send growing history. Choose the
policy based on what you need to retain:

| Policy | Model input | Future saved state |
| --- | --- | --- |
| Trim the request | Recent valid messages | Full history remains |
| Remove messages from state | Retained messages | Removed messages disappear from later checkpoints |
| Summarize | Summary plus recent messages | Summary plus retained messages |

The agent's system prompt is supplied separately. Preserve tool-call/result
pairs when changing history; dropping just one can invalidate the request.

### Trim before each model call

A `wrap_model_call/3` hook can call `BeamWeaver.Core.Messages.Utils.trim/2`
and use `ModelRequest.override(messages: recent)`. This changes only the
request. The default counter estimates tokens; pass a suitable tokenizer
when you need a precise budget and reserve room for tools and output.

Trim only the request window with a model wrapper:

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

Attach the wrapper to a real model. Saved history still includes both turns:

```elixir
{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 128, timeout: 60_000],
    middleware: [MyApp.TrimHistory]
  )

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "trim-example"}}]
{:ok, _} = BeamWeaver.Agent.invoke(agent, %{messages: ["Remember that A-1001 arrives Thursday."]}, opts)
{:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Which day does A-1001 arrive?"]}, opts)
4 = length(result.messages)
true = BeamWeaver.Core.Message.text(List.last(result.messages)) =~ "Thursday"
```

### Delete old messages

Return `BeamWeaver.Graph.Messages.remove(message_id)` markers from a state
hook. Use `Graph.Overwrite.new(messages)` to replace the list or
`Graph.Messages.remove_all/0` followed by new messages to reset it. A normal
`messages` update appends/merges rather than replacing the whole conversation.
Earlier checkpoints still contain their earlier state until explicitly deleted.

For persistent trimming, return message-removal updates. This simple policy applies to the tool-free conversation below:

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

  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000

  system_prompt "You are Acme's support agent."
  middleware [MyApp.KeepRecentMessages]
end

opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-44"}}]

for question <- ["Where is order A-1001?", "When will it arrive?", "Can I change the address?"] do
  {:ok, _result} = MyApp.SupportAgent.invoke(%{messages: [question]}, opts)
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Thanks!"]}, opts)
4 = length(result.messages)
"Thanks!" = result.messages |> Enum.at(-2) |> BeamWeaver.Core.Message.text()
```

### Summarize old messages

Use summarization middleware for a summary plus a retained recent window.
Summarization itself makes model calls and can lose details. Keep authoritative
records in tools or storage; a summary is conversational context, not your
source of truth. [Context Management](context_management.md) demonstrates
actual summarization and its observable result.

## Store threads in production

Use `BeamWeaver.Checkpoint.Ecto` with a supervised PostgreSQL or SQLite
repository. [Storage](storage.md) provides complete setup and migrations.
An adapter struct does not own connections; the repository does.

Persisting checkpoints enables recovery, but does not make external tool
side effects exactly-once. [Durable Execution](durable_execution.md) explains
idempotency and continuation after a crash.
