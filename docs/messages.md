# Messages and Media

BeamWeaver represents conversations as `BeamWeaver.Core.Message` structs.
Agents maintain that conversation for you. Work with messages directly when
calling a model, importing history, handling media or inspecting tool results.

Complete [Installation](installation.md) for the live calls below. Run blocks
in order; the media example also needs the repository's bundled fixture.

## Send and read a conversation

```elixir
alias BeamWeaver.Core.{ChatModel, Message}
alias BeamWeaver.Core.Messages.Utils

{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000)
history = [Message.system("Explain shipping terms briefly."), Message.user("What does dispatched mean?")]
{:ok, reply} = ChatModel.invoke(model, history)
:assistant = reply.role
true = byte_size(Message.text(reply)) > 0
history = history ++ [reply]
```

Read text with `Message.text/1`. It works for plain text and block content,
joining text blocks while leaving media out of the returned string.

## Roles and constructors

| Constructor | Purpose |
| --- | --- |
| `Message.system/2` | Instructions |
| `Message.user/2` | User input, including media |
| `Message.assistant/2` | Model replies or supplied conversation history |
| `Message.tool/2` | An action's result, correlated with `tool_call_id:` |

Constructor options include IDs, names and metadata. Constructors raise on
invalid input; `Message.new/3` returns a result tuple. `Message.from/1`
accepts strings, role/content tuples and maps. A string becomes a user message;
a developer role normalizes to system. To normalize a whole list:

```elixir
{:ok, messages} =
  Utils.normalize([
    %{"role" => "user", "content" => "Track my order."},
    {:assistant, "Please provide the order ID."},
    "A-1001"
  ])

[:user, :assistant, :user] = Enum.map(messages, & &1.role)
```

Do not trust browser-provided roles or saved transcripts as authorization.
Decide which history and instructions the caller may supply.

## The message struct

| Field | Contents |
| --- | --- |
| `role`, `content` | Speaker and text/content blocks |
| `name`, `id` | Speaker identity and message identity |
| `tool_calls` | Requested actions with IDs, names and arguments |
| `tool_call_id` | The action answered by a tool message |
| `usage_metadata` | Provider-reported token counts |
| `response_metadata` | Provider response details |
| `metadata` | Application/provider extras, including parsed output or artifacts |
| `artifacts` | Application-only data on tool results |
| `server_tool_calls`, `server_tool_results` | Hosted-tool records where the provider uses these fields |

Hosted tools can also appear as provider-specific content blocks. Preserve
complete returned messages when continuing a conversation: extracting only
text can discard tool correlation, reasoning signatures or provider state.

## Text and content blocks

A message's content can combine text, images and files. From a repository
checkout, this makes a real image request with the small bundled fixture:

```elixir
alias BeamWeaver.Core.ContentBlock

photo =
  Message.user([
    ContentBlock.text("Name the single color filling this image."),
    ContentBlock.image(data: Base.encode64(File.read!("examples/fixtures/red-square.png")), mime_type: "image/png")
  ])

{:ok, description} = ChatModel.invoke(model, [photo])
true = description |> Message.text() |> String.downcase() |> String.contains?("red")
```

For a consumer app, copy [the fixture](assets/fixtures/red-square.png)
to that relative path or use your own image. File reads resolve from the
process's working directory.

The same downloadable fixtures support the provider walkthroughs. Save them
under these paths in your application before running the examples:

| Fixture | Save as | Expected content |
| --- | --- | --- |
| [PNG image](assets/fixtures/red-square.png) | `examples/fixtures/red-square.png` | A red square |
| [MP4 video](assets/fixtures/red-square.mp4) | `examples/fixtures/red-square.mp4` | One second of solid red |
| [PDF document](assets/fixtures/sample.pdf) | `examples/fixtures/sample.pdf` | “Dummy PDF file” |

The image and video were generated for these examples. The PDF is the
[W3C test document](https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf).

