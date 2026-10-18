# BeamWeaver

Build agents and durable workflows inside an Elixir application. Define tools
as modules, give a model a bounded set of actions, and inspect what it did.
Use graphs when your application should choose the steps explicitly.

You need basic Elixir and Mix knowledge. No prior agent-framework experience
is assumed. These guides target **1.0.0**; check the
[release status](installation.md#release-status) before installing from Hex.

## Start with a working application

1. [Install and configure](installation.md) a Mix application and provider key.
2. [Run your first agent](quickstart.md) against OpenAI or Google.
3. [Build a support agent](tutorial.md) with an order tool and conversation history.
4. Read [How BeamWeaver Works](concepts.md) to connect the runtime concepts.

Examples say where code belongs and what to observe. Live answers can vary in
wording; the guides check facts, tool results and state where those matter.
The [testing guide](testing.md) introduces scripted models for application tests.

## Learn the DSLs

| You are defining | Guide |
| --- | --- |
| Model, instructions, tools and execution policy | [Agent DSL](agents.md) |
| An action and its input contract | [Tool DSL](tools.md) |
| A structured final answer | [Schema DSL](structured_output.md) |
| Hooks around model and tool calls | [Middleware DSL](middleware.md) |
| Steps, branches, joins and state channels | [Graph DSL](graphs.md) and [State](graph_state.md) |

## Add the capability your task needs

| Need | Next guide |
| --- | --- |
| Trusted caller or tenant data | [Runtime Context](runtime_context.md) |
| Progress in a UI | [Streaming](streaming.md) |
| Conversation history | [Conversation History](short_term_memory.md) |
| Facts shared across conversations | [Long-Term Memory](long_term_memory.md) |
| Human approval before actions | [Human Review](human_in_the_loop.md) |
| Files, planning, procedures and delegation | [Compose a Deep Agent](deep_agents.md) |
| Answers grounded in your documents | [Retrieval](retrieval.md) |
| Explicit orchestration | [Workflow Patterns](workflow_patterns.md) |
| Recovery and persistent state | [Checkpoints](checkpoints.md), [Storage](storage.md) |

## Ship and operate

[Production Integration](going_to_production.md) connects supervision,
authorization, persistence, budgets and shutdown. [Tracing](tracing.md) explains
local inspection and export to WeaveScope. [Configuration](configuration.md)
separates application settings from model options and per-request data.

Use the [provider reference](providers.md) for endpoint-specific features.
The guides include complete code, options and result contracts inline.
[Runnable Examples](examples.md) provides a task index and optional downloadable
scripts; you can follow the guides entirely on this documentation site.
