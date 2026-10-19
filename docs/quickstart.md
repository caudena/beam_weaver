# Your First Agent

Make a real model call from an Elixir module. This page assumes you have
completed [Installation](installation.md), including the provider key.
Calls use your provider account and may incur charges.

<a name="build-a-basic-agent"></a>

## Define an agent

Save this as `lib/my_app/support_agent.ex`:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "You help customers understand orders. Be brief. Do not invent order details."
end
```

`use BeamWeaver.Agent` gives the module its runtime functions. `model`
selects the provider and model; the options limit this example's output and
request time. `system_prompt` supplies instructions on each model call.
No tools are available yet, so the agent can explain what information it
needs but cannot look up an order. Save only the module in the source file;
the invocation blocks below belong in IEx or your application call site.

## Run it

Start `iex -S mix`, then evaluate:

```elixir
{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["What information do you need to find my order?"]})
answer = result.messages |> List.last() |> BeamWeaver.Core.Message.text()
true = is_binary(answer) and byte_size(answer) > 0
IO.puts(answer)
```

The wording varies. Expect a request for information such as an order number.
`result.messages` contains the conversation, including the user's message
and the model's answer. Reading that result does not make another API call.

The simple match above is useful in IEx. At an application boundary, handle
all three return shapes so failures and review pauses are visible:

```elixir
outcome =
  case MyApp.SupportAgent.invoke(%{messages: ["Can you help me track an order?"]}) do
    {:ok, state} -> {:answer, state.messages |> List.last() |> BeamWeaver.Core.Message.text()}
    {:interrupted, review} -> {:waiting_for_review, review}
    {:error, error} -> {:failed, error.type, error.message}
  end

{:answer, text} = outcome
true = byte_size(text) > 0
```

An interrupt means the run paused and needs a resume value; it is not a final
answer. This simple agent has no interrupt declarations. An error carries a
type and message you can log or translate into your application's response.

## Use Google

After adding the Google configuration from [Installation](installation.md#use-google-instead),
this is a complete alternative agent:

```elixir
defmodule MyApp.GoogleSupportAgent do
  use BeamWeaver.Agent

  model "google:gemini-3.5-flash", max_tokens: 512, timeout: 60_000
  system_prompt "You help customers understand orders. Be brief. Do not invent order details."
end

{:ok, result} = MyApp.GoogleSupportAgent.invoke(%{messages: ["What information do you need to find my order?"]})
answer = result.messages |> List.last() |> BeamWeaver.Core.Message.text()
true = is_binary(answer) and byte_size(answer) > 0
IO.puts(answer)
```

The agent interface is the same. Provider-specific capabilities and options
are documented in [Providers](providers.md).

## Next steps

[Build an Agent](tutorial.md) adds a tool, checks that the model called it,
and continues the conversation. [Concepts](concepts.md) explains the moving
parts. [Testing](testing.md) shows how to test without an API key using
scripted responses and request assertions.
