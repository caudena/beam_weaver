# Short-Term Memory

Short-term memory is conversation state scoped to one thread. In BeamWeaver,
that state lives in the graph state for an agent or graph and is persisted
through an explicit checkpoint adapter.

The common short-term memory field is `:messages`, backed by
`BeamWeaver.Graph.Messages.channel/1`. It stores system, user, assistant, and
tool messages and knows how to append, replace, delete, and clear messages by
ID.

{% hint style="info" %}
**Thread State**

LangChain describes a thread as a conversation session. BeamWeaver uses the
same concept at the checkpoint boundary: pass a stable
`config: %{"configurable" => %{"thread_id" => "..."}}` to keep one
conversation isolated from another. `context:` is separate and remains per-run
data for tools and middleware.
{% endhint %}

## Enable Memory

Agents already include message state. To persist it across turns, pass a
checkpointer and reuse the same `thread_id`:

```elixir
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "thread-1"}}

{:ok, _state} =
  MyApp.Agent.invoke(
    %{messages: [Message.user("Hi! My name is Bob.")]},
    checkpointer: checkpointer,
    config: config
  )

{:ok, state} =
  MyApp.Agent.invoke(
    %{messages: [Message.user("What is my name?")]},
    checkpointer: checkpointer,
    config: config
  )

state.messages |> List.last() |> Message.text()
```

Use `BeamWeaver.Checkpoint.ETS` for tests, examples, and local workflows.

## Production Persistence

Use the Ecto/Postgres checkpointer for durable deployments:

```elixir
checkpointer = BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo)

MyApp.Agent.invoke(
  %{messages: [BeamWeaver.Core.Message.user("remember this")]},
  checkpointer: checkpointer,
  config: %{"configurable" => %{"thread_id" => "thread-123"}}
)
```

Create tables in your application migration with the versioned migration API:

```elixir
defmodule MyApp.Repo.Migrations.CreateBeamWeaverCheckpoints do
  use Ecto.Migration

  def up do
    BeamWeaver.Migrations.up(adapters: [:checkpoint])
  end

  def down do
    BeamWeaver.Migrations.down(adapters: [:checkpoint], version: 1)
  end
end
```

{% hint style="warning" %}
**Database Setup**

LangChain's Postgres saver examples call `checkpointer.setup()` from Python.
BeamWeaver does not create tables from the runtime path. Schema changes belong
in normal Ecto migrations so production releases, rollbacks, and database
permissions stay explicit. SQLite, Azure Cosmos DB, Redis, and distributed
checkpoint execution are not part of the current BeamWeaver persistence surface;
use ETS for local/test memory and Ecto/Postgres for durable memory.
{% endhint %}

## Custom Agent Memory

Default agent state contains `:messages`, `:remaining_steps`, private routing
channels, and usage metadata. Add custom short-term state through middleware
that owns the behavior:

```elixir
defmodule MyApp.PreferenceMemory do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.LastValue

  def name(_middleware), do: :preference_memory

  def state_schema(_middleware) do
    %{preferences: Graph.channel(LastValue)}
  end
end

defmodule MyApp.Agent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  middleware do
    use MyApp.PreferenceMemory
  end
end

MyApp.Agent.invoke(%{
  messages: [BeamWeaver.Core.Message.user("Hello")],
  preferences: %{theme: "dark"}
})
```

{% hint style="info" %}
**State Ownership**

LangChain documents both middleware-owned state and a direct `state_schema`
argument on `create_agent`. BeamWeaver keeps the agent API single-path:
middleware declares the state it reads or writes. This keeps schema, hooks, and
tools colocated. Direct state schemas remain available when you build a
low-level `BeamWeaver.Graph` yourself.
{% endhint %}

Elixir structs and typespecs are not Python `TypedDict` or Pydantic models.
Use `BeamWeaver.Agent.Schema.field/3`, graph channels, and explicit JSON Schema
maps where runtime validation or provider schemas are needed.

## Trim Messages

