# Messages

A conversation in BeamWeaver is a list of `%BeamWeaver.Core.Message{}`
structs: instructions, what the user said, the model's replies and tool
results. You work with messages when you call a model yourself, seed a
conversation, or read an agent's result.

```elixir
alias BeamWeaver.Core.Message

history = [
  Message.system("You are Acme's support agent."),
  Message.user("Where is my order A-1001?"),
  Message.assistant("It shipped on Monday.")
]

Enum.map(history, &{&1.role, Message.text(&1)})
#=> [system: "You are Acme's support agent.", user: "Where is my order A-1001?", assistant: "It shipped on Monday."]
```

## Roles and constructors

Each message has a role, and each role has a constructor:

| Role | Constructor | Use it for |
| --- | --- | --- |
| `:system` | `Message.system/2` | Instructions for the model. |
| `:user` | `Message.user/2` | What the user says, including images and files. |
| `:assistant` | `Message.assistant/2` | The model's replies, and earlier replies when you seed a conversation. |
| `:tool` | `Message.tool/2` | The result of a tool call. |

The second argument takes the other fields as options, such as `name:`,
`id:`, `metadata:`, `tool_calls:` and `tool_call_id:`. Constructors raise on
invalid content; `BeamWeaver.Core.Message.new/3` returns an error tuple instead:

```elixir
Message.new(:robot, "Beep.")
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_role}}
```

Messages that arrive as plain data, such as JSON from a browser or a stored
transcript, convert with `BeamWeaver.Core.Message.from/1`. It accepts a
string (a user message), a `{role, content}` tuple, or a map with `"role"` and
`"content"` keys. `BeamWeaver.Core.Messages.Utils.normalize/1` converts a whole
list:

```elixir
alias BeamWeaver.Core.Messages.Utils

{:ok, messages} =
  Utils.normalize([
    %{"role" => "user", "content" => "Where is my order A-1001?"},
    %{"role" => "assistant", "content" => "It shipped on Monday."},
    "Thanks!"
  ])

Enum.map(messages, & &1.role)
#=> [:user, :assistant, :user]
```

A `"developer"` role becomes a system message. Agents accept plain strings in
`messages` and turn them into user messages for you.

## The message struct

