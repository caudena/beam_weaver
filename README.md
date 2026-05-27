# BeamWeaver

BeamWeaver is a from-scratch, OTP-native Elixir library for building LLM
applications, agents, and durable graph workflows. It brings the core
capabilities of LangChain, LangGraph, and Deep Agents into the BEAM ecosystem
without wrapping Python or embedding a foreign runtime.

The Python projects are the behavioral reference. The implementation and public
API are Elixir: modules, structs, behaviours, protocols, supervisors,
supervised tasks, `Enumerable` streams, telemetry, and tagged `{:ok, value}` /
`{:error, error}` results.

BeamWeaver is not affiliated with LangChain.

## What It Provides

BeamWeaver covers the library/runtime functionality you would normally assemble
from LangChain, LangGraph, and Deep Agents:

- Chat models, messages, content blocks, tool calls, output parsers, structured
  output, model profiles, and provider request/response translation.
- Provider integrations for OpenAI, Anthropic, Google Gemini, xAI, fake models, and
  replay-backed deterministic tests.
- Agents with tools, middleware, retries, fallbacks, guardrails, runtime
  context, short-term memory, long-term memory, and human-in-the-loop
  interrupts.
- LangGraph-style state graphs with reducers, commands, conditional routing,
  subgraphs, interrupts, checkpoints, state history, time travel, pending
  writes, durable execution, and fault-tolerance policies.
- Deep Agents-style harness features: planning/TODO tools, virtual filesystems,
  filesystem permissions, skills, memory files, profiles, subagents, async
  subagents, sandbox/executable filesystems, context engineering, and
  summarization.
- Retrieval and indexing primitives, document loaders, embeddings, vector
  stores, caches, rate limiting, serialization, event streaming, tracing, and a
  LangSmith-compatible export boundary.
- Conformance tests for core behavior, with BeamWeaver-native APIs where Python
  object identity or duplicate sync/async method families do not make sense in
  Elixir.

## Elixir-Native Approach

BeamWeaver does not copy Python APIs one-to-one. It translates the semantics
into primitives that fit OTP applications:

- **Supervision instead of hidden background threads.** Long-running queues,
  tracing exporters, sandboxes, and async work are normal supervised processes.
- **Behaviours and adapters instead of inheritance trees.** Models,
  checkpointers, stores, caches, vector stores, filesystems, sandboxes, and
  transports are explicit extension points.
- **Tagged results instead of exception-first control flow.** Recoverable
  failures return structured `%BeamWeaver.Core.Error{}` values.
- **Streams as `Enumerable`.** Model events, graph events, and agent execution
  can be consumed with ordinary Elixir stream tools.
- **Telemetry as the callback layer.** Runtime events are emitted through
  `:telemetry`, then consumed by local logging, metrics, or exporters.
- **Data-first interop.** BeamWeaver preserves LangChain/LangGraph-compatible
  message, config, checkpoint, and tracing shapes where useful, but exposes
  them through Elixir structs and maps.

## Status

BeamWeaver is pre-release and not published to Hex yet. The current provider
scope is OpenAI, Anthropic, Google Gemini, xAI, fake models, and replay models.

## Install

Until Hex publishing, use a local path dependency:

```elixir
def deps do
  [{:beam_weaver, path: "../beam_weaver"}]
end
```

After the repository is public, applications can also depend on the GitHub repo
directly from `mix.exs`.

Inside this repository:

```bash
mix deps.get
mix test
```

## Quickstart

Run a graph:

```bash
mix run examples/basic_graph.exs
```

Run a module-defined agent:

```bash
mix run examples/react_agent.exs
```

Run retrieval/indexing:

```bash
mix run examples/retrieval_indexing_agent.exs
```

## Concept Mapping