Use `BeamWeaver.Core.Messages.Utils.trim/2` when the model should see only the
recent part of a conversation. In an agent, run trimming in `before_model`
middleware and overwrite the message channel:

```elixir
defmodule MyApp.TrimMessages do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Messages.Utils
  alias BeamWeaver.Graph.Overwrite

  def name(_middleware), do: :trim_messages

  def before_model(state, _runtime) do
    messages = Map.get(state, :messages, Map.get(state, "messages", []))

    if length(messages) <= 3 do
      nil
    else
      with {:ok, trimmed} <-
             Utils.trim(messages,
               max_tokens: 2_000,
               strategy: :last,
               include_system: true
             ) do
        %{messages: Overwrite.new(trimmed)}
      end
    end
  end
end
```

`Utils.trim/2` preserves tool-call adjacency: assistant messages keep only tool
calls with matching retained tool results, and orphan tool messages are dropped.

{% hint style="info" %}
**Middleware Instead Of Decorators**

LangChain uses decorators such as `@before_model` and `@after_model`.
BeamWeaver uses middleware modules, structs, and callbacks. The lifecycle point
is the same, but the implementation is normal Elixir data that can be tested,
supervised, and reused.
{% endhint %}

## Delete Messages

Use `BeamWeaver.Graph.Messages.remove/1` for specific messages and
`remove_all/0` to clear the message history:

```elixir
defmodule MyApp.DeleteOldMessages do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Graph.Messages

  def name(_middleware), do: :delete_old_messages

  def after_model(state, _runtime) do
    messages = Map.get(state, :messages, Map.get(state, "messages", []))

    if length(messages) > 6 do
      old_messages =
        messages
        |> Enum.take(length(messages) - 6)
        |> Enum.filter(&is_binary(&1.id))
        |> Enum.map(&Messages.remove(&1.id))

      %{messages: old_messages}
    end
  end
end
```

To clear everything:

```elixir
%{messages: [BeamWeaver.Graph.Messages.remove_all()]}
```

{% hint style="warning" %}
**Provider-Valid Histories**

Deleting messages can create invalid provider input. Keep assistant tool calls
paired with matching tool-result messages, and check provider requirements
around first message role, system message placement, and multimodal blocks.
BeamWeaver reducers can delete safely by ID, but provider request builders
still validate the final history before sending it.
{% endhint %}

## Summarize Messages

Use `BeamWeaver.Agent.Middleware.Summarization` to summarize older turns and
keep recent messages:

```elixir
defmodule MyApp.SummarizingAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  middleware do
    use BeamWeaver.Agent.Middleware.Summarization,
     model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini"),
     trigger: {:tokens, 4_000},
     keep: {:messages, 20}
  end
end
```

The summarizer can trigger on message count, token count, or a fraction of the
model profile context window. It rewrites the message channel with one system
summary followed by retained recent turns.

{% hint style="info" %}
**Summarization Policy**

LangChain's `SummarizationMiddleware` and BeamWeaver's summarization middleware
solve the same problem. BeamWeaver requires an explicit summary model value and
returns normal graph state updates. This keeps provider selection, retry policy,
and test fakes visible in the agent declaration.
{% endhint %}

## Custom Strategies

Custom memory strategies are ordinary middleware. Use them when trimming,
deleting, or summarization is not enough:

```elixir
defmodule MyApp.FilterToolNoise do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Graph.Overwrite

  def name(_middleware), do: :filter_tool_noise

  def before_model(state, _runtime) do
    messages = Map.get(state, :messages, Map.get(state, "messages", []))
    filtered = Enum.reject(messages, &noisy_tool_result?/1)

    if filtered == messages, do: nil, else: %{messages: Overwrite.new(filtered)}
  end

  defp noisy_tool_result?(%BeamWeaver.Core.Message{role: :tool, metadata: metadata}) do
    metadata[:ephemeral?] == true or metadata["ephemeral?"] == true
  end

  defp noisy_tool_result?(_message), do: false
end
```

