# Z.ai

BeamWeaver calls Z.ai's GLM models through their OpenAI-compatible Chat
Completions API with `BeamWeaver.ZAI.ChatModel`. It supports thinking with a
reasoning effort, function tools with streamed tool-call arguments, structured
output through JSON mode, cached-token usage, and image, video and PDF input
on GLM-5.3-Flash and GLM-5.3-FlashX, including files uploaded to Z.ai.

## Setup

```elixir
# config/runtime.exs
import Config

config :beam_weaver, :zai, api_key: System.get_env("ZAI_API_KEY")
```

Export `ZAI_API_KEY`.

## Models

| Model | Kind | Input tokens | Output tokens | Tools | Structured output | Reasoning | Inputs |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `zai:glm-4.6` | chat | 200,000 | 131,072 | yes | yes | yes | text |
| `zai:glm-4.7` | chat | 200,000 | 131,072 | yes | yes | yes | text |
| `zai:glm-5` | chat | 200,000 | 131,072 | yes | yes | yes | text |
| `zai:glm-5.1` | chat | 200,000 | 131,072 | yes | yes | yes | text |
| `zai:glm-5.2` | chat | 1,000,000 | 131,072 | yes | yes | yes | text |
| `zai:glm-5.3` | chat | 1,000,000 | 131,072 | yes | yes | yes | text |
| `zai:glm-5.3-flash` | chat | 1,000,000 | 131,072 | yes | yes | yes | text, image, PDF, video |
| `zai:glm-5.3-flashx` | chat | 1,000,000 | 131,072 | yes | yes | yes | text, image, PDF, video |

These are the chat models Z.ai lists as current. Other GLM ids, such as the
older `glm-4.5`, are rejected before the request, and every id needs the
`zai:` prefix.

## Usage

Name the model on the agent's `model` line, with any options after it:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "zai:glm-5.3", reasoning_effort: :high, timeout: 120_000
  system_prompt "You are Acme's support agent. Answer in two sentences."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
```

Tools, middleware and memory work as in [Agents](../agents.md). To call the
model without an agent, build it with `BeamWeaver.Models.init_chat_model/2`
(see [Models](../models.md)):

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("zai:glm-5.3")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Write a one-line apology for a late order.")
BeamWeaver.Core.Message.text(reply)
```

## Options

| Option | What it does |
| --- | --- |
| `reasoning_effort` | GLM-5.3, GLM-5.3-Flash and GLM-5.3-FlashX: `:low`, `:high` or `:max` (their default). GLM-5.2 takes the full range from `:none` to `:max`. GLM-5.1 and older take none. |
| `thinking` | `%{type: :enabled}` or, on GLM-5.2 and older, `%{type: :disabled}`. GLM-5.3 models always think. |
| `tool_stream` | `true` streams tool-call arguments as they are generated. Needs `stream: true`. |
| `max_tokens` | Output cap. |
| `base_url` | The API root, for a proxy. Defaults to `https://api.z.ai/api/paas/v4`. |

