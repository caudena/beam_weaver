# Examples

The repository's `examples/` folder holds runnable scripts, from a one-tool
agent to deep agents with subagents, skills and files. Run one to see a
feature work end to end with a real model, or copy one as a starting point.

## Run an example

Clone the repository, export the key for your provider, and run a script from
the project root:

```bash
git clone https://github.com/caudena/beam_weaver.git
cd beam_weaver
mix deps.get
export OPENAI_API_KEY=...
mix run examples/react_agent.exs
```

```text
The weather in Nicosia is sunny and 25°C.
Tools called: get_weather
```

Each live script whose agent has tools ends by checking that the agent called
them, and fails if it did not. `BEAM_WEAVER_EXAMPLES_MODEL` picks the provider
and model (default `openai:gpt-5.4-mini`):

```bash
mix examples.live --model anthropic:claude-haiku-4-5 --only examples/react_agent.exs
```

| Provider | Key | Model in `mix examples.live` |
|---|---|---|
| OpenAI | `OPENAI_API_KEY` | `openai:gpt-5.4-mini` |
| Anthropic | `ANTHROPIC_API_KEY` | `anthropic:claude-haiku-4-5` |
| Google Gemini | `GOOGLE_API_KEY` or `GEMINI_API_KEY` | `google:gemini-3.5-flash` |
| xAI | `XAI_API_KEY` | `xai:grok-4.3` |
| Moonshot (Kimi) | `MOONSHOT_API_KEY` or `KIMI_API_KEY` | `moonshot:kimi-k2.6` |
| Z.ai | `ZAI_API_KEY` | `zai:glm-5.3-flash` |
| DeepSeek | `DEEPSEEK_API_KEY` | `deepseek:deepseek-flash` |
| TypeSafe | `TYPESAFE_API_KEY` or `TYPESAFE_API` | Decision-model scripts; no generic chat model |

Offline scripts need no key. [Testing](testing.md) introduces scripted fake
models; the [Quickstart](quickstart.md) uses a real provider.

## Run them all

`mix examples.live` requests every configured provider in its manifest and
fails if a requested provider has no key. Use `--provider` to select a subset.
It runs each applicable script and prints a pass/fail table. Keys come from the environment or a `.env`
file and are never printed. Each run keeps a JSON report, per-attempt logs and
HTTP evidence in `_build/examples_live/runs/`. A successful exit alone does not
pass a live run: the runner must observe a successful inference response from
each provider the example requires.

```bash
mix examples.live                              # every manifest provider; all keys required
mix examples.live --provider openai,anthropic  # only these providers
mix examples.live --model anthropic:claude-sonnet-4-6 --only deepagents/
```

`--offline` adds the offline scripts; `--jobs` and `--timeout` set concurrency
and seconds per script. A script that fails because the provider was briefly
over capacity or unreachable (a retryable rate limit, server error, lost
connection or timeout) runs once more after 15 seconds; a script that fails on
its own checks, such as a tool the model didn't call, does not. `mix test` compiles every script and runs the offline ones.

## Agents and tools

