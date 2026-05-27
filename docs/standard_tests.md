# BeamWeaver Conformance Tests

BeamWeaver conformance tests are shared ExUnit cases translated from the
behavioral shape of LangChain standard tests. They are intentionally
BeamWeaver-native: providers and adapters implement behaviours, then shared
cases exercise them through public Elixir wrappers.

Implemented shared cases include:

- `BeamWeaver.TestSupport.Conformance.ChatModelCase`
- `BeamWeaver.TestSupport.Conformance.EmbeddingModelCase`
- `BeamWeaver.TestSupport.Conformance.ToolCase`
- `BeamWeaver.TestSupport.Conformance.LLMCase`
- `BeamWeaver.TestSupport.Conformance.CacheCase`
- `BeamWeaver.TestSupport.Conformance.ChatHistoryCase`
- `BeamWeaver.TestSupport.Conformance.DocumentLoaderCase`
- `BeamWeaver.TestSupport.Conformance.TextSplitterCase`
- `BeamWeaver.TestSupport.Conformance.VectorStoreCase`
- `BeamWeaver.TestSupport.Conformance.RecordManagerCase`
- `BeamWeaver.TestSupport.Conformance.IndexingCase`
- `BeamWeaver.TestSupport.Conformance.RetrieverCase`
- `BeamWeaver.TestSupport.Conformance.AgentCase`

Example:

```elixir
defmodule MyProvider.ChatModelTest do
  use BeamWeaver.TestSupport.Conformance.ChatModelCase,
    subject: %BeamWeaver.TestSupport.Conformance.Subject{
      module: {MyProvider.ChatModel, model: "example"}
    }
end
```

Runtime code should depend on behaviours and adapters, not the test support
modules. Conformance cases live under `support/conformance` and are test-only.

Run:

```bash
mix test test/beam_weaver/conformance
mix test test/beam_weaver/checkpoint/conformance_test.exs
mix test test/beam_weaver/memory/conformance_test.exs
```

## Related Guides

- [Core](core.md)
- [Adapters](adapters.md)
- [Replay](replay.md)
