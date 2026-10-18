# Deep agent examples

A deep agent is an ordinary BeamWeaver agent with planning, files, skills,
memory and subagents turned on. Each script here builds one with
`BeamWeaver.Agent.build/1` and runs it against a live model. At the end it
checks that the agent called the tools the example is about, and fails if not.

```bash
mix examples.live --model openai:gpt-5.4-mini --only examples/deepagents/deep_research.exs
```

The files an agent reads and writes live in
`<tmp>/beam_weaver_examples/<provider>/deepagents/<example>/`, and every run
starts from a fresh copy. Tools that would reach the outside world (web
search, a database, a remote agent server) return canned data, so runs are
repeatable.

`support/support.exs` adds what all of them share:

- four-minute timeouts on every graph node, for slow providers (the tools
  node runs whole subagent conversations);
- at most 16 model calls and 24 tool calls per run (`ModelCallLimit` and
  `ToolCallLimit`), so a looping model stops early;
- a recursion limit of 120 graph steps as a backstop (a deep agent runs about
  seven graph steps per model turn);
- `assert_tools_called!/2`, the check at the end of each script.

| Script | What it shows | Must call |
|---|---|---|
| `async_subagent_server.exs` | Start a task on a remote agent server and check on it later | `start_async_task`, `check_async_task` |
| `better_harness.exs` | Tune another agent's prompt file and run its evals; writes allowed only to declared files | `edit_file` or `write_file`, `run_evals` |
| `content_builder_agent.exs` | Brand memory, writing skills, a researcher subagent and a cover-image tool | `generate_cover`, `write_file` |
| `deep_research.exs` | A research lead that hands each question to a researcher subagent with web search | `task` |
| `deploy_coding_agent.exs` | Fix a failing test in a project on disk; writes allowed under `/workspace` only | `read_file`, `edit_file` or `write_file` |
| `deploy_content_writer.exs` | Two memory files (team policy and user preferences) shape a saved draft | `write_file` |
| `deploy_gtm_agent.exs` | A subagent in the conversation plus an async subagent in the background | `task`, `start_async_task` |
| `deploy_mcp_docs_agent.exs` | Answer from a docs search tool and cite the pages | `search_docs` |
| `downloading_agents.exs` | An agent shipped as a folder: `AGENTS.md` plus skills | `write_file` |
| `llm_wiki.exs` | Keep a Markdown wiki: search it, add a note, answer from it | `wiki_query`, `edit_file` or `write_file` |
| `nvidia_deep_agent.exs` | Data-analysis skills, a data-processor subagent, and run context that reaches its tool | `task` |
| `ralph_mode.exs` | The same prompt in fresh conversations; progress carries over only in files | `write_file` or `edit_file` |
| `repl_swarm.exs` | Fan per-file work out to parallel workers with a swarm skill; the coordinator may read only its skills | `task` |
| `rlm_agent.exs` | A recursive agent whose subagent is another copy of itself, one level down | `task` |
| `text_to_sql_agent.exs` | Inspect tables, run a read-only query, answer from the rows | `execute_query` |

See [docs/examples.md](../../docs/examples.md) for the other examples and for
`mix examples.live`, which runs these on explicitly selected providers and fails when a required key is missing.
