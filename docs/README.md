# Overview

BeamWeaver is an OTP-native Elixir system for building LLM applications,
agents, and graph-orchestrated workflows. It combines the two layers that the
Python ecosystem documents separately:

- LangChain-style model, message, tool, middleware, retrieval, and agent
  abstractions.
- LangGraph-style durable graph execution, checkpoints, interrupts, streaming,
  state, and memory.

The Python projects are behavioral references. BeamWeaver's public API is
Elixir: modules, structs, behaviours, protocols, supervised tasks, `Enumerable`
streams, telemetry, explicit adapters, and tagged errors.

BeamWeaver is not affiliated with LangChain.

{% hint style="info" %}
**Unified System**

LangChain agents are built on top of LangGraph in Python. BeamWeaver exposes
that relationship as one native system: `use BeamWeaver.Agent` and
`BeamWeaver.Agent.build/1` compile to graph-backed runtimes, while
`BeamWeaver.Graph` remains available for deterministic or custom orchestration.
Use an agent when you want the standard model/tool loop. Use a graph when you
need explicit control over state transitions, branches, fan-out, retries,
interrupts, or long-running workflows.
{% endhint %}

## Install

Add BeamWeaver to your Mix project:

```elixir
def deps do
  [
    {:beam_weaver, "~> 0.1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
mix compile
```

Inside this repository:

```bash
mix deps.get
mix test
```

## Create An Agent

Use `use BeamWeaver.Agent` for stable application modules and
`BeamWeaver.Agent.build/1` for runtime-configured agents. Both compile to the
same graph-backed runtime. Stable modules should use the semantic DSL so tools,
middleware, subagents, graphs, prompts, and schemas stay visibly separate.

