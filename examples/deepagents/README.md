# BeamWeaver DeepAgents Examples

Elixir ports of the upstream Python DeepAgents examples. Each `.exs` file is
offline-safe by default: it uses `BeamWeaver.Agent.build/1` with native
capability options, fake models, local filesystem adapters, or in-memory stubs
so the example can run in tests without provider credentials.

Run an example from the BeamWeaver project root:

```bash
mix run examples/deepagents/deep_research.exs
```

To smoke-test against OpenAI instead of fake models:

```bash
set -a && . ./.env && set +a
BEAM_WEAVER_DEEPAGENTS_EXAMPLES_LIVE=true mix run examples/deepagents/deep_research.exs
```

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