| Script | What it shows | Runs |
|---|---|---|
| [react_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/react_agent.exs) | An agent calls a tool and answers from the result | live |
| [tool_injected_args.exs](https://github.com/caudena/beam_weaver/blob/master/examples/tool_injected_args.exs) | A tool receives the agent state and run context the model never sees | live |
| [structured_output_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/structured_output_agent.exs) | Look an order up with a tool, then answer as a map matching a schema | live |
| [streaming_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/streaming_agent.exs) | Print tokens and tool calls while the agent runs | live |
| [hitl_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/hitl_agent.exs) | Pause before a refund, approve it, resume from a checkpoint | live |
| [hitl_per_call_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/hitl_per_call_agent.exs) | Review each refund on its own while lookups run; answer the refunds one at a time | live |
| [chat_model.exs](https://github.com/caudena/beam_weaver/blob/master/examples/chat_model.exs) | Call a chat model directly, without an agent | live |
| [prompt_caching.exs](https://github.com/caudena/beam_weaver/blob/master/examples/prompt_caching.exs) | Compare reported cache-read tokens across repeated live calls | live |

## Memory, subagents and deep agents

| Script | What it shows | Runs |
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

| Script | What it shows | Runs |
|---|---|---|
| [basic_graph.exs](https://github.com/caudena/beam_weaver/blob/master/examples/basic_graph.exs) | A one-node graph in a graph module | offline |
| [branching_waiting_graph.exs](https://github.com/caudena/beam_weaver/blob/master/examples/branching_waiting_graph.exs) | Route with a command and fan out with sends | offline |
| [durable_interrupt_resume_graph.exs](https://github.com/caudena/beam_weaver/blob/master/examples/durable_interrupt_resume_graph.exs) | Pause a graph for input and resume it from a checkpoint | offline |
| [research_pipeline_graph.exs](https://github.com/caudena/beam_weaver/blob/master/examples/research_pipeline_graph.exs) | Node dependencies, conditions and bounded revision loops | offline |

## Retrieval, streaming and sandboxes

| Script | What it shows | Runs |
|---|---|---|
| [retrieval_indexing_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/retrieval_indexing_agent.exs) | Split documents into a vector store and give an agent a search tool, with fake embeddings | offline |
| [streaming_redaction.exs](https://github.com/caudena/beam_weaver/blob/master/examples/streaming_redaction.exs) | Redact email addresses from a message stream | offline |
| [streaming_tool_call_chunks.exs](https://github.com/caudena/beam_weaver/blob/master/examples/streaming_tool_call_chunks.exs) | Rebuild tool calls from streamed chunks | offline |
| [interpreter_adapter.exs](https://github.com/caudena/beam_weaver/blob/master/examples/interpreter_adapter.exs) | A custom interpreter with snapshot and restore | offline |
| [sandbox_provider_registry.exs](https://github.com/caudena/beam_weaver/blob/master/examples/sandbox_provider_registry.exs) | Register a sandbox provider and run a command | offline |

## Provider features

| Script | What it shows | Runs |
|---|---|---|
| [openai_responses_tool_roundtrip.exs](https://github.com/caudena/beam_weaver/blob/master/examples/openai_responses_tool_roundtrip.exs) | A streamed tool round trip on the Responses API | offline; OpenAI with `--live` |
| [openai_apply_patch_tool.exs](https://github.com/caudena/beam_weaver/blob/master/examples/openai_apply_patch_tool.exs) | The `apply_patch` tool request and replay | offline |
| [openai_json_http_error.exs](https://github.com/caudena/beam_weaver/blob/master/examples/openai_json_http_error.exs) | Provider error details kept on an HTTP error | offline |
| [openai_gpt6_controls.exs](https://github.com/caudena/beam_weaver/blob/master/examples/openai_gpt6_controls.exs) | Access programs and cache prewarming | OpenAI |
| [auto_mode_agent.exs](https://github.com/caudena/beam_weaver/blob/master/examples/auto_mode_agent.exs) | GPT-6 Luna lets a file deletion the user asked for run and blocks one nobody asked for | OpenAI |
| [anthropic_opus55_compaction.exs](https://github.com/caudena/beam_weaver/blob/master/examples/anthropic_opus55_compaction.exs) | Server-side compaction and its replay | Anthropic |
| [deepseek.exs](https://github.com/caudena/beam_weaver/blob/master/examples/deepseek.exs) | Chat, Responses, fill-in-the-middle and the Anthropic-style endpoint | DeepSeek |
| [typesafe_dynamic_routing.exs](https://github.com/caudena/beam_weaver/blob/master/examples/typesafe_dynamic_routing.exs) | Route each request to a fast or a strong model with a classifier | TypeSafe and OpenAI; `--offline` |
| [zai_media.exs](https://github.com/caudena/beam_weaver/blob/master/examples/zai_media.exs) | Send an image, a PDF and a video to GLM-5.3-Flash | Z.ai |

## Known provider limitations

- **Z.ai** GLM-5.3 models always think and reject `thinking: %{type: "disabled"}`;
  the examples set `reasoning_effort: "low"` instead on the models whose profile
  takes it. GLM-5.1 and older take no effort and think at their default.
- **xAI** `mix examples.live` uses `xai:grok-4.3`. With
  `xai:grok-4.20-0309-non-reasoning` (and, less often,
  `xai:grok-4.20-0309-reasoning`), deep agents sometimes say they saved a file
  without calling a write tool; the tool check catches it.
- **Kimi** thinks before every reply, so deep agents take minutes; add `--timeout 600`.

## Reference

- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): define, build and run agents
- [`BeamWeaver.Tool`](https://hexdocs.pm/beam_weaver/BeamWeaver.Tool.html): define tools as modules
- [`BeamWeaver.Agent.Middleware.ModelCallLimit`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ModelCallLimit.html): cap model calls per run or thread
- [`BeamWeaver.Agent.Middleware.ToolCallLimit`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ToolCallLimit.html): cap tool calls per run or thread
