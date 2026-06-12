# Quickstart

Build your first BeamWeaver agent and graph in minutes. BeamWeaver combines the
agent-facing pieces covered by LangChain's quickstart with the orchestration
pieces covered by LangGraph's quickstart.

Use an agent when you want the standard model/tool loop. Use a graph when you
want explicit nodes, edges, routing, state reducers, checkpoints, interrupts, or
custom workflow control.

{% hint style="info" %}
**Using An AI Coding Assistant**

LangChain's quickstarts point to the LangChain Docs MCP server and LangChain
Skills. BeamWeaver does not ship those packages. For BeamWeaver work, use the
native docs in this repository and generate `doc/llms.txt` with `mix docs` when
you want an LLM-friendly local documentation index.
{% endhint %}

## Install Dependencies

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

Inside this repository, run:

```bash
mix deps.get
mix test
```

## Set Up API Keys

Live provider calls require credentials in BeamWeaver application config. A
typical `config/runtime.exs` loads them from the OS environment:

```elixir
import Config

config :beam_weaver,
  openai: [api_key: System.fetch_env!("OPENAI_API_KEY")],
  anthropic: [api_key: System.fetch_env!("ANTHROPIC_API_KEY")],
  xai: [api_key: System.fetch_env!("XAI_API_KEY")]
```

{% hint style="warning" %}
**Provider Scope**

LangChain's quickstart shows tabs for OpenAI, Gemini, Anthropic, OpenRouter,
Fireworks, Baseten, Ollama, Azure, AWS Bedrock, HuggingFace, and other provider
packages. BeamWeaver currently documents first-class paths for OpenAI,
Anthropic, Google Gemini, xAI, fake models, and replay-backed tests. Other
provider adapters need native transport, message translation, streaming, model
profile, replay, and documentation coverage before being presented as supported
workflows.
{% endhint %}

## Build A Basic Agent

Start with a small weather tool and a model. This mirrors LangChain's
`create_agent` example, but uses BeamWeaver's Elixir tool and agent APIs.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Core.{Message, Tool}

get_weather =
  Tool.from_function!(
    name: "get_weather",
    description: "Get weather for a given city.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "city" => %{"type" => "string", "description" => "City name"}
      },
      "required" => ["city"]
    },
    handler: fn input, _opts ->
      city = input["city"] || input[:city]
      "It's always sunny in #{city}."
    end
  )

model =
  BeamWeaver.Models.init_chat_model!("openai:gpt-5.4",
    temperature: 0.2,
    timeout: 30_000
  )

{:ok, agent} =
  Agent.build(
    name: "weather_agent",
    model: model,
    tools: [get_weather],
    system_prompt: "You are a helpful assistant."
  )

{:ok, state} =
  Agent.invoke(agent, %{
    messages: [Message.user("What's the weather in San Francisco?")]
  })

state.messages
|> List.last()
|> Message.text()
```

You can also define the same agent as an application module:

```elixir
defmodule MyApp.WeatherAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4")

  tools do
    tool MyApp.Tools.GetWeather
  end

  system_prompt "You are a helpful assistant."
end
```

## Add Conversation Memory

Short-term memory is graph state persisted by a checkpointer. Reuse the same
checkpointer and `thread_id` across invocations:

```elixir
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "weather-thread-1"}}

{:ok, first_state} =
  Agent.invoke(
    agent,
    %{messages: [Message.user("My name is Ada.")]},
    checkpointer: checkpointer,
    config: config
  )

{:ok, second_state} =
  Agent.invoke(
    agent,
    %{messages: [Message.user("What did I tell you my name was?")]},
    checkpointer: checkpointer,
    config: config
  )
```

Use `BeamWeaver.Checkpoint.ETS` for tests and local workflows. Use
`BeamWeaver.Checkpoint.Ecto` for durable Postgres-backed deployments.

## Build A Calculator Graph

LangGraph's quickstart builds a calculator agent with explicit graph nodes.
BeamWeaver uses the same graph idea with Elixir data and functions. For static
workflows, define the graph in a module:

```elixir
defmodule MyApp.CalculatorGraph do
  use BeamWeaver.Agent

  graph do
    node :route, fn state -> %{operation: state.operation} end
    node :add, fn state -> %{result: state.a + state.b} end
    node :multiply, fn state -> %{result: state.a * state.b} end
    node :divide, fn state -> %{result: state.a / state.b} end

    edge start(), :route
    edge :route, :add, when: %{operation: :add}
    edge :route, :multiply, when: %{operation: :multiply}
    edge :route, :divide, when: %{operation: :divide}
    edge :add, finish()
    edge :multiply, finish()
    edge :divide, finish()
  end
end

{:ok, state} =
  MyApp.CalculatorGraph.invoke(%{
    operation: :add,
    a: 3,
    b: 4
  })

