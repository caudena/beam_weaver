# BeamWeaver

BeamWeaver is an Elixir library for AI agents and durable workflows. An agent
lets a model choose tools and produce an answer. A graph executes the steps
you define. Both run inside your application and support streaming,
checkpoints and pauses for human input.

These guides describe the refactored **1.0.0** API. See the
[release status](installation.md#release-status) before installing from Hex.

## Start here

1. [Installation](installation.md): create a Mix application and configure credentials.
2. [Quickstart](quickstart.md): make your first real OpenAI or Google call.
3. [Build an Agent](tutorial.md): add a tool, inspect the model's work and continue a conversation.
4. [Concepts](concepts.md): understand state, threads, context, agents and graphs.
5. [Testing](testing.md): verify your application with scripted models and replay.

You need basic Elixir and Mix knowledge. No previous agent-framework
experience is assumed. Examples state their setup and expected behavior;
model-generated wording can vary.

## Choose a capability

| Your application needs | Read |
| --- | --- |
| Model-selected actions | [Agents](agents.md), [Tools](tools.md) |
| A validated answer shape | [Structured Output](structured_output.md) |
| Conversation history or user preferences | [Short-Term Memory](short_term_memory.md), [Long-Term Memory](long_term_memory.md) |
| Progress and partial output | [Streaming](streaming.md) |
| Approval before a sensitive action | [Human-in-the-Loop](human_in_the_loop.md) |
| Planning, files, skills or delegated work | [Deep Agents](deep_agents.md) |
| Explicit steps, branches and parallelism | [Graphs](graphs.md), [Workflow Patterns](workflow_patterns.md) |
| Restart recovery and durable state | [Checkpoints](checkpoints.md), [Storage](storage.md) |
| Search over your documents | [Retrieval](retrieval.md) |
| Operational configuration and diagnostics | [Configuration](configuration.md), [Going to Production](going_to_production.md), [Tracing](tracing.md) |

## Reference and runnable projects

The guides teach behaviors and link to the public API reference. The
[Agents](agents.md) and [Graphs](graphs.md) guides cover the DSLs; the
[provider guides](providers.md) cover all supported backends and their
differences. [Examples](examples.md) lists complete scripts for further study.

BeamWeaver can export traces to [WeaveScope](https://weavescope.com).
[Tracing](tracing.md) covers local inspection and exporter configuration.