| Constructor | Input |
| --- | --- |
| `ContentBlock.text(text)` | Text |
| `ContentBlock.image(url: url)` | A reachable image URL |
| `ContentBlock.image(data: base64, mime_type: type)` | Inline image bytes |
| `ContentBlock.file(data: base64, mime_type: type, filename: name)` | Inline file, such as a PDF |
| `ContentBlock.file(file_id: id, ...)` | A resource already uploaded to that provider |
| `ContentBlock.audio(...)`, `ContentBlock.video(...)` | Provider-supported audio/video input |
| `ContentBlock.reasoning(text)` | Reasoning content |

`ContentBlock.from/1` can normalize data URIs. Use actual media bytes, not a
filename encoded as base64. Check input support with
`BeamWeaver.Provider.Compatibility.supports?/2`; the provider guide explains
which formats and upload endpoints are supported. An uploaded resource ID is
provider/account-specific. Delete resources your application no longer needs.

## Tool calls and tool results

A direct model call requests tools but does not execute them. An agent owns
that loop. If you implement it yourself, keep the complete assistant request
and match every result to its call ID:

```elixir
tool =
  BeamWeaver.Core.Tool.from_function!(
    name: "delivery_day",
    description: "Read the delivery day for order A-1001.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"order_id" => %{"type" => "string"}},
      "required" => ["order_id"]
    },
    handler: fn %{"order_id" => "A-1001"}, _opts -> {:ok, "Thursday"} end
  )

question = Message.user("Call delivery_day for order A-1001 and tell me the result.")
{:ok, requested} = ChatModel.invoke(model, [question], tools: [tool])
[call] = requested.tool_calls
"delivery_day" = call.name
%{"order_id" => "A-1001"} = call.args
{:ok, tool_reply} = BeamWeaver.Core.Tool.invoke(tool, call)
true = tool_reply.tool_call_id == call.id
{:ok, answer} = ChatModel.invoke(model, [question, requested, tool_reply], tools: [tool])
true = Message.text(answer) =~ "Thursday"
```

A production loop must handle multiple requests, tool errors, timeouts and
repeated turns. Prefer an [agent](agents.md) unless your application needs
that control. `ToolResult` keeps artifacts separately from model-visible
content; see [Tools](tools.md#artifacts).

## Work with history

`BeamWeaver.Core.Messages.Utils` operates on messages or normalizable data.
Use `filter/2` to include/exclude roles, IDs, names or tool exchanges; use
`trim/2` to fit a budget while retaining valid call/result pairs.

```elixir
{:ok, user_messages} = Utils.filter(messages, include_roles: [:user])
true = Enum.all?(user_messages, &(&1.role == :user))
{:ok, stored} = Utils.encode(messages)
{:ok, restored} = stored |> JSON.encode!() |> JSON.decode!() |> Utils.decode()
true = Enum.map(restored, &Message.text/1) == Enum.map(messages, &Message.text/1)
```

Trimming uses an approximate character-based token counter unless you supply
`token_counter:`. Reserve space for instructions, tools and the answer.
`merge_runs/2` merges compatible adjacent messages; `buffer_string/2`
produces a readable transcript. Neither replaces lossless serialization when
you need to continue provider conversations.

Encode a complete conversation and restore it before replay:

```elixir
{:ok, stored} = Utils.encode(history)
json = JSON.encode!(stored)

{:ok, restored} = json |> JSON.decode!() |> Utils.decode()
Enum.map(restored, &Message.text/1) == Enum.map(history, &Message.text/1)
#=> true
```

## Usage metadata

`Utils.add_usage/2` combines token counters. For an entire agent run, use
`BeamWeaver.Agent.Usage.from_messages/1`. [Models](models.md#token-usage)
explains cache/reasoning details and cost estimates.

Combine reported usage without discarding existing counters:

```elixir
Utils.add_usage(%{input_tokens: 12, output_tokens: 6, total_tokens: 18}, %{
  input_tokens: 30,
  output_tokens: 4,
  total_tokens: 34
})

#=> %{input_tokens: 42, output_tokens: 10, total_tokens: 52}
```

## Streaming chunks

Chunks contain partial text and tool arguments. Assemble them before treating
them as complete messages or executable calls. [Streaming](streaming.md)
explains typed events, finalization and failed-attempt handling.
