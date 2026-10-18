# Installation

BeamWeaver runs inside an Elixir application. You need Elixir 1.19 or later,
a working Mix installation, and a provider API key for live model calls.
A database is optional until you need persistence across application restarts.

## Release status

These guides target **BeamWeaver 1.0.0**. The dependency below is the release
target; it will resolve from Hex after 1.0.0 is published. Testing a locally
built package does not verify availability in the public registry.

## Create an application

```bash
mix new my_app --sup
cd my_app
```

Add BeamWeaver to the dependency list in `mix.exs`:

```elixir
def deps do
  [{:beam_weaver, "~> 1.0.0"}]
end
```

Then install dependencies:

```bash
mix deps.get
```

Mix starts BeamWeaver with your application's dependencies. You do not need
to add BeamWeaver to your supervision tree. Resources you create yourself,
such as an Ecto repository, still belong in your application's supervision tree.

## Configure OpenAI

Create the `config` directory and `config/runtime.exs`. The following is the
complete runtime configuration for the quickstart:

```elixir
import Config

config :beam_weaver, :openai, api_key: System.fetch_env!("OPENAI_API_KEY")
```

Set `OPENAI_API_KEY` in the environment of the process that runs your app.
Keep its value out of source control. BeamWeaver reads **application
configuration**; your application is responsible for loading credentials.
A dependency's `config/runtime.exs` is not loaded into a consuming application.

## Use Google instead

Configure Google's Gemini Developer API in the same file:

```elixir
import Config

config :beam_weaver, :google, api_key: System.fetch_env!("GOOGLE_API_KEY")
```

Set `GOOGLE_API_KEY`, then use a `google:` model in your agent. The
[Quickstart](quickstart.md#use-google) includes a complete alternative.
Other providers have their own [setup guides](providers.md).

## Configure the formatter

Add `import_deps: [:beam_weaver]` to your `.formatter.exs` keyword list. This
keeps DSL declarations such as `model "..."` and `field :id, :string` without
parentheses when you run `mix format`.

## Check installation

Start your application:

```bash
iex -S mix
```

At the prompt, initialize a model. This checks the identifier and options;
it does **not** send a request or establish that the API key is valid:

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini")
model.model
#=> "gpt-5.4-mini"
```

Continue to the [Quickstart](quickstart.md) to make a real request, then
[Build an Agent](tutorial.md) to give the model a tool.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Hex cannot find `~> 1.0.0` | The release must be published before these release-targeted instructions resolve. |
| Missing API key | Configure the provider in **your application's** `config/runtime.exs`, set the key, and restart IEx. |
| Authentication failure | Check the key and the account/project it belongs to. Successful model initialization is not authentication. |
| Unknown or unavailable model | Check the provider's access rules and the model identifiers in [Models](models.md). |
| Rate limit | Check account limits and use the policies in [Rate Limiting](rate_limiting.md). |
| State disappears between calls | Reuse a checkpointer and thread ID; see [Short-Term Memory](short_term_memory.md). |