The options shared by every provider, such as `timeout`, are on
[Providers](../providers.md#options-for-every-provider). BeamWeaver rejects an
effort or thinking mode a model doesn't support before the request.

Z.ai takes no request metadata, so `metadata:` returns an
`:unsupported_model_param` error before the request; trace data goes in
`trace_metadata:` (see [Tracing](../tracing.md#name-and-tag-a-run)).

## Thinking

The GLM-5.3 models always think, at `:max` effort unless you choose `:low` or
`:high`. GLM-5.2 and the older models can turn thinking off:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "zai:glm-5.2", thinking: %{type: :disabled}, timeout: 120_000
  system_prompt "You are Acme's support agent."
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Reply with the word ready."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

The reasoning text arrives as `%{type: :reasoning}` blocks in the reply's
`content`, which `BeamWeaver.Core.Message.text/1` skips.

## Streamed tool arguments

With `tool_stream: true`, Z.ai sends a tool call's arguments while the model
writes them, so a streaming UI can show the call as it forms. It works only on
streamed requests; an agent streams every model call when its model options
include `stream: true`:

```elixir
defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Get an order's shipping status."

  schema do
    field :order_id, :string, required: true
  end

  @impl true
  def invoke(_tool, %{"order_id" => id}, _opts), do: {:ok, "Order #{id} shipped on Monday."}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "zai:glm-5.3", stream: true, tool_stream: true, timeout: 120_000
  system_prompt "Look up the order before answering. Call lookup_order exactly once."
  tools [MyApp.Tools.LookupOrder]
end

{:ok, events} = MyApp.SupportAgent.stream_events(%{messages: ["Where is my order A-1001?"]}, live: true)
events = Enum.to_list(events)

alias BeamWeaver.Stream.Events

argument_chunks =
  for %{event: %Events.ToolCallChunk{chunk: chunk}} <- events,
      is_binary(chunk.args), do: chunk.args
%{"order_id" => "A-1001"} = argument_chunks |> Enum.join() |> JSON.decode!()
[call] = for %{event: %Events.ToolStart{tool_name: "lookup_order"} = call} <- events, do: call
%{"order_id" => "A-1001"} = call.input
true = Enum.any?(events, &match?(%{event: %Events.ToolFinish{tool_call_id: id}} when id == call.tool_call_id, &1))
false = Enum.any?(events, &match?(%{event: %Events.Error{}}, &1))
```

On a model without `stream: true`, BeamWeaver rejects `tool_stream` before the
request. [Streaming](../streaming.md) covers the events.

## Structured output

Z.ai has a JSON object mode but no JSON Schema mode. For structured output,
BeamWeaver turns on JSON mode, adds the schema to the prompt and validates the
answer itself; see [Structured Output](../structured_output.md).

When Z.ai reports cached prompt tokens, BeamWeaver puts them in
`usage_metadata.input_token_details.cache_read`. There is no cache key to set,
and `prompt_caching true` has no effect.

## Images, video and PDFs

GLM-5.3-Flash and GLM-5.3-FlashX read images, video and PDFs, each as a URL
or as base64 data, and one message can mix them:

Run this example from a repository checkout, using the bundled
[example fixtures](https://github.com/caudena/beam_weaver/tree/master/examples/fixtures).

```elixir
alias BeamWeaver.Core.{ContentBlock, Message}

label = Base.encode64(File.read!("examples/fixtures/sample.pdf"))

question =
  Message.user([
    ContentBlock.text("Name the image colour and quote the text in the PDF."),
    ContentBlock.image(data: Base.encode64(File.read!("examples/fixtures/red-square.png")), mime_type: "image/png"),
    ContentBlock.file(data: label, mime_type: "application/pdf", filename: "sample.pdf")
  ])

{:ok, model} = BeamWeaver.Models.init_chat_model("zai:glm-5.3-flash")
{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, [question])
```

A file uploaded with Z.ai's file API (`POST https://api.z.ai/api/paas/v4/files`
with purpose `user_data`, which BeamWeaver doesn't wrap) goes by the `id` the
upload returns:

```elixir
alias BeamWeaver.Core.{ContentBlock, Message}

files_url = "https://api.z.ai/api/paas/v4/files"
headers = [{"authorization", "Bearer " <> System.fetch_env!("ZAI_API_KEY")}]
upload = Req.post!(files_url,
  headers: headers,
  form_multipart: [purpose: "user_data", file: {File.read!("examples/fixtures/sample.pdf"), filename: "sample.pdf"}],
  retry: false, receive_timeout: 60_000
)
true = upload.status in 200..299
file_id = Map.fetch!(upload.body, "id")

try do
  question = Message.user([
    ContentBlock.text("Quote the text in this PDF."),
    ContentBlock.file(file_id: file_id)
  ])
  {:ok, model} = BeamWeaver.Models.init_chat_model("zai:glm-5.3-flash", timeout: 60_000)
  {:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, [question])
  true = String.contains?(String.downcase(Message.text(reply)), "dummy")
after
  response = Req.delete!(files_url <> "/" <> URI.encode(file_id), headers: headers, retry: false)
  true = response.status in 200..299
end
```

Z.ai's own part for a document, `%{"type" => "file", "file" => %{"file_url" => url}}`
(or `"file_id"`, or `"file_data"` with a data URL), works in a message's
content too and becomes the same file block. Z.ai downloads URL media itself,
so the URL must be public; when Z.ai can't fetch or read a file, the call
fails with an `:invalid_request` error (HTTP 400) whose Z.ai code is
`"1210"`. The other GLM models take text only, and every model rejects audio;
a block a model can't take returns an `:unsupported_feature` error before the
request. Z.ai's tool messages take only text, so media a tool returns goes in
a user message right after the tool results. The
[zai_media.exs](https://github.com/caudena/beam_weaver/blob/master/examples/zai_media.exs)
example sends an image, a PDF and a video.

## Errors

Z.ai names its errors by code, which BeamWeaver keeps in `details.code`: 1301,
its content filter, is a `:content_filter` error, and its plan and usage
limits are `:billing_exhausted`; `ModelRetry` retries neither. Its other
errors get their [type](../models.md#errors) from their HTTP status: 1302 (a
rate limit) and 1305 (an overload) are `:rate_limit` errors. A reply that Z.ai
stops partway reports why as its finish reason instead, and the call fails the
same way, with or without streaming: `sensitive` (its safety review blocked
the reply) is a `:content_filter` error, and `network_error` (its inference
failed) a `:server_error` that `ModelRetry` retries.

## Limitations

- No JSON Schema mode; schemas are enforced by local validation.
- Z.ai takes only automatic tool choice, so the structured-output tool
  strategy offers the schema tool without forcing it.
- Z.ai's built-in tools and its non-chat APIs have no BeamWeaver wrapper.
- `BeamWeaver.ZAI.ChatModel.count_tokens/3` returns a rough local estimate,
  not Z.ai's own count.

## Testing

In tests, use `"fake:chat"` instead of a GLM model; it needs no key (see
[Testing](../testing.md)). To check the exact requests your code sends,
answer them from a cassette with `transport: BeamWeaver.Transport.Replay`
and `transport_opts: [cassette_path: "test/cassettes/zai.yml"]`;
[Replay provider responses](../testing.md#replay-provider-responses) shows
how to write one.

## Reference

- [Z.ai file uploads](https://docs.z.ai/api-reference/agents/file-upload): provider API contract

- [`BeamWeaver.ZAI`](https://hexdocs.pm/beam_weaver/BeamWeaver.ZAI.html): constructors
- [`BeamWeaver.ZAI.ChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.ZAI.ChatModel.html): the GLM chat model
- [`BeamWeaver.ZAI.Tools`](https://hexdocs.pm/beam_weaver/BeamWeaver.ZAI.Tools.html): function tool declarations
