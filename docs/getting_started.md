# Quickstart

Build your first BeamWeaver agent and graph in minutes. BeamWeaver gives Elixir
applications a native model/tool loop, explicit workflow graphs, streaming,
memory, checkpointing, and tracing.

Use an agent when you want the standard model/tool loop. Use a graph when you
want explicit nodes, edges, routing, state reducers, checkpoints, interrupts, or
custom workflow control.

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

## Build A Basic Agent

Start with a small weather tool and a model using BeamWeaver's Elixir tool and
agent APIs.

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
defmodule MyApp.Tools.GetWeather do
  use BeamWeaver.Tool

  name "get_weather"
  description "Get weather for a given city."

  schema do
    field :city, :string, required: true, description: "City name"
  end

  @impl true
  def invoke(_tool, input, _opts) do
    city = Map.get(input, :city) || Map.get(input, "city")
    {:ok, "It's always sunny in #{city}."}
  end
end

defmodule MyApp.WeatherAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("openai:gpt-5.4",
    temperature: 0.2,
    timeout: 30_000
  )

  tools do
    tool MyApp.Tools.GetWeather
  end

  system_prompt "You are a helpful assistant."
end

alias BeamWeaver.Core.Message

{:ok, state} =
  MyApp.WeatherAgent.invoke(%{
    messages: [Message.user("What's the weather in San Francisco?")]
  })

state.messages
|> List.last()
|> Message.text()
```

## Add Conversation Memory

Short-term memory is graph state persisted by a checkpointer. Reuse the same
checkpointer and `thread_id` across invocations of the same agent module:

```elixir
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "weather-thread-1"}}

{:ok, _first_state} =
  MyApp.WeatherAgent.invoke(
    %{messages: [Message.user("My name is Ada.")]},
    checkpointer: checkpointer,
    config: config
  )

{:ok, second_state} =
  MyApp.WeatherAgent.invoke(
    %{messages: [Message.user("What did I tell you my name was?")]},
    checkpointer: checkpointer,
    config: config
  )

second_state.messages
|> List.last()
|> Message.text()
```

Use `BeamWeaver.Checkpoint.ETS` for tests and local workflows. Use
`BeamWeaver.Checkpoint.Ecto` for durable Postgres-backed deployments.

## Build A Calculator Graph

A calculator workflow is a good fit for explicit graph nodes. For static
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

When multiple nodes update list-like state, use explicit reducers:

```elixir
BeamWeaver.Graph.add_reducer(graph, :messages, fn existing, update ->
  existing ++ List.wrap(update)
end)
```

Reducers make state merge behavior visible and testable.
{% endhint %}

## Functional Style

Use ordinary Elixir functions for local control flow, and switch to
`BeamWeaver.Graph` when you need checkpointing, interrupts, streaming, state
history, or orchestration metadata.

```elixir
defmodule MyApp.Calculator do
  def run(%{operation: :add, a: a, b: b}), do: {:ok, %{result: a + b}}
  def run(%{operation: :multiply, a: a, b: b}), do: {:ok, %{result: a * b}}
  def run(%{operation: :divide, a: a, b: b}), do: {:ok, %{result: a / b}}
end
```

## Build A Research Agent

For a more realistic agent, add a tool that fetches approved URLs and reuse a
checkpointer for conversation state:

```elixir
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.Message

defmodule MyApp.Tools.FetchTextFromURL do
  use BeamWeaver.Tool

  name "fetch_text_from_url"
  description "Fetch UTF-8 text from an approved URL."

  schema do
    field :url, :string, required: true
  end

  @impl true
  def invoke(_tool, input, _opts) do
    url = Map.get(input, :url) || Map.get(input, "url")

    case URI.parse(url) do
      %URI{scheme: "https", host: "www.gutenberg.org"} ->
        {:ok, response} = Req.get(url, receive_timeout: 120_000)
        {:ok, response.body}

      _other ->
        {:error, "URL is not allowed"}
    end
  end
end

defmodule MyApp.ResearchAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6",
    temperature: 0.5,
    timeout: 120_000
  )

  tools do
    tool MyApp.Tools.FetchTextFromURL
  end

  system_prompt """
  You are a literary data assistant.

  Use fetch_text_from_url when you need source text. Do not invent exact line
  counts or positions unless a tool or graph node computed them.
  """
end

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "great-gatsby"}}

{:ok, state} =
  MyApp.ResearchAgent.invoke(
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

state.messages
|> List.last()
|> Message.text()
```

Exact line counting over a large file should be done by deterministic code, a
retriever/indexing workflow, or a graph node, not by asking a model to count
tokens in its context window.

{% hint style="info" %}
**Integrated Deep Agents Capabilities**

BeamWeaver does not expose a separate deep-agent constructor. Planning, a
virtual filesystem, file search, memory, checkpointing, middleware, and
subagents are positive declarations on `BeamWeaver.Agent`: add the capabilities
you need and omit the ones you do not.
Use [Deep Agents Quickstart](deep_agents_quickstart.md) for a focused
research-agent walkthrough with planning, filesystem tools, and a subagent.
Use [Composed Agent Capabilities](agent_harness.md) for the full capability map.
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