The runnable weather-agent walkthrough is in
[Quickstart](getting_started.md#build-a-basic-agent). The full module DSL is in
[Semantic DSL](semantic_dsl.md).

Agent features include model and tool calling, middleware, structured output,
short-term memory through checkpoints, long-term memory through stores,
Deep Agents-style composed capabilities, human-in-the-loop interrupts, typed
streaming, retries, fallbacks, and runtime context injection.

{% hint style="warning" %}
**Provider Scope**

LangChain's overview shows many provider tabs because Python integrations are
distributed across many packages. BeamWeaver currently documents first-class
agent model paths for OpenAI, Anthropic, Google Gemini, xAI, and fake/replay
models. Azure OpenAI, Vertex AI, Bedrock, OpenRouter, Fireworks, Baseten,
Ollama, HuggingFace, and other provider-specific adapters need native
transport, message translation, streaming, profile, replay, and documentation
coverage before being presented as supported BeamWeaver workflows.
{% endhint %}

## Build A Graph

Use `graph do` inside an agent module when the workflow is not just a
model/tool loop, or when you want explicit orchestration:

```elixir
defmodule MyApp.HelloWorld do
  use BeamWeaver.Agent

  graph do
    state do
      channel :messages, merge: fn existing, update -> existing ++ List.wrap(update) end
    end

    node :mock_llm, fn _state ->
      %{messages: [BeamWeaver.Core.Message.assistant("hello world")]}
    end

    edge start(), :mock_llm
    edge :mock_llm, finish()
  end
end

{:ok, state} =
  MyApp.HelloWorld.invoke(%{
    messages: [BeamWeaver.Core.Message.user("hi")]
  })
```

Use `BeamWeaver.Graph` builder functions directly when graph shape is dynamic or
generated from configuration. Graphs support reducer-based state, conditional
routing, dynamic fan-out, joins, commands, checkpoints, interrupts, state
history, and `stream_events/3`. Agents use the same graph runtime underneath.

## Core Benefits

| Capability | BeamWeaver surface |
| --- | --- |
| Standard model interface | `BeamWeaver.Core.ChatModel` plus provider adapters for OpenAI, Anthropic, Google, xAI, fake, and replay-backed tests. |
| Agent architecture | `use BeamWeaver.Agent` and `BeamWeaver.Agent.build/1` for graph-backed model/tool loops. |
| Low-level orchestration | `BeamWeaver.Graph` for deterministic, agentic, or hybrid workflows. |
| Durable execution | [Checkpoint-backed resumable graph execution](durable_execution.md). |
| Fault tolerance | [Node retries, timeouts, error handlers, and failure policies](fault_tolerance.md). |
| Human oversight | Graph interrupts and agent human-in-the-loop middleware. |
| Memory | Short-term memory through checkpoints; long-term memory through `BeamWeaver.Memory` stores. |
| Composed agent capabilities | Planning, virtual filesystems, permissions, subagents, context compaction, code execution, HITL, skills, and memory files through normal composable agent options and middleware. |
| Deep Agents quickstart | Build a composed research agent with planning, filesystem tools, and a subagent. |
| Customization | Crosswalk from Deep Agents `create_deep_agent(...)` options to BeamWeaver module macros and `Agent.build/1` options. |
| Streaming | Typed `%BeamWeaver.Stream.Envelope{}` values exposed as Elixir `Enumerable` streams. |
| Observability | Telemetry and tracing/export boundaries under `BeamWeaver.Tracing`. |
| Retrieval | Document loaders, splitters, embeddings, vector stores, retrievers, and indexing primitives. |

## Concept Mapping

| Python concept | BeamWeaver concept |
| --- | --- |
| `create_agent` | `use BeamWeaver.Agent` or `BeamWeaver.Agent.build/1` |
| `StateGraph` | `BeamWeaver.Graph` |
| `MessagesState` | State maps with reducers, usually `:messages` |
| `HumanMessage`, `AIMessage`, `ToolMessage` | `BeamWeaver.Core.Message` |
| Python `@tool` | `%BeamWeaver.Core.Tool{}`, `Tool.from_function!/1`, or `use BeamWeaver.Tool` |
| Middleware hooks | `BeamWeaver.Agent.Middleware` callbacks and middleware modules |
| `create_deep_agent(...)` customization | Compose the same capabilities with `use BeamWeaver.Agent` macros or `BeamWeaver.Agent.build/1` options |
| LangGraph checkpointer | `BeamWeaver.Checkpoint.Saver` adapters |
| LangGraph store | `BeamWeaver.Memory.Store` adapters |
| Stream modes | Typed event envelopes from `stream_events/3` |
| observability | BeamWeaver telemetry and native WeaveScope tracing/export boundaries |

{% hint style="warning" %}
**Hosted Product Scope**

LangChain's overview links to Deep Agents, hosted engines, deployment products,
Studio, SDKs, and remote LangGraph Platform APIs. BeamWeaver does not implement
those hosted products or their Python SDK/CLI contracts. It provides native
Elixir building blocks for agents, graphs,
middleware, memory, streaming, tracing boundaries, and adapters. Product-level
deployment, evaluation, patch generation, no-code builders, and remote platform
APIs should be integrated explicitly by the application.
{% endhint %}

## Start Here

- [Getting Started](getting_started.md)
- [Semantic DSL](semantic_dsl.md)
- [DSL Migration Guide](dsl_migration.md)
- [Thinking In BeamWeaver](thinking_in_beamweaver.md)
- [Workflows And Agents](workflows_and_agents.md)
- [Persistence](persistence.md)
- [Memory](memory.md)
- [Composed Agent Capabilities](agent_harness.md)
- [Deep Agents Quickstart](deep_agents_quickstart.md)
- [Customization](customization.md)
- [Profiles](profiles.md)
- [Filesystem](filesystem.md)
- [Filesystem Permissions](permissions.md)
- [Skills](skills.md)
- [Sandboxes](sandboxes.md)
- [Subagents](subagents.md)
- [Async Subagents](async_subagents.md)
- [Subgraphs](subgraphs.md)
- [Time Travel](time_travel.md)
- [Durable Execution](durable_execution.md)
- [Fault Tolerance](fault_tolerance.md)
- [Agents](agents.md)
- [Graph](graph.md)
- [Models](models.md)
- [Tools](tools.md)
- [Messages](messages.md)
- [Runtime](runtime.md)
- [Context Engineering](context_engineering.md)
- [Middleware](middleware.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Custom Middleware](custom_middleware.md)
- [Guardrails](guardrails.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Short-Term Memory](short_term_memory.md)
- [Long-Term Memory](long_term_memory.md)
- [Event Streaming](event_streaming.md)
- [Structured Output](structured_output.md)
- [Retrieval](retrieval.md)
- [Prompts And Parsers](prompts_parsers.md)
- [Adapters](adapters.md)
- [Core](core.md)
- [Partner Matrix](partners.md)
- [OpenAI](partners/openai.md)
- [Anthropic](partners/anthropic.md)
- [Google](partners/google.md)
- [Moonshot/Kimi](partners/moonshot.md)
- [xAI](partners/xai.md)
- [Replay](replay.md)
- [Going To Production](going_to_production.md)
- [Rate Limiting](rate_limiting.md)
- [Tracing](tracing.md)
- [Standard Tests](standard_tests.md)

## API Reference

GitBook hosts the workflow documentation in this `docs/` directory. Public
module and function reference belongs in Elixir code docs. Generate it locally
with:

```bash
mix docs
```

HexDocs is published from the same module docs and `@doc` annotations. Keep
conceptual tutorials in GitBook and code-level contracts in the modules that
implement them.
