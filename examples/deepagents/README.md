# BeamWeaver DeepAgents Port Examples

Elixir ports of the upstream Python DeepAgents examples. They use BeamWeaver's
normal composed agent surface — there is no separate DeepAgent type or runtime
mode; planning, filesystem, subagents, memory, and tracing are ordinary tools,
middleware, state, and runtime options.

The examples run against a **live provider model**. Set a provider API key and,
optionally, the model to use, then run any example from the project root:

```bash
export OPENAI_API_KEY=sk-...                 # or ANTHROPIC_API_KEY / GOOGLE_API_KEY / XAI_API_KEY / KIMI_API_KEY
export BEAM_WEAVER_EXAMPLES_MODEL=openai:gpt-5.4-mini   # default; switch provider/model here
mix run examples/deepagents/deep_research.exs
```

`BEAM_WEAVER_EXAMPLES_MODEL` selects the provider and model for every example
(top-level and DeepAgents); the matching provider key is read from the
environment. The same applies to the top-level `examples/*.exs`.

## Port Map

| Upstream example | BeamWeaver port |
|---|---|
| `async-subagent-server/` | `async_subagent_server.exs` |
| `better-harness/` | `better_harness.exs` |
| `content-builder-agent/` | `content_builder_agent.exs` |
| `deep_research/` | `deep_research.exs` |
| `deploy-coding-agent/` | `deploy_coding_agent.exs` |
| `deploy-content-writer/` | `deploy_content_writer.exs` |
| `deploy-gtm-agent/` | `deploy_gtm_agent.exs` |
| `deploy-mcp-docs-agent/` | `deploy_mcp_docs_agent.exs` |
| `downloading_agents/` | `downloading_agents.exs` |
| `llm-wiki/` | `llm_wiki.exs` |
| `nvidia_deep_agent/` | `nvidia_deep_agent.exs` |
| `ralph_mode/` | `ralph_mode.exs` |
| `repl_swarm/` | `repl_swarm.exs` |
| `rlm_agent/` | `rlm_agent.exs` |
| `text-to-sql-agent/` | `text_to_sql_agent.exs` |
