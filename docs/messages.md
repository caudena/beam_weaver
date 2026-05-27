# Messages

Messages are the shared context unit for BeamWeaver models, agents, prompts,
tools, and graph state. A message carries:

- a role: `:system`, `:user`, `:assistant`, or `:tool`
- content: a string or a list of content blocks
- metadata: IDs, names, usage, provider response details, tool calls, artifacts,
  and server-side tool data

BeamWeaver keeps one persistent public message value:
`%BeamWeaver.Core.Message{}`. Role-specific constructors create that same struct.

{% hint style="info" %}
**One Message Struct**

LangChain's Python docs use separate classes such as `SystemMessage`,
`HumanMessage`, `AIMessage`, and `ToolMessage`. Python classes make that API
natural because runtime type checks and object inheritance are the normal
extension points. BeamWeaver uses a single `%BeamWeaver.Core.Message{}` with an
atom role because pattern matching, structs, protocols, and tagged results are
the native boundary. This keeps provider translation, graph state, checkpoint
serialization, and tool execution on one value model.
{% endhint %}

## Basic Usage

Create messages with `BeamWeaver.Core.Message` and pass them to any chat model:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5-nano")

messages = [
  Message.system("You are a helpful assistant."),
  Message.user("Hello, how are you?")
]

{:ok, response} = ChatModel.invoke(model, messages)
IO.puts(Message.text(response))
```

### Text Prompts

For a single standalone request, pass a string. The chat model boundary treats it
as a user message:

```elixir
{:ok, response} =
  BeamWeaver.Core.ChatModel.invoke(model, "Write a haiku about spring")
```

Use a text prompt when there is no conversation history, no system instruction,
and no multimodal input.

### Message Prompts

Use message lists for multi-turn conversations, system instructions, tool calls,
and multimodal content:

```elixir
alias BeamWeaver.Core.Message

messages = [
  Message.system("You are a poetry expert."),
  Message.user("Write a haiku about spring."),
  Message.assistant("Cherry blossoms bloom..."),
  Message.user("Make it shorter.")
]

{:ok, response} = BeamWeaver.Core.ChatModel.invoke(model, messages)
```

### Map Format

BeamWeaver can normalize OpenAI-style maps and role/content tuples through the
`BeamWeaver.Core.MessageLike` protocol:

```elixir
alias BeamWeaver.Core.Messages.Utils

{:ok, messages} =
  Utils.normalize([
    %{"role" => "system", "content" => "You are a poetry expert."},
    %{"role" => "user", "content" => "Write a haiku about spring."},
    {:assistant, "Cherry blossoms bloom..."}
  ])
```

Prefer constructors in new application code. Map normalization is useful at
transport boundaries, replay fixtures, migration paths, and user-supplied data
where the message shape arrives as plain JSON.

{% hint style="info" %}
**Map Lists At The Boundary**

LangChain accepts lists of raw dictionaries directly in many model calls.
BeamWeaver validates chat-model message lists as `%BeamWeaver.Core.Message{}`
values so provider modules receive one stable internal shape. Normalize raw
maps first with `Utils.normalize/1`, or use `Message.system/2`,
`Message.user/2`, `Message.assistant/2`, and `Message.tool/2` directly.
{% endhint %}

{% hint style="info" %}
**Role Names**

LangChain uses `human` and `ai` in some APIs and `user` and `assistant` in
provider-facing APIs. BeamWeaver stores `:user` and `:assistant`; the
normalizer accepts common aliases so imported histories and provider payloads
can be converted at the edge. Provider-specific roles, such as OpenAI's
`developer`, are represented as system messages with provider metadata and are
rendered by the provider request builder when that provider needs them.
{% endhint %}

## Message Roles

| Role | Constructor | Purpose |
|---|---|---|
| `:system` | `Message.system/2` | instructions that shape model behavior |
| `:user` | `Message.user/2` | user input, multimodal requests, or provider tool-result blocks |
| `:assistant` | `Message.assistant/2` | model output, tool calls, reasoning, usage, and response metadata |
| `:tool` | `Message.tool/2` | client-side tool execution results sent back to the model |

### System Messages

System messages are instructions or persistent context:

```elixir
alias BeamWeaver.Core.Message

