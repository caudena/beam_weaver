# Configuration

Configure BeamWeaver in your application's `config/runtime.exs`. Keep
credentials there and pass request-specific values as invocation options.
An installed dependency's own configuration files do not configure your app.

## Configuration and call options

A provider's application configuration supplies credentials and connection
defaults. Model constructors and invocation options carry the settings for
that model or request. For example, `max_tokens` belongs on a model, while a
thread ID belongs on an invocation; neither is a global `:beam_weaver` key.

```elixir
import Config

config :beam_weaver, :openai,
  api_key: System.fetch_env!("OPENAI_API_KEY")
```

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000)
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Reply with the word ready.")
true = byte_size(BeamWeaver.Core.Message.text(reply)) > 0
```

[`BeamWeaver.Config`](https://hexdocs.pm/beam_weaver/BeamWeaver.Config.html)
reads grouped application configuration. Blank strings are treated as missing.
Where an API uses `BeamWeaver.Config.option/4`, an explicitly supplied option wins over
application configuration, including an explicit `nil`. Check the constructor
reference for its supported options; provider-specific URL resolution may
apply its own fallback for an empty endpoint.

## Provider groups

| Group | Credentials and connection options | Guide |
| --- | --- | --- |
| `:openai` | `api_key`, `organization`, `project`, `base_url` | [OpenAI](providers/openai.md) |
| `:google` | `api_key`, `base_url` | [Google](providers/google.md) |
| `:anthropic` | `api_key`, `base_url` | [Anthropic](providers/anthropic.md) |
| `:deepseek` | `api_key`, `base_url`, `beta_base_url`, `anthropic_base_url` | [DeepSeek](providers/deepseek.md) |
| `:moonshot` | `api_key`, `base_url` | [Moonshot](providers/moonshot.md) |
| `:xai` | `api_key`, `base_url` | [xAI](providers/xai.md) |
| `:zai` | `api_key`, `base_url` | [Z.ai](providers/zai.md) |
| `:typesafe` | `api_key`, `base_url` | [TypeSafe](providers/typesafe.md) |

Provider clients use their built-in service URL unless you configure a
replacement. API keys have no built-in default. A custom URL is useful for
a gateway; it does not imply that every gateway supports the provider's
features. Never embed keys in agent modules or log them with request options.

## Tracing

Local run storage retains up to 10,000 finished/running records by default;
running records are retained even when the limit is exceeded. `max_runs: 0`
retains only active runs. Configure a different retention count:

```elixir
import Config

config :beam_weaver, :tracing, max_runs: 1_000
```

The `:tracing` group also accepts `exporter` and `exporter_opts` for a custom
exporter. The `:weave_scope` group configures the built-in WeaveScope exporter:
`endpoint`, `api_key`, `version` and `otp_app` identify the destination and
application version. Configure these before application startup so the
export queue starts with the intended settings. See [Tracing](tracing.md)
for delivery, redaction and exporter examples.

Queue settings also belong in `:weave_scope` and are read at startup:

| Key | Default | Meaning |
| --- | --- | --- |
| `transport` | `Req` | HTTP transport implementing `post/2`. |
| `batch_size` | `200` | Maximum observations per batch. |
| `flush_interval` | `250` | Milliseconds between background flushes. |
| `max_items` | `100_000` | Buffered observations before overflow handling. |
| `max_batch_bytes` | `6_000_000` | Maximum encoded batch size. |
| `max_inflight` | `2` | Concurrent uploads. |
| `overflow` | `:block` | Backpressure; alternatives are `:drop_oldest` and `:drop_newest`. |
| `retry_delay` | `100` | Initial retry delay in milliseconds. |
| `backoff` | `2.0` | Retry delay multiplier. |
| `jitter` | `0.0` | Retry jitter. |
| `max_attempts` | `5` | Upload attempts before a dead letter. |
| `shutdown` | `120_000` | Milliseconds allowed to drain during shutdown. |
| `redactor` | Built-in credential redaction | Function applied before export. |


## Transport pools

The `:transport` group controls isolated connection pools:

| Key | Default | Meaning |
| --- | --- | --- |
| `max_isolated_pools` | `16` | Maximum isolated origin/settings pools. |
| `isolated_pool_idle_timeout` | `60_000` | Milliseconds before an idle pool is stopped. |

Both values must be positive integers. Configure them before startup.
Normal model timeouts, retries and connection options are configured through
the model or transport API, not by inventing additional application keys.

## Execution

The `:execution` key `delta_max_supersteps_since_snapshot` defaults to `5_000`.
It limits delta replay between snapshots. Per-run limits such as
`recursion_limit`, `step_timeout` and `run_timeout` belong on the agent/graph
or its invocation. See [Durable Execution](durable_execution.md) and
[Graph State](graph_state.md).

## Provider registration

The `:providers` group accepts provider adapter modules or provider/spec pairs.
BeamWeaver loads these registrations during application startup. For explicit
runtime registration use
[`BeamWeaver.Provider.Registry`](https://hexdocs.pm/beam_weaver/BeamWeaver.Provider.Registry.html).
Custom models implement the appropriate chat, embedding or decision contract;
see [Models](models.md).

## Your application's resources

Configure Ecto repositories under your own application's OTP name. Supply
checkpointers, memory stores and caches explicitly to the agent or graph.
They are not global provider settings. [Storage](storage.md) covers repository
startup, migrations, serialization and retention.

The repository's `:test` and `:examples` groups support development scripts;
they are not application feature switches. Test selection uses Mix command
arguments. In tests, use explicit constructor arguments, fake models or your
application's configuration to choose behavior.