state.result
```

The same graph can stream typed events:

```elixir
MyApp.CalculatorGraph.graph()
|> BeamWeaver.Graph.Compiled.stream_events(%{operation: :multiply, a: 6, b: 7})
|> Enum.each(fn envelope -> IO.inspect(envelope.event) end)
```

Use `BeamWeaver.Graph` builder functions when the topology is generated from
configuration at runtime instead of written as an application module.

For a graph-backed model/tool loop, use [Agents](agents.md). Agents compile to
graphs, so you can embed an agent graph inside a larger workflow when you need a
hybrid deterministic and agentic system.

{% hint style="info" %}
**State Reducers**

LangGraph's Python examples use `Annotated[..., operator.add]` to append
messages. BeamWeaver uses explicit reducers:

```elixir
BeamWeaver.Graph.add_reducer(graph, :messages, fn existing, update ->
  existing ++ List.wrap(update)
end)
```

Reducers make state merge behavior visible and testable.
{% endhint %}

## Functional Style

LangGraph also has a Python Functional API with `@entrypoint` and `@task`
decorators. BeamWeaver does not copy those decorators. Use ordinary Elixir
functions for local control flow, and switch to `BeamWeaver.Graph` when you need
checkpointing, interrupts, streaming, state history, or orchestration metadata.

```elixir
defmodule MyApp.Calculator do
  def run(%{operation: :add, a: a, b: b}), do: {:ok, %{result: a + b}}
  def run(%{operation: :multiply, a: a, b: b}), do: {:ok, %{result: a * b}}
  def run(%{operation: :divide, a: a, b: b}), do: {:ok, %{result: a / b}}
end
```

{% hint style="warning" %}
**Functional API Deviation**

Python's LangGraph Functional API turns decorated functions into graph tasks.
BeamWeaver keeps task and supervision behavior explicit through graph nodes,
`BeamWeaver.Core.Async`, `Task.Supervisor`, and normal Elixir modules. There is
no BeamWeaver `@entrypoint` or `@task` decorator API.
{% endhint %}

## Build A Research Agent

For a more realistic agent, add a tool that fetches approved URLs and a
checkpointer for conversation state:

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.{Message, Tool}

fetch_text_from_url =
  Tool.from_function!(
    name: "fetch_text_from_url",
    description: "Fetch UTF-8 text from an approved URL.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"url" => %{"type" => "string"}},
      "required" => ["url"]
    },
    handler: fn input, _opts ->
      url = input["url"] || input[:url]

      case URI.parse(url) do
        %URI{scheme: "https", host: "www.gutenberg.org"} ->
          {:ok, response} = Req.get(url, receive_timeout: 120_000)
          response.body

        _other ->
          {:error, "URL is not allowed"}
      end
    end
  )

system_prompt = """
You are a literary data assistant.

Use fetch_text_from_url when you need source text. Do not invent exact line
counts or positions unless a tool or graph node computed them.
"""

{:ok, research_agent} =
  Agent.build(
    name: "research_agent",
    model: BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6",
      temperature: 0.5,
      timeout: 120_000
    ),
    tools: [fetch_text_from_url],
    system_prompt: system_prompt
  )

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "great-gatsby"}}

Agent.invoke(
  research_agent,
  %{
    messages: [
      Message.user("""
      Fetch https://www.gutenberg.org/files/64317/64317-0.txt and summarize the text.
      If you cannot verify exact counts, say so.
      """)
    ]
  },
  checkpointer: checkpointer,
  config: config
)
```

Exact line counting over a large file should be done by deterministic code, a
retriever/indexing workflow, or a graph node, not by asking a model to count
tokens in its context window.

{% hint style="info" %}
**Integrated Deep Agents Capabilities**

LangChain's quickstart compares a basic LangChain agent with Deep Agents, which
adds planning, a virtual filesystem, file search, and subagents. BeamWeaver does
not expose a separate `create_deep_agent` constructor. Instead, those
capabilities are positive declarations on `BeamWeaver.Agent`: add the tools,
middleware, filesystem, memory, checkpointing, and subagents you need, and omit
the ones you do not.
Use [Deep Agents Quickstart](deep_agents_quickstart.md) for a focused
research-agent walkthrough with planning, filesystem tools, and a subagent.
Use [Composed Agent Capabilities](agent_harness.md) for the full capability map.
{% endhint %}

## Trace And Debug Calls

BeamWeaver exposes telemetry and tracing boundaries through
`BeamWeaver.Tracing`. Generate ExDoc reference locally with:

```bash
mix docs
```

Then inspect:

```bash
open doc/index.html
```

{% hint style="info" %}
**Hosted Product Scope**

LangChain's quickstarts use hosted tracing and deployment links.
BeamWeaver has telemetry and tracing/export boundaries, but it does not
implement hosted engines, deployments, Studio, or remote LangGraph Platform APIs
as built-in product features.
{% endhint %}

## Next Steps

- [Overview](README.md)
- [Thinking In BeamWeaver](thinking_in_beamweaver.md)
- [Workflows And Agents](workflows_and_agents.md)
- [Persistence](persistence.md)
- [Durable Execution](durable_execution.md)
- [Fault Tolerance](fault_tolerance.md)
- [Deep Agents Quickstart](deep_agents_quickstart.md)
- [Composed Agent Capabilities](agent_harness.md)
- [Agents](agents.md)
- [Graph](graph.md)
- [Tools](tools.md)
- [Models](models.md)
- [Runtime](runtime.md)
- [Short-Term Memory](short_term_memory.md)
- [Long-Term Memory](long_term_memory.md)
- [Event Streaming](event_streaming.md)
- [Retrieval](retrieval.md)
- [Tracing](tracing.md)
