# Deep Agents Quickstart

Build your first BeamWeaver deep agent in minutes. The agent below can plan a
research task, call a search tool, write notes into a virtual filesystem, and
delegate focused work to a subagent.

{% hint style="info" %}
**No Separate Constructor**

The Python docs use `create_deep_agent(...)`. BeamWeaver integrates those
capabilities into normal agents. Use `BeamWeaver.Agent.build/1` for a runtime
quickstart or `use BeamWeaver.Agent` for application modules.
{% endhint %}

## Prerequisites

You need:

- An Elixir project that depends on BeamWeaver.
- A model provider API key for a tool-calling chat model.
- Optional: a search provider API key if you keep the live search tool.

Deep agents need a model that supports tool calling. See [Models](models.md)
and the [Deep Agents model matrix](partners.md#deep-agents-model-matrix) for
provider strings, model configuration, and capability support notes.

## Step 1: Install Dependencies

Add BeamWeaver to your Mix project:

```elixir
def deps do
  [
    {:beam_weaver, "~> 0.1.0"},
    {:req, "~> 0.5"}
  ]
end
```

Then run:

```bash
mix deps.get
mix compile
```

Inside this repository, use:

```bash
mix deps.get
mix test
```

## Step 2: Set API Keys

Use the provider you plan to call by loading credentials in `config/runtime.exs`:

```elixir
import Config

config :beam_weaver,
  openai: [api_key: System.fetch_env!("OPENAI_API_KEY")],
  anthropic: [api_key: System.fetch_env!("ANTHROPIC_API_KEY")],
  xai: [api_key: System.fetch_env!("XAI_API_KEY")]
```

If you keep the Tavily example search tool, also set:

```bash
export TAVILY_API_KEY="your-tavily-api-key"
```

You can replace that search tool with DuckDuckGo, Brave Search, SerpAPI,
Postgres full-text search, an internal retriever, or any other normal
BeamWeaver tool.

## Step 3: Create A Search Tool

For stable application code, define tools as modules. This example uses Tavily's
HTTP API through `Req`; swap the handler body for your preferred search
provider.

```elixir
defmodule MyApp.Tools.InternetSearch do
  use BeamWeaver.Tool

  name "internet_search"
  description "Run an internet search."
  max_result_chars 12_000

  schema do
    field :query, :string, description: "Search query"
    field :max_results, :integer, required: false, default: 5
    field :topic, :string, required: false, default: "general"
    field :include_raw_content, :boolean, required: false, default: false
  end

  @impl true
  def invoke(_tool, input, _opts) do
    api_key = System.fetch_env!("TAVILY_API_KEY")

    response =
      Req.post!(
        "https://api.tavily.com/search",
        headers: [{"authorization", "Bearer #{api_key}"}],
        json: %{
          query: input.query,
          max_results: Map.get(input, :max_results, 5),
          topic: Map.get(input, :topic, "general"),
          include_raw_content: Map.get(input, :include_raw_content, false)
        },
        receive_timeout: 120_000
      )

    {:ok, response.body}
  end
end
```

The important BeamWeaver contract is the tool shape: a name, description,
schema, and `invoke/3` callback. See [Tools](tools.md) for runtime-created tools
and advanced schemas.

## Step 4: Compose A Long-Running Agent

This runtime-built agent enables the core long-running capabilities:

- `TodoList` middleware for planning.
- `Filesystem.State` for virtual files and offloaded notes.
- `subagents` for focused task delegation.
- `compact_conversation` and `overflow_recovery` for long-running context
  management.

These are ordinary BeamWeaver agent options and middleware entries. Omit any
capability you do not want; BeamWeaver does not switch into a separate
DeepAgent type or mode.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Agent.Middleware
alias BeamWeaver.Agent.Subagent
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Filesystem

research_instructions = """
You are an expert researcher. Conduct thorough research, keep useful notes in
files when they help, and write a polished final report.

Use internet_search as your primary way to gather external information.
Prefer concise, source-backed findings over unsupported claims.
"""

{:ok, agent} =
  Agent.build(
    name: "research_agent",
    model: "openai:gpt-5.4",
    model_opts: [
      temperature: 0.2,
      timeout: 120_000
    ],
    tools: [MyApp.Tools.InternetSearch],
    system_prompt: research_instructions,
    middleware: [
      {Middleware.TodoList, tool_name: "write_todos"}
    ],
    filesystem: Filesystem.State.new(),
    subagents: [
      Subagent.Spec.new(
        name: "researcher",
        description: "Research a narrow question and return concise sourced findings.",
        system_prompt: "Use available tools and return only relevant findings with sources."
      )
    ],
    compact_conversation: true,
    overflow_recovery: true,
    checkpointer: CheckpointETS.new()
  )
```

You can pass `"anthropic:claude-sonnet-4-6"` or another supported provider
string instead. For stable application code, move the same fields into a
`use BeamWeaver.Agent` module.

## Step 5: Run The Agent

Invoke the agent with a stable `thread_id` when you want checkpointed state and
virtual filesystem contents to persist across turns.

```elixir
alias BeamWeaver.Core.Message

config = %{"configurable" => %{"thread_id" => "research-thread-1"}}

{:ok, state} =
  Agent.invoke(
    agent,
    %{
      messages: [
        Message.user("What is LangGraph? Write a short source-backed report.")
      ]
    },
    config: config
  )

state.messages
|> List.last()
|> Message.text()
```

## Stream Progress

Use `stream_events/3` when you want to observe planning, tool calls, subagent
work, model streaming, and graph execution as typed envelopes:

```elixir
{:ok, events} =
  Agent.stream_events(
    agent,
    %{messages: [Message.user("Research recent LangGraph capabilities.")]},
    config: config
  )

Enum.each(events, fn envelope ->
  IO.inspect({envelope.event, envelope.name})
end)
```

See [Event Streaming](event_streaming.md) for event types, filtering, and UI
projection patterns.

## How It Works

The agent automatically:

1. Plans its approach with the `write_todos` tool from `TodoList` middleware.
2. Calls `internet_search` to gather information.
3. Uses filesystem tools such as `write_file` and `read_file` when virtual files
   help manage context.
4. Uses the `task` tool to spawn the configured `researcher` subagent when a
   focused subtask should be isolated.
5. Synthesizes the final answer from messages, tool results, subagent results,
   and any notes it wrote to the virtual filesystem.

The `researcher` starts with a fresh message context containing the task
description. Because its `tools` field is omitted, it can use the parent
`internet_search` tool. It does not automatically receive TODO or filesystem
middleware; add those middleware entries to the child only when it needs its own
planning or file workspace.

## Observability

BeamWeaver exposes telemetry and tracing boundaries under `BeamWeaver.Tracing`.
Use [Tracing](tracing.md) to emit local traces or export runs to WeaveScope.
Model, tool, graph, and subagent boundaries are represented as BeamWeaver run
events rather than Python LangGraph SDK objects.

## Next Steps

- [Customization](customization.md)
- [Composed Agent Capabilities](agent_harness.md)
- [Filesystem](filesystem.md)
- [Subagents](subagents.md)
- [Skills](skills.md)
- [Memory](memory.md)
- [Event Streaming](event_streaming.md)
- [Tracing](tracing.md)
