# BeamWeaver Core

BeamWeaver core defines the structs and behaviours shared by providers and the
runtime.

## Values

- `BeamWeaver.Core.Message`: chat messages with roles `:system`, `:user`,
  `:assistant`, and `:tool`.
- `BeamWeaver.Core.Document`: text documents for retrieval and data processing.

## Behaviours

- `BeamWeaver.Core.ChatModel`
- `BeamWeaver.Core.EmbeddingModel`
- `BeamWeaver.Core.LLM`
- `BeamWeaver.Core.Tool`

Public helpers validate inputs and returned shapes before provider-specific code
can claim success. Recoverable failures return tagged `BeamWeaver.Core.Error`
values.

## Async

Core model wrappers expose Task-backed async helpers:

```elixir
task = BeamWeaver.Core.ChatModel.async_invoke(model, messages)
{:ok, message} = BeamWeaver.Core.Async.await(task)
```

Batch helpers return ordered task lists, so awaiting the list preserves caller
input order even when work completes out of order.

## Chat History

Chat history is an explicit adapter contract. Use ETS for local/test sessions or
Memory-backed sessions when history should share the same store interface as
graphs and agents:

```elixir
history = BeamWeaver.Core.ChatHistory.ETS.new()
session = BeamWeaver.Core.ChatHistory.ETS.for_session(history, "thread-1")

:ok = BeamWeaver.Core.ChatHistory.add_user_message(session, "hello")
:ok = BeamWeaver.Core.ChatHistory.add_ai_message(session, "world")
{:ok, messages} = BeamWeaver.Core.ChatHistory.get_messages(session)
```

`async_get_messages/2`, `async_add_messages/3`, `async_add_message/3`, and
`async_clear/2` use the same Task-backed async helpers as model wrappers.

## Related Guides

- [Messages](messages.md)
- [Tools](tools.md)
- [Models](models.md)
- [Adapters](adapters.md)
