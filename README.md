# BeamWeaver

[![ci](https://github.com/caudena/beam_weaver/actions/workflows/ci.yml/badge.svg)](https://github.com/caudena/beam_weaver/actions/workflows/ci.yml)

BeamWeaver is an Elixir library for building applications on large language
models (LLMs) such as GPT, Claude and Gemini. You write tools as Elixir
modules, and an agent lets the model call them in a loop until it can answer.
Graphs run workflows with steps you define; they survive restarts and can
pause for a person's approval. Deep agents plan, keep files and hand work to
subagents. It all runs inside your own application, with streaming and
tracing built in.

**New here?** The [Quickstart](docs/quickstart.md) builds a working agent in
about ten minutes; you need an API key only for the last step.

**Documentation:** [docs.weavescope.com/beamweaver](https://docs.weavescope.com/beamweaver) ·
[API reference](https://hexdocs.pm/beam_weaver)

## Install

```elixir
def deps do
  [
    {:beam_weaver, "~> 1.0.0"}
  ]
end
```

## An agent with a tool

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts) do
    {:ok, "Order #{order_id} shipped on Monday."}
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini"
  system_prompt "You are Acme's support agent. Look orders up before you answer."
  tools [MyApp.Tools.LookupOrder]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
result.messages |> List.last() |> BeamWeaver.Core.Message.text()
# e.g. "Your order A-1001 shipped on Monday."
```

The tool's `name`, `description` and `schema` tell the model what it does.
The model decides when to call `lookup_order`; BeamWeaver runs the tool and
hands the result back until the model has an answer. This example calls
OpenAI, so it needs an [API key](docs/models.md#api-keys). The
[Quickstart](docs/quickstart.md) builds the same agent step by step and runs
it without one.

## What you get

| Feature | What it gives you |
| --- | --- |
| [Agents](docs/agents.md) | Agent modules with a model, tools, instructions and middleware. |
| [Tools](docs/tools.md) | Typed tool modules, with access to state, runtime context and the memory store. |
| [Structured output](docs/structured_output.md) | Answers validated against a schema. |
| [Middleware](docs/builtin_middleware.md) | Retries, model fallback, call limits, PII redaction, summarization, tool selection. |
| [Memory](docs/long_term_memory.md) | Conversation threads, long-term memory stores, and memory files. |
| [Human-in-the-loop](docs/human_in_the_loop.md) | Pause before sensitive tool calls; approve, edit or reject, then resume. |
| [Streaming](docs/streaming.md) | Typed events for tokens, tool calls and state updates. |
| [Graphs](docs/graphs.md) | Workflows with branches, parallel steps, subgraphs and interrupts. |
| [Durable execution](docs/durable_execution.md) | Checkpoints in Postgres or SQLite, resume after failures, time travel. |
| [Deep agents](docs/deep_agents.md) | Planning, a virtual filesystem, skills, subagents and sandboxed code execution. |
| [Retrieval](docs/retrieval.md) | Text splitters, embeddings, vector stores, retrievers and incremental indexing. |
| [Testing](docs/testing.md) | Scripted fake models and recorded provider responses for fast, offline tests. |
| [Tracing](docs/tracing.md) | Run trees with token usage and costs, exported to WeaveScope. |

## Providers

OpenAI, Anthropic, Google Gemini, xAI, DeepSeek, Moonshot (Kimi) and Z.ai chat
models, OpenAI and xAI embeddings, and TypeSafe decision models. Switching
provider means changing the model string, and scripted fake models stand in
for all of them in tests. See [Providers](docs/providers.md).

## Tracing with WeaveScope

Every run is traced: agents, graph steps, model calls, tool calls and
subagents, with tokens, costs and errors. Traces stay local until you add
[WeaveScope](https://weavescope.com) credentials:

```elixir
# config/runtime.exs
config :beam_weaver,
  weave_scope: [
    endpoint: "https://app.weavescope.com",
    api_key: System.fetch_env!("WEAVESCOPE_API_KEY")
  ]
```

![WeaveScope tracing view](https://raw.githubusercontent.com/caudena/beam_weaver/master/docs/assets/weavescope-tracing.png)

## Learn more

- [Quickstart](docs/quickstart.md): a working agent in ten minutes, no API key needed.
- [Concepts](docs/concepts.md): agents, graphs, deep agents, threads and memory on one page.
- [Examples](docs/examples.md): runnable scripts for every feature.
- [Coming from LangChain](docs/coming_from_langchain.md): where familiar concepts live in BeamWeaver.
- [Changelog](CHANGELOG.md)

## License

Apache-2.0. See [LICENSE](https://github.com/caudena/beam_weaver/blob/master/LICENSE).