| Field | Holds |
| --- | --- |
| `role` | `:system`, `:user`, `:assistant` or `:tool`. |
| `content` | A string, or a list of content blocks. |
| `name` | Who wrote it. An agent puts its name on its replies. |
| `id` | An id; messages in an agent's state get one. |
| `tool_calls` | On replies: the tools the model asked to call. |
| `tool_call_id` | On tool results: the call this result answers. |
| `usage_metadata` | On replies: token counts (see [Models](models.md#token-usage)). |
| `response_metadata` | On replies: details from the provider, such as the model used. |
| `metadata` | Extra data, yours or the provider's. |
| `artifacts` | On tool results you build with `Message.tool/2`: data for your application that providers don't send to the model. |
| `server_tool_calls`, `server_tool_results` | Tools Google ran itself, such as web search. Anthropic and OpenAI put these in content blocks. |

## Text and content blocks

Content is a string or a list of blocks. Blocks put images, files and audio
next to text. This example uses the bundled image from a repository checkout:

```elixir
alias BeamWeaver.Core.ContentBlock

photo =
  Message.user([
    ContentBlock.text("What color fills this image?"),
    ContentBlock.image(data: Base.encode64(File.read!("examples/fixtures/red-square.png")), mime_type: "image/png")
  ])

Message.text(photo)
#=> "What color fills this image?"
```

`Message.text/1` joins the text of a message and skips the other blocks. Use it
to read any reply, whatever its content.

| Constructor | Block |
| --- | --- |
| `ContentBlock.text(text)` | Text. |
| `ContentBlock.image(url: url)` | An image at a URL. |
| `ContentBlock.image(data: base64, mime_type: "image/png")` | An image sent inline, base64-encoded. |
| `ContentBlock.file(data: base64, mime_type: "application/pdf", filename: name)` | A file such as a PDF. `file_id:` refers to a file uploaded to the provider. |
| `ContentBlock.audio(...)`, `ContentBlock.video(...)` | Audio and video, with the same options as images. |
| `ContentBlock.reasoning(text)` | A model's reasoning, as reasoning models return it. |

Each block has a `type`:

```elixir
invoice =
  Message.user([
    ContentBlock.text("Please check this invoice."),
    ContentBlock.file(data: Base.encode64("%PDF-1.7 ..."), mime_type: "application/pdf", filename: "invoice.pdf")
  ])

Enum.map(invoice.content, & &1.type)
#=> [:text, :file]
```

`ContentBlock.from/1` turns a data URI, such as `"data:image/png;base64,..."`,
into the block for its media type. Not every model reads every kind of block, so check with
`BeamWeaver.Provider.Compatibility.supports?/2` and a feature such as
`:image_input`, `:pdf_input` or `:audio_input` before you send one (see
[Model profiles](models.md#model-profiles)). A block the API has no input for,
such as video on Anthropic or OpenAI, makes the call return an error before
anything is sent.

## Tool calls and tool results

When the model wants a tool, its reply lists `tool_calls`, each with an `id`,
a `name` and `args`. Your code runs the tool and answers with a tool message
whose `tool_call_id` matches the call. An agent does this loop for you; here it
is by hand, with the `lookup_order` tool from the [Quickstart](quickstart.md):

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped on Monday."}
end

alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Models.FakeChatModel

{:ok, model} =
  BeamWeaver.Models.init_chat_model("fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday."
    ]
  )

question = Message.user("Where is my order A-1001?")
{:ok, call_reply} = ChatModel.invoke(model, [question], tools: [MyApp.Tools.LookupOrder])

[call] = call_reply.tool_calls
{call.name, call.args}
#=> {"lookup_order", %{"order_id" => "A-1001"}}
```

`BeamWeaver.Core.Tool.invoke/3` runs the tool for a call and returns the tool
message, with `tool_call_id` already set:

```elixir
{:ok, result} = BeamWeaver.Core.Tool.invoke(MyApp.Tools.LookupOrder, call)
{result.role, result.tool_call_id == call.id}
#=> {:tool, true}
```

Send the whole exchange back, and the model answers:

```elixir
{:ok, answer} = ChatModel.invoke(model, [question, call_reply, result], tools: [MyApp.Tools.LookupOrder])
Message.text(answer)
#=> "Your order A-1001 shipped on Monday."
```

To write a tool result yourself, use
`Message.tool("Order A-1001 shipped on Monday.", tool_call_id: call.id, name: "lookup_order")`.
Pass `artifacts:` to keep data, such as raw records, for your application:
providers send only `content` to the model. A tool module returns such data
in a `ToolResult` instead, and an agent stores it in the tool message's
`metadata.artifact` (see [Tools](tools.md#artifacts)).

## Usage metadata

Replies carry the provider's token counts in `usage_metadata`.
`BeamWeaver.Core.Messages.Utils.add_usage/2` adds two of them:

```elixir
Utils.add_usage(%{input_tokens: 12, output_tokens: 6, total_tokens: 18}, %{input_tokens: 30, output_tokens: 4, total_tokens: 34})
#=> %{input_tokens: 42, output_tokens: 10, total_tokens: 52}
```

[Models](models.md#token-usage) shows where the counts come from and how to
total an agent run.

## Work with history

`BeamWeaver.Core.Messages.Utils` prepares a history before you send or store
it. Its functions accept messages or plain data and return `{:ok, result}`.
This is the conversation from the last section, with a system prompt and one
more user turn:

```elixir
history = [
  Message.system("You are Acme's support agent."),
  question,
  call_reply,
  result,
  answer,
  Message.user("Thanks!")
]

{:ok, without_tools} = Utils.filter(history, exclude_tool_calls: true)
Enum.map(without_tools, & &1.role)
#=> [:system, :user, :assistant, :user]
```

`filter/2` also keeps or drops messages by role, name or id, with options such
as `include_roles: [:user]` and `exclude_ids: [...]`.

`trim/2` keeps the newest messages that fit a budget. By default it estimates
tokens like `count_tokens_approximately/2`: about four characters per token,
plus a few per message. Pass `token_counter:` a function that counts a
message's tokens to use your model's tokenizer. A tool result is never kept
without the call it answers. Here the tool result fits in the budget but its
call doesn't, so both are left out:

```elixir
{:ok, recent} = Utils.trim(history, max_tokens: 40, strategy: :last, include_system: true)
Enum.map(recent, & &1.role)
#=> [:system, :assistant, :user]
```

`encode/1` turns messages into plain maps that you can store as JSON, and
`decode/1` turns them back:

```elixir
{:ok, stored} = Utils.encode(history)
json = JSON.encode!(stored)

{:ok, restored} = json |> JSON.decode!() |> Utils.decode()
Enum.map(restored, &Message.text/1) == Enum.map(history, &Message.text/1)
#=> true
```

`buffer_string/2` renders a transcript as text, for example to put a
conversation inside a prompt:

```elixir
Utils.buffer_string([question, Message.assistant("It shipped on Monday.")])
#=> {:ok, "Human: Where is my order A-1001?\nAI: It shipped on Monday."}
```

`merge_runs/2` joins consecutive messages that have the same role (except
tool results), and
`count_tokens_approximately/2` estimates the size of a history. An agent's
history is managed for you; [Short-Term Memory](short_term_memory.md) and
[Context Management](context_management.md) cover trimming and summarizing it.

## Streaming chunks

A streamed reply arrives as chunks: text deltas and partial tool calls that
add up to the final message. [Streaming](streaming.md) covers chunks and how
to merge them.

## Reference

- [`BeamWeaver.Core.Message`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.Message.html): the message struct and its constructors
- [`BeamWeaver.Core.ContentBlock`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.ContentBlock.html): text, image, file and other content blocks
- [`BeamWeaver.Core.Messages.Utils`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.Messages.Utils.html): filter, trim, merge, count and serialize messages
- [`BeamWeaver.Core.Messages.ToolCall`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.Messages.ToolCall.html): a tool call on a model reply
- [`BeamWeaver.Core.Tool`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.Tool.html): run a tool for a tool call
