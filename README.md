# BeamWeaver

[![ci](https://github.com/caudena/beam_weaver/actions/workflows/ci.yml/badge.svg)](https://github.com/caudena/beam_weaver/actions/workflows/ci.yml)

Build AI agents and durable workflows in Elixir. Define tools as modules,
give an agent a model and instructions, and run it inside your application.
Use explicit graphs when your application should control the steps.

These docs target **1.0.0**. The Hex dependency `{:beam_weaver, "~> 1.0.0"}`
becomes installable when that release is published. See
[Installation](docs/installation.md) for application setup and credentials.

## Your first agent

After configuring OpenAI in your application's `config/runtime.exs`:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Help customers with orders. Be brief and do not invent order details."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["What do you need to look up my order?"]})
answer = result.messages |> List.last() |> BeamWeaver.Core.Message.text()
true = is_binary(answer) and byte_size(answer) > 0
IO.puts(answer)
```

The [Quickstart](docs/quickstart.md) explains each line and includes a Google
alternative. [Build an Agent](docs/tutorial.md) adds a real tool, verifies
that the model called it, and continues the conversation.

## Build from the pieces you need

| Capability | Guide |
| --- | --- |
| Declare agents, typed tools and structured answers | [Agents](docs/agents.md), [Tools](docs/tools.md), [Structured Output](docs/structured_output.md) |
| Stream progress and integrate per-request context | [Streaming](docs/streaming.md), [Runtime Context](docs/runtime_context.md) |
| Keep conversations and cross-thread memory | [Short-Term Memory](docs/short_term_memory.md), [Long-Term Memory](docs/long_term_memory.md) |
| Review actions before they run | [Human-in-the-Loop](docs/human_in_the_loop.md) |
| Add files, planning, skills and delegation | [Deep Agents](docs/deep_agents.md) |
| Control workflow steps, branches and parallel work | [Graphs](docs/graphs.md), [Workflow Patterns](docs/workflow_patterns.md) |
| Persist checkpoints and recover interrupted work | [Storage](docs/storage.md), [Durable Execution](docs/durable_execution.md) |
| Search documents with embeddings and vector stores | [Retrieval](docs/retrieval.md) |
| Apply retries, limits, caching and context policies | [Built-in Middleware](docs/builtin_middleware.md), [Context Management](docs/context_management.md) |
| Test and inspect production behavior | [Testing](docs/testing.md), [Tracing](docs/tracing.md), [Going to Production](docs/going_to_production.md) |

## Providers

OpenAI, Anthropic, Google Gemini, xAI, DeepSeek, Moonshot, Z.ai and TypeSafe.
The [provider guides](docs/providers.md) distinguish chat, embedding and
decision models and explain each provider's supported features. Fake models
and replay transports support deterministic application tests.

## Documentation and examples

- [Guides](https://docs.weavescope.com/beamweaver)
- [API reference](https://hexdocs.pm/beam_weaver)
- [Runnable examples](docs/examples.md)
- [Changelog](CHANGELOG.md)

Run `mix test` for deterministic checks and `mix docs.verify --all` for
isolated documentation execution, including required live providers and
services. The verification report identifies failures and unmet prerequisites;
compilation alone is not reported as executed coverage.

Apache-2.0. See [LICENSE](https://github.com/caudena/beam_weaver/blob/master/LICENSE).
