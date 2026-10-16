# Quickstart

Build a support agent that looks up orders with a tool, run it without an API
key, then switch it to a real model. It takes about ten minutes.

## Install

Create a project and add BeamWeaver to `mix.exs`:

```bash
mix new my_app --sup
cd my_app
```

```elixir
def deps do
  [
    {:beam_weaver, "~> 0.1.32"}
  ]
end
```

Then run `mix deps.get`. BeamWeaver needs Elixir 1.19 or later.

## Write a tool

A tool is a module the model can call. Its `name`, `description` and `schema`
tell the model what the tool does and which arguments it takes; `invoke/3`
does the work. Save this as `lib/my_app/tools/lookup_order.ex`:

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id, such as A-1001."

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts) do
    {:ok, "Order #{order_id} shipped on Monday and arrives on Thursday."}
  end
end
```

Arguments arrive under string keys, the way the model sends them as JSON.

## Write the agent

An agent is a module too. It names a model, gives it instructions, and lists
the tools it may call. Save this as `lib/my_app/support_agent.ex`:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday and arrives on Thursday."
    ]

  system_prompt "You are Acme's support agent. Look orders up before you answer."
  tools [MyApp.Tools.LookupOrder]
end
```

`"fake:chat"` is a scripted model built into BeamWeaver. Each entry in
`responses:` is what it says on one turn: first it calls `lookup_order`, then
it answers. A fake model needs no key and always behaves the same, so it is
also what you use in tests.

## Run it

Start `iex -S mix` and ask a question:

```elixir
{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})

result.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "Your order A-1001 shipped on Monday and arrives on Thursday."
```

`invoke/2` runs the agent loop until the model answers without calling a
tool, and returns the final state. The conversation shows each step:

```elixir
Enum.map(result.messages, & &1.role)
#=> [:user, :assistant, :tool, :assistant]
```

1. **user** — your question.
2. **assistant** — the model asks for `lookup_order` with `order_id: "A-1001"`.
3. **tool** — BeamWeaver runs the tool and records its result.
4. **assistant** — the model answers using that result.

The tool call is on the first assistant message:

```elixir
[call] = Enum.at(result.messages, 1).tool_calls
{call.name, call.args}
#=> {"lookup_order", %{"order_id" => "A-1001"}}
```

## Keep the conversation

By default every `invoke/2` starts fresh. To continue a conversation, give
the agent a checkpointer and a thread id. The checkpointer saves the state
after each step; the thread id says which conversation to load:

```elixir
saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:ok, _first} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]}, opts)
{:ok, second} = MyApp.SupportAgent.invoke(%{messages: ["Thanks! Which day again?"]}, opts)

length(second.messages)
#=> 6
```

The second call saw the whole first exchange. `Checkpoint.ETS` keeps threads
in memory, in tables owned by the process that created the saver (here, your
iex shell), so create it once and pass it on every call. In production you
use `Checkpoint.Ecto` with Postgres or SQLite.

## Use a real model

Now let a real model decide. In `lib/my_app/support_agent.ex`, replace the
`model "fake:chat", responses: [...]` declaration with a provider model and
delete the `FakeChatModel` alias. Then create `config/runtime.exs` (`mix new`
doesn't make a `config` folder) so BeamWeaver reads the API key from the
environment:

{% tabs %}
{% tab title="OpenAI" %}
```elixir
model "openai:gpt-5.4-mini"
```

```elixir
# config/runtime.exs
import Config

config :beam_weaver, :openai, api_key: System.get_env("OPENAI_API_KEY")
```
{% endtab %}

{% tab title="Anthropic" %}
```elixir
model "anthropic:claude-haiku-4-5"
```

```elixir
# config/runtime.exs
import Config

config :beam_weaver, :anthropic, api_key: System.get_env("ANTHROPIC_API_KEY")
```
{% endtab %}

{% tab title="Google Gemini" %}
```elixir
model "google:gemini-3.5-flash"
```

```elixir
# config/runtime.exs
import Config

config :beam_weaver, :google, api_key: System.get_env("GOOGLE_API_KEY")
```
{% endtab %}
{% endtabs %}

Export the key in your shell (for example `export OPENAI_API_KEY=...`),
restart `iex -S mix` and ask again. Ask about another order, or about
something unrelated, and see how the model decides when to call the tool.
[Providers](providers.md) lists every provider and model.

## Next steps

- [Concepts](concepts.md) explains agents, tools, graphs, threads and memory
  in one page.
- [Agents](agents.md) covers everything an agent module can declare.
- [Tools](tools.md) shows richer tools: injected state, errors, and results
  for the user.
- [Human-in-the-Loop](human_in_the_loop.md) pauses the agent for approval
  before a tool runs, such as issuing a refund.
- [Examples](examples.md) lists runnable scripts for every feature.
