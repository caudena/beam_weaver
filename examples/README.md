# Examples

Runnable scripts for BeamWeaver features, from a one-tool agent to deep agents
with subagents and files. Run them from the project root:

```bash
export OPENAI_API_KEY=...
mix run examples/react_agent.exs
```

`BEAM_WEAVER_EXAMPLES_MODEL` picks the provider and model (default
`openai:gpt-5.4-mini`), and the scripts read that provider's key from the
environment. Offline scripts need no key. `mix examples.live` runs every live
script on every provider you have a key for.

The full list, grouped by topic, is in [docs/examples.md](../docs/examples.md).
The deep agent examples are described in [deepagents/README.md](deepagents/README.md).
