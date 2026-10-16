# Providers

A provider is a model API that BeamWeaver calls directly over HTTP: OpenAI,
Anthropic, Google Gemini, DeepSeek, Moonshot (Kimi), xAI, Z.ai and TypeSafe.
You pick one with a model string and a key in config; agents, tools, graphs and
streaming work the same on all of them.

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "anthropic:claude-haiku-4-5"
  system_prompt "You are Acme's support agent. Look orders up before you answer."
end
```

## Model strings

A model string is `"provider:model"`: a provider prefix, then the provider's
own model id, which is sent to its API unchanged. The agent DSL passes the
string to `BeamWeaver.Models.init_chat_model/2`, which builds the provider's
model struct and attaches the model's profile: its context size and what it
supports (tools, structured output, images). BeamWeaver checks each request
against the profile before it leaves your app.

Always write the prefix. BeamWeaver guesses the provider of a bare `gpt-*`,
`claude-*` or `grok-*` id, but not of Gemini, DeepSeek, Kimi or GLM ids:

```elixir
{:error, error} = BeamWeaver.Models.init_chat_model("gemini-3.5-flash")
error.message
#=> "Gemini model identifiers require the google: prefix"
```

A retired model id returns an error that names its replacement, so an upgrade
never silently switches you to a different model. [Models](models.md) covers
calling a model directly and reading its profile.

## Supported providers

<!-- generated: provider-overview -->
| Provider | Prefix | Models | Tools | Structured output | Reasoning | Image input |
| --- | --- | --- | --- | --- | --- | --- |
| [OpenAI](providers/openai.md) | `openai:` | 17 chat, 2 embedding | all | all | 16 of 17 | all |
| [Anthropic](providers/anthropic.md) | `anthropic:` | 19 chat | all | 16 of 19 | all | all |
| [Google Gemini](providers/google.md) | `google:` | 7 chat | all | all | all | all |
| [xAI](providers/xai.md) | `xai:` | 7 chat, 1 embedding | all | all | 6 of 7 | all |
| [Moonshot (Kimi)](providers/moonshot.md) | `moonshot:` | 5 chat | all | all | all | all |
| [Z.ai](providers/zai.md) | `zai:` | 8 chat | all | all | all | 2 of 8 |
| [DeepSeek](providers/deepseek.md) | `deepseek:` | 4 chat | all | all | all | 3 of 4 |
| [TypeSafe](providers/typesafe.md) | `typesafe:` | 3 decision | — | — | — | — |
<!-- /generated -->

Run `mix beam_weaver.models.profiles` to print every model id your version
knows. TypeSafe's Jev is a decision model: it answers typed questions and can
route an agent between chat models, but cannot run one. In tests, `fake:chat`
stands in for any provider (see [Testing](testing.md)).

## Credentials

Put the keys of the providers you use in your app's `config/runtime.exs`:

```elixir
# config/runtime.exs
import Config

config :beam_weaver, :openai, api_key: System.get_env("OPENAI_API_KEY")
config :beam_weaver, :anthropic, api_key: System.get_env("ANTHROPIC_API_KEY")
config :beam_weaver, :google, api_key: System.get_env("GOOGLE_API_KEY")
config :beam_weaver, :deepseek, api_key: System.get_env("DEEPSEEK_API_KEY")
config :beam_weaver, :moonshot, api_key: System.get_env("MOONSHOT_API_KEY")
config :beam_weaver, :xai, api_key: System.get_env("XAI_API_KEY")
config :beam_weaver, :zai, api_key: System.get_env("ZAI_API_KEY")
config :beam_weaver, :typesafe, api_key: System.get_env("TYPESAFE_API_KEY")
```

BeamWeaver reads keys from application config, not from environment variables,
and a dependency's own config files don't apply to your app, so these lines are
required. A missing key is not caught at startup: the first call returns
`{:error, %BeamWeaver.Core.Error{type: :missing_api_key}}`, on every provider,
without sending a request.

The same config groups take a few more keys:

| Key | Providers | Purpose |
| --- | --- | --- |
| `organization`, `project` | OpenAI | Bill requests to an organization or project. |
| `base_url` | All | API root, for a proxy, gateway or regional host. |

A model's own `api_key:` option wins over config, for example to use one key
per customer.

## Options for every provider

These options work on every chat model, set on the `model` line of an agent or
passed to `init_chat_model/2`:

| Option | What it does |
| --- | --- |
| `api_key` | Use this key instead of the configured one. |
| `timeout` | Milliseconds to wait for the response. Default `15_000`; raise it for long reasoning calls. |
| `temperature`, `top_p` | Sampling, on models that allow it. |
| `max_tokens` | Cap the output tokens. `max_output_tokens` is the same option. |
| `extra_body` | A map merged into the request body, for provider fields BeamWeaver doesn't model. |
| `base_url` | The API root, instead of the configured one. |
| `endpoint` | The full URL to send requests to, for a proxy or an [OpenAI-compatible server](#openai-compatible-servers). Google takes the API root here, as with `base_url`. |
| `transport`, `transport_opts` | Replace the HTTP layer, for example with cassettes in tests. |
| `profile` | Override what BeamWeaver believes the model supports. |

Reasoning, caching and other options are specific to a provider; see its page.
A model rejects an option it doesn't take, both when you create it and on a
call, with an `:unsupported_model_param` error. An agent's model options apply
to every call, and `model_opts:` overrides them for one invocation:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", reasoning_effort: :low, timeout: 60_000
  system_prompt "You are Acme's support agent."
end

MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]},
  model_opts: [reasoning_effort: :high]
)
```