messages = [
  Message.system("""
  You are a senior Elixir developer.
  Provide concise code examples and explain tradeoffs.
  """),
  Message.user("How do I create a supervised worker?")
]
```

Provider-specific prompt-cache or routing hints live in metadata or content
block metadata and are interpreted only by provider request builders that
understand them.

```elixir
Message.system([
  %{type: :text, text: "You analyze literary works."},
  %{type: :text, text: "<long source text>", metadata: %{cache_hint: :ephemeral}}
])
```

### User Messages

User messages represent user input. A plain string is enough for text:

```elixir
Message.user("What is machine learning?", id: "msg_123", name: "alice")
```

The `:name` field is preserved on the message and passed to providers that
accept it. Some providers ignore names or restrict characters, so keep names
short and provider-safe when they are model-visible.

For multimodal input, provide content blocks:

```elixir
alias BeamWeaver.Core.{ContentBlock, Message}

message =
  Message.user([
    ContentBlock.text("Describe this image."),
    ContentBlock.image(%{url: "https://example.com/path/to/image.jpg"})
  ])
```

### Assistant Messages

Assistant messages are model outputs. They may include text, content blocks,
tool calls, provider response metadata, and token usage:

```elixir
message =
  Message.assistant("I can help with that.",
    id: "msg_456",
    response_metadata: %{"model" => "gpt-5-nano", "finish_reason" => "stop"},
    usage_metadata: %{
      input_tokens: 8,
      output_tokens: 24,
      total_tokens: 32
    }
  )

Message.text(message)
message.usage_metadata
message.response_metadata
```

You can add an assistant message manually when restoring history:

```elixir
messages = [
  Message.system("You are helpful."),
  Message.user("Can you help me?"),
  Message.assistant("Yes. What do you need?"),
  Message.user("What is 2 + 2?")
]
```

#### Tool Calls

When a model requests client-side tool execution, tool calls are stored on the
assistant message:

```elixir
message =
  Message.assistant("",
    tool_calls: [
      %{id: "call_weather", name: "get_weather", args: %{"location" => "Paris"}}
    ]
  )

for call <- message.tool_calls do
  IO.inspect({Map.get(call, :name) || call["name"], Map.get(call, :args) || call["args"]})
end
```

Standalone model calls return tool-call requests. Agents execute the tool loop
for you.

#### Token Usage

Provider token accounting is stored in `message.usage_metadata` when returned:

```elixir
{:ok, response} = BeamWeaver.Core.ChatModel.invoke(model, "Hello!")

case response.usage_metadata do
  nil -> :provider_did_not_return_usage
  usage -> Map.get(usage, :total_tokens) || usage["total_tokens"]
end
```

For aggregate application usage, collect message usage maps directly or consume
BeamWeaver tracing and telemetry events.

{% hint style="info" %}
**Usage Metadata**

LangChain exposes usage aggregation through callback handlers and context
managers. BeamWeaver keeps usage on messages and emits telemetry/tracing
events from the call boundary. That fits supervised Elixir services better
than mutable callback objects shared across unrelated invocations.
{% endhint %}

### Tool Messages

Tool messages send the result of a client-side tool call back to the model. The
`tool_call_id` should match the assistant tool call:

```elixir
alias BeamWeaver.Core.Message

ai_message =
  Message.assistant("",
    tool_calls: [
      %{id: "call_123", name: "get_weather", args: %{"location" => "San Francisco"}}
    ]
  )

tool_message =
  Message.tool("Sunny, 72 F",
    tool_call_id: "call_123",
    name: "get_weather"
  )

messages = [
  Message.user("What is the weather in San Francisco?"),
  ai_message,
  tool_message
]
```

Tool outputs can keep downstream-only data in `:artifacts` while sending concise
content to the model:

```elixir
Message.tool("Found the relevant passage.",
  tool_call_id: "call_search",
  name: "search_books",
  artifacts: [%{document_id: "doc_123", page: 0}]
)
```

`BeamWeaver.Core.ToolResult` and `:content_and_artifact` tools populate the same
tool-message shape.

{% hint style="info" %}
**Artifacts**

LangChain's `ToolMessage` has an `artifact` field. BeamWeaver stores
downstream-only payloads as a list in `message.artifacts` because a tool call
can carry more than one useful application artifact over time. Provider
translators send `message.content` to the model and keep artifacts available
for application code, tracing, retrieval UIs, and checkpointed state.
{% endhint %}

## Message Content

Message content is either:

1. a string
2. a list of content-block-like values

Strings are best for ordinary text. Lists are best for multimodal input,
reasoning blocks, citations, tool results, server-side tool calls, and
provider-specific data.

```elixir
alias BeamWeaver.Core.{ContentBlock, Message}

