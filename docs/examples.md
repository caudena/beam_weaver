# Runnable Examples

The guides contain complete inline examples, including setup, invocation and
observable results. The downloadable scripts below are optional companion files. Start with
[Your First Agent](quickstart.md) and [Build a Support Agent](tutorial.md) if
you are new to the library.

## Find an inline example

| Task | Complete guide examples |
| --- | --- |
| Create an agent and give it an order tool | [Support-agent tutorial](tutorial.md) |
| Validate inputs, update state, return artifacts | [Tools](tools.md) |
| Retry, select tools, bound calls and redact data | [Built-in Middleware](builtin_middleware.md) |
| Stream to a UI and handle tool progress | [Streaming](streaming.md) |
| Approve, edit, reject or review each call | [Human Review](human_in_the_loop.md) |
| Delegate, capture output and manage async work | [Subagents](subagents.md) |
| Read and write files; run commands | [Filesystem](filesystem.md), [Sandboxes](sandboxes.md) |
| Persist conversations and customer preferences | [Conversation History](short_term_memory.md), [Long-Term Memory](long_term_memory.md) |
| Search documents with real embeddings | [Retrieval](retrieval.md) |
| Route, join and improve work in bounded loops | [Workflow Patterns](workflow_patterns.md) |
| Replay, fork or recover a saved workflow | [Checkpoints](checkpoints.md), [Durable Execution](durable_execution.md) |
| Configure databases and migrations | [Storage](storage.md) |
| Trace and export actual runs | [Tracing](tracing.md) |

## Run an example

From a repository checkout, install dependencies and configure a provider key
in your environment or the checkout's untracked `.env`. The example runner
loads that file; a consuming application configures credentials itself.

```bash
mix deps.get
mix examples.live --model openai:gpt-5.4-mini --only examples/react_agent.exs
mix examples.live --provider google --only examples/streaming_agent.exs
```

The weather example calls a local fixture tool with a real model. It proves
the model/tool integration, not access to a weather service. Script comments
identify fixture-backed business tools and required external resources.

| Provider | Credential variables |
| --- | --- |
| OpenAI | `OPENAI_API_KEY` |
| Anthropic | `ANTHROPIC_API_KEY` |
| Google | `GOOGLE_API_KEY` or `GEMINI_API_KEY` |
| xAI | `XAI_API_KEY` |
| DeepSeek | `DEEPSEEK_API_KEY` |
| Moonshot | `MOONSHOT_API_KEY` or `KIMI_API_KEY` |
| Z.ai | `ZAI_API_KEY` |
| TypeSafe | `TYPESAFE_API_KEY` or `TYPESAFE_API` |

Choose models explicitly with `--model`; use `--provider` for runner defaults.
TypeSafe runs decision-specific examples rather than generic chat scripts.
Some scripts require more than one provider, as stated in their setup.

## Run a selection or the full matrix

```bash
mix examples.live --provider openai,google
mix examples.live --provider openai --offline
mix examples.live --provider moonshot --only deepagents/ --timeout 600
mix examples.live
```

The unfiltered command requests every manifest provider and fails for missing
credentials. `--jobs` controls concurrency and `--timeout` is seconds per
script. Generic live scripts run across applicable chat providers; pinned
scripts use their actual provider. Offline scripts exercise local behavior.
Transient provider failures can receive one bounded retry; failed behavioral
assertions are not silently converted into passes.

## Understand verification results

Each run retains per-attempt logs, JSON results and provider HTTP evidence
under `_build/examples_live/runs/`. A successful process exit is insufficient:
a live example must receive a successful inference response from its required
provider and pass its behavioral assertions. Unconsumed streams, constructors,
model lists and fixtures cannot substitute for inference.

Tool assertions check successful results and relevant arguments. Other checks
cover structured answers, streamed events, approval/resume, saved memory and
actual files. A provider response alone does not establish all those behaviors.

The existing `mix docs.verify --all` command additionally executes guide and
inline API examples and a fresh consumer of the built package. Use `--only`
for a page/script substring, `--scenario` for a scenario, `--provider` or
`--model` for provider/model selection and `--service postgres,docker` for
service requirements. Missing prerequisites remain incomplete in reports.
Public Hex installation is separate and remains pending until the target
release is published and installed successfully.

## Agents and tools