{% hint style="warning" %}
Options on the `model` line are evaluated each time the agent runs, so they
can read runtime configuration. Keep keys and other secrets in
`config/runtime.exs` and read them there, as in
`api_key: Application.fetch_env!(:my_app, :openai_key)`, never as literals in
the agent module.
{% endhint %}

## Switching and fallback

To switch providers, change the model string and replace its provider-specific
options: a provider rejects options it doesn't take before the request. To survive an outage, give the agent backup models with
`BeamWeaver.Agent.Middleware.ModelFallback`; it tries them in order when a
model call fails:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.ModelFallback

  model "openai:gpt-5.4-mini"
  system_prompt "You are Acme's support agent."

  middleware [{ModelFallback, fallbacks: ["anthropic:claude-haiku-4-5"]}]
end
```

A fallback is a `"provider:model"` string, resolved the way the agent's
`model` is, or a model value from `BeamWeaver.Models.init_chat_model!/2` when
it needs options. It uses its own API key and connection settings, and of the
agent's model options it gets only those it takes, so `reasoning_effort:` on
an OpenAI model doesn't reach a Claude fallback. When a fallback's key isn't
in your configuration, give it one with `init_chat_model!/2`. BeamWeaver
never retries a failed call by itself; add
`BeamWeaver.Agent.Middleware.ModelRetry` for that.
[Built-in Middleware](builtin_middleware.md) covers both. To pick a model per
request, see the [TypeSafe router](providers/typesafe.md).

When the conversation moves to another provider, or between OpenAI's
Responses and Chat Completions APIs, earlier replies go to the new model as
their text and tool calls. Their reasoning, such as Claude's thinking, is left
out: a provider takes back only its own.

## OpenAI-compatible servers

Servers that speak OpenAI's Chat Completions API, such as a local inference
server, work through `BeamWeaver.OpenAI.chat_completions_model/1` and an
`endpoint`. BeamWeaver has no profile for their models, so declare what the
model supports with `profile:`; without `tool_calling: true`, BeamWeaver
refuses to send tools. Always pass `api_key:`, or your configured OpenAI key
is sent to that server; for a server that needs no key, pass a placeholder,
since a call without a key fails with `:missing_api_key`:

```elixir
defmodule MyApp.LocalAgent do
  use BeamWeaver.Agent

  model BeamWeaver.OpenAI.chat_completions_model(
          model: "llama3.1",
          endpoint: "http://localhost:11434/v1/chat/completions",
          api_key: "unused",
          profile: %{tool_calling: true, max_input_tokens: 128_000}
        )

  system_prompt "You are Acme's support agent."
end
```

To route a supported provider through a proxy or gateway instead, set
`base_url`, the API root, in its config group or on the model, or the full
`endpoint` URL on the model (every chat provider but Google).

## Adding a provider

Any other API can become a provider with its own prefix. Write a chat model
that implements `BeamWeaver.Core.ChatModel` (only `invoke/3` is required) and
an adapter that implements `BeamWeaver.Provider.Adapter`:

```elixir
defmodule MyApp.Acme.ChatModel do
  @behaviour BeamWeaver.Core.ChatModel

  defstruct model: "support-1", profile: nil

  @impl true
  def invoke(%__MODULE__{}, _messages, _opts) do
    # Call your API here and return the reply as an assistant message.
    {:ok, BeamWeaver.Core.Message.assistant("Order A-1001 shipped on Monday.")}
  end
end

defmodule MyApp.Acme.Provider do
  @behaviour BeamWeaver.Provider.Adapter

  @impl true
  def provider, do: :acme

  @impl true
  def chat_model(_opts), do: {:ok, MyApp.Acme.ChatModel}

  @impl true
  def profile(model), do: {:ok, BeamWeaver.Models.Profile.new(provider: :acme, id: model)}
end
```

Register the adapter in `config/config.exs` with
`config :beam_weaver, :providers, [MyApp.Acme.Provider]`, or at runtime with
`BeamWeaver.Provider.Registry.register/2`. Then `"acme:support-1"` works
wherever a model string does.

## Reference

- [`BeamWeaver.Models`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.html): model strings, `init_chat_model/2` and friends
- [`BeamWeaver.Models.Profile`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.Profile.html): what a model supports
- [`BeamWeaver.Provider.Compatibility`](https://hexdocs.pm/beam_weaver/BeamWeaver.Provider.Compatibility.html): feature checks across providers and models
- [`BeamWeaver.Provider.Registry`](https://hexdocs.pm/beam_weaver/BeamWeaver.Provider.Registry.html): registered providers
- [`BeamWeaver.Provider.Adapter`](https://hexdocs.pm/beam_weaver/BeamWeaver.Provider.Adapter.html): behaviour for your own provider
- [`BeamWeaver.Core.ChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.ChatModel.html): behaviour every chat model implements
- [`BeamWeaver.Agent.Middleware.ModelFallback`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ModelFallback.html): backup models