text_message = Message.user("Hello, how are you?")

block_message =
  Message.user([
    ContentBlock.text("Describe this image."),
    ContentBlock.image(%{url: "https://example.com/image.jpg"}),
    %{type: :citation, url: "https://example.com/source", start_index: 0}
  ])
```

Use `Message.text/1` to extract text from strings and text-like blocks:

```elixir
Message.text(block_message)
```

Use `Message.content_blocks/1` to normalize content into typed BeamWeaver
blocks:

```elixir
{:ok, blocks} = Message.content_blocks(block_message)
```

{% hint style="info" %}
**Content Blocks Are Explicit**

LangChain's `content_blocks` property lazily parses provider-native Python
objects while keeping a permissive `content` field for backwards
interop. BeamWeaver uses explicit constructors and
`Message.content_blocks/1` because Elixir code tends to make conversion points
visible. Provider-native maps are still accepted at boundaries, but portable
application code should prefer `BeamWeaver.Core.ContentBlock` helpers. Message
serialization is also explicit through `Messages.Utils`; there is no global
environment variable that changes the shape of every model output in a running
OTP system.
{% endhint %}

## Standard Content Blocks

`BeamWeaver.Core.ContentBlock.known_types/0` returns the native block types the
core understands:

| Type | Constructor or shape | Purpose |
|---|---|---|
| `:text` | `ContentBlock.text/2` | text content |
| `:plain_text` | `ContentBlock.plain_text/2` | document-style plain text |
| `:image` | `ContentBlock.image/1` | image URL, data URI, or base64 data |
| `:audio` | `ContentBlock.audio/1` | audio URL or base64 data |
| `:video` | `ContentBlock.video/1` | video URL or base64 data |
| `:file` | `ContentBlock.file/1` | PDFs and other files |
| `:reasoning` | `ContentBlock.reasoning/2` | model reasoning summaries or thinking output |
| `:citation` | `ContentBlock.citation/1` | source annotations |
| `:tool_result` | `ContentBlock.tool_result/1` | provider tool-result block |
| `:tool_call` | `%{type: :tool_call, ...}` | complete streamed or provider tool call |
| `:tool_call_chunk` | `%{type: :tool_call_chunk, ...}` | partial streamed client-side tool call |
| `:server_tool_call` | `%{type: :server_tool_call, ...}` | provider-executed tool call |
| `:server_tool_call_chunk` | `%{type: :server_tool_call_chunk, ...}` | partial server-side tool call |
| `:server_tool_result` | `%{type: :server_tool_result, ...}` | provider-executed tool result |
| `:unknown` | `ContentBlock.unknown/3` | provider-specific escape hatch |

Content block names are Elixir atoms inside BeamWeaver. Provider translators
render the provider's external string names at the HTTP boundary.

### Text And Reasoning

```elixir
[
  ContentBlock.text("Final answer."),
  ContentBlock.reasoning("I compared the available evidence."),
  ContentBlock.citation(%{
    url: "https://example.com/article",
    title: "Article",
    start_index: 32,
    end_index: 88
  })
]
```

Reasoning fields vary by provider. BeamWeaver normalizes common OpenAI,
Anthropic, Google, and xAI reasoning shapes into reasoning blocks where provider
translators have coverage, and preserves unknown provider data instead of
dropping it.

### Multimodal

Core messages can represent image, audio, video, and file blocks:

```elixir
payload = Base.encode64("binary image bytes")

Message.user([
  ContentBlock.text("Describe this image."),
  ContentBlock.image(%{url: "https://example.com/image.jpg"}),
  ContentBlock.image(%{data: payload, mime_type: "image/jpeg"}),
  ContentBlock.file(%{file_id: "file-abc123", filename: "brief.pdf"}),
  ContentBlock.audio(%{data: Base.encode64("wav bytes"), mime_type: "audio/wav"})
])
```

Data URIs are parsed into typed blocks:

```elixir
{:ok, block} =
  ContentBlock.from("data:image/png;base64,#{Base.encode64("png bytes")}")
```

{% hint style="info" %}
**Provider Translation**

The core message struct can hold more block types than any one model provider
accepts. OpenAI, Anthropic, Google, and xAI translators cover the scoped block
shapes tested for those providers. Other provider-native formats belong in
provider translators or `ContentBlock.unknown/3` until a native adapter defines
how the data should be rendered.
{% endhint %}

### Tool Calling Blocks

Assistant messages can carry complete tool calls in `message.tool_calls` or in
content blocks. Streamed tool calls use chunks and are finalized by the chunk
merge helpers:

```elixir
alias BeamWeaver.Core.Messages
alias BeamWeaver.Core.Messages.MessageChunk