| LangChain/LangGraph concept | BeamWeaver concept |
|---|---|
| `StateGraph`, graph runtime | `BeamWeaver.Graph` and `BeamWeaver.Graph.Compiled` |
| `create_agent`, ReAct prebuilt | `use BeamWeaver.Agent` modules or `BeamWeaver.Agent.build/1` |
| chat messages | `BeamWeaver.Core.Message` and typed message chunks |
| tools | `BeamWeaver.Core.Tool`, `use BeamWeaver.Tool`, and ToolNode |
| memory/checkpoints/cache | explicit behaviours with ETS/Ecto adapters |
| async/streaming | `BeamWeaver.Core.Async` and `Enumerable` streams |
| callbacks | telemetry and typed stream envelopes |
| standard tests | test-only modules under `support/conformance` |
| OpenAI provider | `BeamWeaver.OpenAI` Responses and Chat Completions models |
| Anthropic provider | `BeamWeaver.Anthropic` Messages API models and tools |
| Google provider | `BeamWeaver.Google` Gemini Developer API models and tools |
| xAI provider | `BeamWeaver.XAI` Responses and Chat Completions models |
| LangSmith | telemetry/exporter boundary under `BeamWeaver.Tracing` |

## Guides

- [Getting Started](docs/getting_started.md)
- [Thinking In BeamWeaver](docs/thinking_in_beamweaver.md)
- [Workflows And Agents](docs/workflows_and_agents.md)
- [Persistence](docs/persistence.md)
- [Memory](docs/memory.md)
- [Agent Harness](docs/agent_harness.md)
- [Deep Agents Quickstart](docs/deep_agents_quickstart.md)
- [Customization](docs/customization.md)
- [Profiles](docs/profiles.md)
- [Filesystem](docs/filesystem.md)
- [Filesystem Permissions](docs/permissions.md)
- [Skills](docs/skills.md)
- [Sandboxes](docs/sandboxes.md)
- [Subagents](docs/subagents.md)
- [Async Subagents](docs/async_subagents.md)
- [Subgraphs](docs/subgraphs.md)
- [Time Travel](docs/time_travel.md)
- [Durable Execution](docs/durable_execution.md)
- [Fault Tolerance](docs/fault_tolerance.md)
- [Agents](docs/agents.md)
- [Context Engineering](docs/context_engineering.md)
- [Models](docs/models.md)
- [Messages](docs/messages.md)
- [Tools](docs/tools.md)
- [Middleware](docs/middleware.md)
- [Custom Middleware](docs/custom_middleware.md)
- [Prebuilt Middleware](docs/prebuilt_middleware.md)
- [Guardrails](docs/guardrails.md)
- [Human-In-The-Loop](docs/human_in_the_loop.md)
- [Runtime](docs/runtime.md)
- [Short-Term Memory](docs/short_term_memory.md)
- [Long-Term Memory](docs/long_term_memory.md)
- [Event Streaming](docs/event_streaming.md)
- [Structured Output](docs/structured_output.md)
- [Graph](docs/graph.md)
- [Retrieval](docs/retrieval.md)
- [Prompts And Parsers](docs/prompts_parsers.md)
- [Adapters](docs/adapters.md)
- [Core](docs/core.md)
- [Partner Matrix](docs/partners.md)
- [OpenAI](docs/partners/openai.md)
- [Anthropic](docs/partners/anthropic.md)
- [Google](docs/partners/google.md)
- [Moonshot/Kimi](docs/partners/moonshot.md)
- [xAI](docs/partners/xai.md)
- [Replay](docs/replay.md)
- [Going To Production](docs/going_to_production.md)
- [Rate Limiting](docs/rate_limiting.md)
- [Tracing](docs/tracing.md)
- [Standard Tests](docs/standard_tests.md)

GitBook uses `docs/README.md` and `docs/SUMMARY.md` as the published
documentation entry point and sidebar. Hex API reference is generated from
module docs with ExDoc.

## Verification

```bash
mix test
mix test --include postgres
mix format --check-formatted
```

Live Postgres tests use `BEAM_WEAVER_POSTGRES_URL`; local developers can point
it at any disposable BeamWeaver test database.
