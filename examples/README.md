# Runnable BeamWeaver examples

Start with the [Quickstart](../docs/quickstart.md) and
[Build an Agent](../docs/tutorial.md) if you are new to the library. These
scripts are complete runs with explicit setup and outcome checks: tool calls, streaming, human review,
state, retrieval, graphs, persistence and longer agent workflows.

Run commands from a repository checkout after `mix deps.get`. Set provider
credentials in your environment or the checkout's untracked `.env` file.
Choose the model explicitly through the runner:

```bash
mix examples.live --model openai:gpt-5.4-mini --only examples/react_agent.exs
mix examples.live --provider google --only examples/streaming_agent.exs
mix examples.live --provider openai --offline
```

Each requested provider must have credentials. A missing key is a failure,
not an omitted test. Provider-specific scripts run only on their declared
provider; generic scripts use the selected model. Offline scripts need no
model API. See [the example index](../docs/examples.md) for prerequisites and
the behavior each script checks.

The runner gives scripts isolated temporary directories and writes a JSON
report, per-attempt logs and HTTP evidence under `_build/examples_live/runs/`.
A live run must receive a successful inference response from its selected
provider. Fixtures and unconsumed streams cannot satisfy that check. Evidence
records endpoint, model and HTTP status; credentials and request bodies are
not recorded.

Tool checks require successful results, not merely requested calls. Examples
also check relevant arguments, structured values, streamed output, approval
interrupts and generated files. Some business tools intentionally use local
fixtures (such as weather, search or an async server); the script header says
so. These verify the model integration and tool workflow, not the external
system represented by that fixture. Cache examples report observed hit counts;
zero does not establish a cache hit.

```bash
mix docs.verify --all
```

The full documentation verifier executes guide and API examples, the scripts,
and a fresh consumer of the built package. Reports distinguish execution from
missing prerequisites and retain the pending public Hex installation check
until release. The [example index](../docs/examples.md#understand-verification-results)
explains selectors and report contents.
