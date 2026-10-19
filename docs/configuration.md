# Configuration

Keep provider credentials and deployment defaults in your application's
runtime configuration. Put model behavior on model constructors/declarations,
and request identity/state selection on invocation options. A dependency's
config files do not configure a consuming application.

## Configuration and call options

Create `config/runtime.exs` in the application that runs the agent:

```elixir
import Config
config :beam_weaver, :openai, api_key: System.fetch_env!("OPENAI_API_KEY")
```

Export the credential before starting Mix or load it through your deployment
secret mechanism. BeamWeaver reads application configuration; it does not
implicitly load a consumer's `.env`.

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000)
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Reply with a brief greeting.")
true = byte_size(BeamWeaver.Core.Message.text(reply)) > 0
```

| Setting | Belongs in |
| --- | --- |
| Provider key and base URL | Provider application group or explicit constructor options |
| Model, output limit and reasoning controls | Model constructor/agent declaration |
| Thread ID and checkpoint selection | Invocation `config:` |
| Authenticated caller and request dependencies | Invocation `context:` |
| Saver/store/cache | Application-owned resource passed to the run |
| Retry and tool policy | Middleware or node options |
| Whole-run and step budgets | Agent/graph declaration or invocation options |

`BeamWeaver.Config` reads grouped settings and treats blank strings as missing.
APIs using `BeamWeaver.Config.option/4` let an explicit option win, including explicit nil.
Endpoint constructors may have additional empty-value fallback rules. Use the
specific API's documented options rather than inventing global feature keys.

## Provider groups

| Group | Credentials and connection settings |
| --- | --- |
| `:openai` | `api_key`, `organization`, `project`, `base_url` |
| `:google`, `:anthropic` | `api_key`, `base_url` |
| `:deepseek` | `api_key`, `base_url`, `beta_base_url`, `anthropic_base_url` |
| `:moonshot`, `:xai`, `:zai`, `:typesafe` | `api_key`, `base_url` |

The [provider guides](providers.md) cover operation-specific options and
endpoint differences. Default service URLs exist; default credentials do not.
A gateway URL does not make every native feature available through it.

## Your application's resources

Configure repos under your own OTP application name and supervise them before
storage users. Model initialization does not create an Ecto repo or migrate
its schema. [Storage](storage.md) contains complete setup.

Keep shared ETS resources, rate limiters and workspace owners alive for their
intended scope. Declaration evaluation is per-call; avoid creating a new
resource on every invocation. [Production Integration](going_to_production.md)
explains ownership and shutdown.

## Provider registration

The `:providers` setting accepts adapter modules or provider/spec pairs loaded
at startup. `BeamWeaver.Provider.Registry` supports explicit registration.
Custom adapters implement the appropriate chat, embedding or decision contract;
registering a prefix does not automatically implement those operations.

Agent `ProviderProfile` defaults and behavioral `CapabilityProfile` registries
are node-wide. Set shared policies at startup and pass request-specific
variations explicitly rather than mutating a registry per request.

## Tracing

Local trace retention defaults to 10,000 records, while active records are
retained even when that budget is exceeded. Zero retains only active runs:

```elixir
import Config
config :beam_weaver, :tracing, max_runs: 1_000
```

The `:tracing` group also accepts `exporter` and `exporter_opts`.
The `:weave_scope` group configures endpoint, key, version, OTP application and
queue behavior. Configure it before application startup.

| Queue setting | Default | Meaning |
| --- | --- | --- |
| `transport` | `Req` | HTTP implementation of `post/2` |
| `batch_size` | 200 | Observations per upload |
| `flush_interval` | 250 | Milliseconds between background flushes |
| `max_items` | 100,000 | Buffered observations |
| `max_batch_bytes` | 6,000,000 | Encoded upload limit |
| `max_inflight` | 2 | Concurrent uploads |
| `overflow` | `:block` | Backpressure; drop-oldest/newest alternatives trade data for availability |
| `retry_delay`, `backoff`, `jitter` | 100 ms, 2.0, 0.0 | Upload retry timing |
| `max_attempts` | 5 | Attempts before dead-letter handling |
| `shutdown` | 120,000 | Milliseconds allowed for shutdown drain |
| `redactor` | Built-in credential redaction | Pre-export data transformation |

[Tracing](tracing.md) explains delivery checks, queue monitoring and the
limits of redaction. A large buffer remains in-memory and is not durable
storage for an extended outage.

## Transport pools

The `:transport` group accepts `max_isolated_pools` (default 16) and
`isolated_pool_idle_timeout` (default 60,000 ms). Both must be positive integers.
These bound isolated origin/settings pools, such as validated URL fetches.
Ordinary provider request timeouts belong on the model/transport request.

## Execution

`:execution` accepts `delta_max_supersteps_since_snapshot` (default 5,000)
for delta replay between snapshots. Per-run recursion/time limits remain
agent/graph options. See [State and Channels](graph_state.md) and
[Durable Execution](durable_execution.md).

Repository-only `:test` and `:examples` settings support development scripts.
Use explicit test arguments, fakes and application configuration for your own
behavior; do not make production correctness depend on runner settings.