| Example | What it shows | Runs |
|---|---|---|
| [react_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/react_agent.exs) | An agent calls a tool and answers from the result | live |
| [tool_injected_args.exs](https://github.com/caudena/beam_weaver/blob/master/examples/tool_injected_args.exs) | A tool receives the agent state and run context the model never sees | live |
| [structured_output_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/structured_output_agent.exs) | Look an order up with a tool, then answer as a map matching a schema | live |
| [streaming_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/streaming_agent.exs) | Print tokens and tool calls while the agent runs | live |
| [hitl_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/hitl_agent.exs) | Pause before a refund, approve it, resume from a checkpoint | live |
| [Per-call review](human_in_the_loop.md#one-pause-per-call) | Review each refund on its own while lookups run; answer the refunds one at a time | live |
| [chat_model.exs](https://github.com/caudena/beam_weaver/blob/master/examples/chat_model.exs) | Call a chat model directly, without an agent | live |
| [prompt_caching.exs](https://github.com/caudena/beam_weaver/blob/master/examples/prompt_caching.exs) | Compare reported cache-read tokens across repeated live calls | live |

## Memory, subagents and deep agents

| Example | What it shows | Runs |
|---|---|---|
| [file_memory.exs](https://github.com/caudena/beam_weaver/blob/master/examples/file_memory.exs) | Memory in an `AGENTS.md` file the agent edits with file tools | live |
| [long_term_memory.exs](https://github.com/caudena/beam_weaver/blob/master/examples/long_term_memory.exs) | Memories as store records per user, ETS or Postgres (`--ecto`) | live |
| [subagent_supervisor.exs](https://github.com/caudena/beam_weaver/blob/master/examples/subagent_supervisor.exs) | A supervisor hands work to a summarizer subagent | live |
| [deep_agent_composition.exs](https://github.com/caudena/beam_weaver/blob/master/examples/deep_agent_composition.exs) | To-do planning, files, a writer subagent, compaction and retries in one agent | live |
| [async_subagent_protocol_client.exs](https://github.com/caudena/beam_weaver/blob/master/examples/async_subagent_protocol_client.exs) | The requests an async subagent sends to a remote agent server | offline |

The [deepagents/](https://github.com/caudena/beam_weaver/tree/master/examples/deepagents)
folder holds 15 more live deep agents: research with subagents, a coding agent
with write permissions, text-to-SQL, a wiki keeper, a swarm of parallel
workers, a recursive agent, async subagents and more. Its
[README](https://github.com/caudena/beam_weaver/blob/master/examples/deepagents/README.md)
lists each one with the tools it must call.

## Graphs

| Example | What it shows | Runs |
|---|---|---|
| [basic_graph.exs](https://github.com/caudena/beam_weaver/blob/master/examples/basic_graph.exs) | A one-node graph in a graph module | offline |
| [branching_waiting_graph.exs](https://github.com/caudena/beam_weaver/blob/master/examples/branching_waiting_graph.exs) | Route with a command and fan out with sends | offline |
| [durable_interrupt_resume_graph.exs](https://github.com/caudena/beam_weaver/blob/master/examples/durable_interrupt_resume_graph.exs) | Pause a graph for input and resume it from a checkpoint | offline |
| [research_pipeline_graph.exs](https://github.com/caudena/beam_weaver/blob/master/examples/research_pipeline_graph.exs) | Node dependencies, conditions and bounded revision loops | offline |

## Retrieval, streaming and sandboxes

| Example | What it shows | Runs |
|---|---|---|
| [retrieval_indexing_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/retrieval_indexing_agent.exs) | Split documents into a vector store and give an agent a search tool, with fake embeddings | offline |
| [streaming_redaction.exs](https://github.com/caudena/beam_weaver/blob/master/examples/streaming_redaction.exs) | Redact email addresses from a message stream | offline |
| [streaming_tool_call_chunks.exs](https://github.com/caudena/beam_weaver/blob/master/examples/streaming_tool_call_chunks.exs) | Rebuild tool calls from streamed chunks | offline |
| [interpreter_adapter.exs](https://github.com/caudena/beam_weaver/blob/master/examples/interpreter_adapter.exs) | A custom interpreter with snapshot and restore | offline |
| [sandbox_provider_registry.exs](https://github.com/caudena/beam_weaver/blob/master/examples/sandbox_provider_registry.exs) | Register a sandbox provider and run a command | offline |

## Provider features

| Example | What it shows | Runs |
|---|---|---|
| [openai_responses_tool_roundtrip.exs](https://github.com/caudena/beam_weaver/blob/master/examples/openai_responses_tool_roundtrip.exs) | A streamed tool round trip on the Responses API | offline; OpenAI with `--live` |
| [openai_apply_patch_tool.exs](https://github.com/caudena/beam_weaver/blob/master/examples/openai_apply_patch_tool.exs) | The `apply_patch` tool request and replay | offline |
| [openai_json_http_error.exs](https://github.com/caudena/beam_weaver/blob/master/examples/openai_json_http_error.exs) | Provider error details kept on an HTTP error | offline |
| [openai_gpt6_controls.exs](https://github.com/caudena/beam_weaver/blob/master/examples/openai_gpt6_controls.exs) | Access programs and cache prewarming | OpenAI |
| [Auto mode](guardrails.md#block-risky-tool-calls) | GPT-6 Luna permits a requested fixture deletion call and blocks an unrequested one | OpenAI |
| [anthropic_opus55_compaction.exs](https://github.com/caudena/beam_weaver/blob/master/examples/anthropic_opus55_compaction.exs) | Server-side compaction and its replay | Anthropic |
| [deepseek.exs](https://github.com/caudena/beam_weaver/blob/master/examples/deepseek.exs) | Chat, Responses, fill-in-the-middle and the Anthropic-style endpoint | DeepSeek |
| [typesafe_dynamic_routing.exs](https://github.com/caudena/beam_weaver/blob/master/examples/typesafe_dynamic_routing.exs) | Route each request to a fast or a strong model with a classifier | TypeSafe and OpenAI; `--offline` |
| [Z.ai media](providers/zai.md#images-video-and-pdfs) | Send an image, a PDF and a video to GLM-5.3-Flash | Z.ai |

## Choose a useful integration check

Use the actual provider/model, storage adapter and execution backend that you
deploy. For media examples, use the bundled fixtures and create/delete remote
resources as the script demonstrates. For retrieval, assert expected sources
with real embeddings. For caching, inspect observed cache reads; zero is not
a cache hit. For generated work, inspect the actual artifact.

[Testing Your Application](testing.md) covers deterministic application tests;
[Production Integration](going_to_production.md) covers deployment ownership.