Keep custom memory policies close to the application behavior they protect:
privacy filters, domain-specific retention, and tool-output pruning usually
belong in separate middleware modules.

## Read Memory In Tools

Tools read short-term memory by declaring injected state:

```elixir
alias BeamWeaver.Core.Tool

get_last_user_message =
  Tool.from_function!(
    name: "get_last_user_message",
    description: "Get the most recent user message.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"state" => %{"type" => "object"}},
      "required" => ["state"]
    },
    injected: [state: :state],
    handler: fn input, _opts ->
      state = input[:state] || input["state"] || %{}

      state
      |> then(&Map.get(&1, :messages, Map.get(&1, "messages", [])))
      |> Enum.reverse()
      |> Enum.find(&match?(%BeamWeaver.Core.Message{role: :user}, &1))
      |> case do
        nil -> "No user messages found."
        message -> BeamWeaver.Core.Message.text(message)
      end
    end
  )
```

Injected fields are removed from the model-visible schema, so the model only
sees arguments it is allowed to provide.

## Write Memory From Tools

Return `BeamWeaver.Graph.Command` when a tool needs to update short-term state:

```elixir
alias BeamWeaver.Core.{Message, Tool}
alias BeamWeaver.Graph.Command

set_user_name =
  Tool.from_function!(
    name: "set_user_name",
    description: "Set the user's name in conversation state.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "new_name" => %{"type" => "string"},
        "tool_call_id" => %{"type" => "string"}
      },
      "required" => ["new_name", "tool_call_id"]
    },
    injected: [tool_call_id: :tool_call_id],
    handler: fn input, _opts ->
      name = input["new_name"] || input[:new_name]
      call_id = input["tool_call_id"] || input[:tool_call_id]

      %Command{
        update: %{
          user_name: name,
          messages: [Message.tool("User name set to #{name}.", tool_call_id: call_id)]
        }
      }
    end
  )
```

Define reducers or channels for state fields that multiple tools may update in
parallel. For example, `BeamWeaver.Agent.Middleware.TodoList` owns its TODO
state and installs the tool that mutates it.

## Dynamic Prompts From Memory

Use `BeamWeaver.Agent.Middleware.DynamicPrompt` when the system prompt depends
on state or per-run context:

```elixir
defmodule MyApp.ContextPromptAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  context_schema do
    field :user_name, :string, required: true
  end

  middleware do
    use BeamWeaver.Agent.Middleware.DynamicPrompt,
     prompt: fn request ->
       user_name = request.runtime.context.user_name
       "You are a helpful assistant. Address the user as #{user_name}."
     end
  end
end
```

This replaces Python callable prompt decorators with a middleware entry that is
visible in the agent spec.

## Inspect And Modify Checkpointed State

Compiled graphs and agents expose state inspection through the checkpointer:

```elixir
config = %{"configurable" => %{"thread_id" => "thread-1"}}

{:ok, state} =
  MyApp.Agent.get_state(
    checkpointer: checkpointer,
    config: config
  )

{:ok, _config} =
  BeamWeaver.Graph.Compiled.update_state(
    compiled_graph,
    config,
    %{messages: [BeamWeaver.Graph.Messages.remove_all()]}
  )
```

Use these APIs for administrative repair, tests, or explicit memory management.
Normal conversation turns should update memory through agent invocation,
middleware, tools, or graph nodes.

## Related Guides

- [Agents](agents.md)
- [Messages](messages.md)
- [Tools](tools.md)
- [Middleware](middleware.md)
- [Custom Middleware](custom_middleware.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Guardrails](guardrails.md)
- [Context Engineering](context_engineering.md)
- [Persistence](persistence.md)
- [Durable Execution](durable_execution.md)
- [Fault Tolerance](fault_tolerance.md)
- [Long-Term Memory](long_term_memory.md)
- [Graph](graph.md)
- [Adapters](adapters.md)
- [Event Streaming](event_streaming.md)
