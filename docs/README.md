# BeamWeaver

BeamWeaver is an Elixir library for building applications on large language
models (LLMs) such as GPT, Claude and Gemini. You write tools as Elixir
modules, and an agent lets the model call them in a loop until it can answer.
Graphs run workflows with steps you define; they survive restarts and can
pause for a person's approval. Deep agents plan, keep files and hand work to
subagents. Everything runs inside your own application, with streaming and
tracing built in.

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini"
  system_prompt "You are Acme's support agent. Look orders up before you answer."
  tools [MyApp.Tools.LookupOrder]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
```

`MyApp.Tools.LookupOrder` is a tool: a module the model can call to look an
order up. When the model asks for it, BeamWeaver runs it and hands the result
back, until the model answers. New to BeamWeaver? The
[Quickstart](quickstart.md) writes this tool and agent and runs them without
an API key.

## Start here

- [Quickstart](quickstart.md) — build a support agent with a tool and run it
  without an API key, then switch to a real model.
- [Concepts](concepts.md) — agents, graphs, deep agents, threads, memory and
  context on one page.
- [Examples](examples.md) — runnable scripts for every feature.

## Choose your path

| You want to | Read |
| --- | --- |
| Answer questions with your own data and actions | [Agents](agents.md), [Tools](tools.md), [Models](models.md) |
| Get typed results instead of text | [Structured Output](structured_output.md) |
| Remember conversations and users | [Short-Term Memory](short_term_memory.md), [Long-Term Memory](long_term_memory.md) |
| Approve risky actions before they happen | [Human-in-the-Loop](human_in_the_loop.md), [Guardrails](guardrails.md) |
| Show progress while the agent works | [Streaming](streaming.md) |
| Handle long, open-ended tasks | [Deep Agents](deep_agents.md), [Subagents](subagents.md), [Skills](skills.md) |
| Run code the agent writes | [Sandboxes](sandboxes.md) |
| Control every step of a workflow | [Graphs](graphs.md), [Workflow Patterns](workflow_patterns.md) |
| Survive crashes and deploys mid-run | [Durable Execution](durable_execution.md), [Checkpoints](checkpoints.md) |
| Search your documents | [Retrieval](retrieval.md) |
| Ship it | [Going to Production](going_to_production.md), [Testing](testing.md), [Tracing](tracing.md) |

## Providers

OpenAI, Anthropic, Google Gemini, xAI, DeepSeek, Moonshot (Kimi), Z.ai and
TypeSafe. You pick a model with a string such as `"anthropic:claude-haiku-4-5"`,
and fake models stand in for all of them in tests. See
[Providers](providers.md).

## Tracing

Every run records a trace: agents, graph steps, model and tool calls, tokens
and costs. Send traces to [WeaveScope](https://weavescope.com) to inspect them
with your team. See [Tracing](tracing.md).

{% hint style="info" %}
Moving an existing project over? [Coming from LangChain](coming_from_langchain.md)
shows where familiar concepts live in BeamWeaver.
{% endhint %}