chunks = [
  Messages.ai_chunk("",
    tool_call_chunks: [
      Messages.tool_call_chunk(
        id: "call_weather",
        index: 0,
        name: "weather",
        args: ~s({"city":)
      )
    ]
  ),
  Messages.ai_chunk("",
    tool_call_chunks: [
      Messages.tool_call_chunk(id: "call_weather", index: 0, args: ~s("Nicosia"}))
    ]
  )
]

message =
  chunks
  |> MessageChunk.merge_many()
  |> MessageChunk.to_message()

message.tool_calls
```

Malformed streamed tool arguments are preserved in
`message.metadata[:invalid_tool_calls]` so callers can surface a useful error or
ask the model to retry.

{% hint style="info" %}
**Chunk Merging**

LangChain examples combine `AIMessageChunk` values with the Python `+`
operator. Elixir does not overload arithmetic operators for structs, so
BeamWeaver uses `MessageChunk.merge/2`, `MessageChunk.merge_many/1`, and
`MessageChunk.to_message/1`. The merge step is explicit and testable, which is
important for streamed tool calls where providers may send IDs, names, and JSON
argument fragments in different events.
{% endhint %}

### Server-Side Tool Blocks

Some providers execute tools server-side and return tool calls/results inside a
single assistant response. BeamWeaver can preserve those blocks on message
content and on the dedicated fields:

```elixir
Message.assistant([
  %{type: :server_tool_call, id: "srv_1", name: "web_search", args: %{"query" => "news"}},
  %{type: :server_tool_result, tool_call_id: "srv_1", status: "success"},
  ContentBlock.text("Here is the summary.")
])
```

Client-side tools still use assistant `tool_calls` followed by `:tool` messages.
Server-side tool blocks represent provider work that already happened during
the model request.

### Unknown Provider Blocks

Use `ContentBlock.unknown/3` or plain maps when a provider returns data that
does not yet have a portable BeamWeaver block:

```elixir
ContentBlock.unknown("vendor.private", %{"payload" => %{"deep" => true}})
```

Unknown blocks are preserved for application logic and provider translators.
They are not treated as portable model input until a translator defines their
provider-specific rendering.

## Serialization

Use `BeamWeaver.Core.Messages.Utils` for safe plain-data serialization:

```elixir
alias BeamWeaver.Core.{Message, Messages.Utils}

messages = [
  Message.user("hello", id: "msg_1"),
  Message.assistant("world", usage_metadata: %{total_tokens: 4})
]

{:ok, encoded} = Utils.messages_to_dict(messages)
{:ok, decoded} = Utils.messages_from_dict(encoded)
```

Serialized messages include a BeamWeaver message version and only plain data.
That shape is suitable for checkpoints, replay fixtures, and test assertions.

## Message Utilities

`BeamWeaver.Core.Messages.Utils` includes common history operations:

```elixir
alias BeamWeaver.Core.Messages.Utils

{:ok, trimmed} =
  Utils.trim(messages,
    max_tokens: 2_000,
    strategy: :last,
    token_counter: &my_token_counter/1
  )

{:ok, merged} = Utils.merge_runs(messages)
{:ok, filtered} = Utils.filter(messages, exclude_tool_calls: true)
{:ok, count} = Utils.count_tokens_approximately(messages)
{:ok, printable} = Utils.pretty_print(messages)
```

These helpers operate on message-like values and return tagged results. Use
them before provider calls, in middleware, or when preparing checkpointed
conversation state.

## Use With Chat Models

Chat models accept a string, one message-like value, or a list of
`%BeamWeaver.Core.Message{}` values:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

history = [
  Message.system("You translate English to French."),
  Message.user("Translate: I love programming.")
]

{:ok, response} = ChatModel.invoke(model, history)
```

For streaming tokens and semantic events, see [Event Streaming](event_streaming.md)
and [Models](models.md). For agent-managed message state, checkpoints, tool
loops, and middleware, see [Agents](agents.md) and
[Short-Term Memory](short_term_memory.md).

## Related Guides

- [Models](models.md)
- [Agents](agents.md)
- [Tools](tools.md)
- [Structured Output](structured_output.md)
- [Event Streaming](event_streaming.md)
