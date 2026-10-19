# Z.ai

Use GLM through Z.ai's Chat Completions API. BeamWeaver supports model-specific
thinking, function tools, streamed arguments, JSON-mode structured answers
and media on compatible Flash models.

## Setup and first request

```elixir
import Config
config :beam_weaver, :zai, api_key: System.fetch_env!("ZAI_API_KEY")
```

Save configuration in your application's runtime file, then run:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}

{:ok, model} =
  BeamWeaver.Models.init_chat_model("zai:glm-5.3-flash", reasoning_effort: :low, max_tokens: 2_048, timeout: 120_000)

{:ok, reply} = ChatModel.invoke(model, "Explain parcel tracking in one sentence.")
true = byte_size(Message.text(reply)) > 0
true = reply.usage_metadata.total_tokens > 0
```

GLM-5.3 models always think. Low effort reduces the example's work without
trying to disable a required model behavior. Reasoning consumes output budget;
leave room for a visible answer as well.

## Options and thinking

GLM-5.3 accepts low/high/max effort; GLM-5.2 has a broader effort range and can
disable thinking. Older models have their own fixed controls. Unsupported
combinations fail before the request. Use the profile of the exact model.

Other options include output-token limits, base URL and `tool_stream:`.
Native request metadata is unsupported; use trace metadata for your labels.
Returned reasoning is separate from `Message.text/1`.

## Streamed tool arguments

`tool_stream: true` needs model streaming enabled. This complete example
reassembles actual argument chunks and correlates the completed tool:

```elixir
defmodule MyApp.ZaiOrderTool do
  use BeamWeaver.Tool
  name "lookup_order"
  description "Read the sample order status."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => id}, _opts), do: {:ok, "Order #{id} shipped Monday."}
end

defmodule MyApp.ZaiAgent do
  use BeamWeaver.Agent

  model "zai:glm-5.3-flash",
    reasoning_effort: :low,
    max_tokens: 2_048,
    stream: true,
    tool_stream: true,
    timeout: 120_000

  system_prompt "Call lookup_order exactly once before answering an order question."
  tools [MyApp.ZaiOrderTool]
end

alias BeamWeaver.Stream.Events
{:ok, stream} = MyApp.ZaiAgent.stream_events(%{messages: ["Check order A-1001."]}, live: true)
events = Enum.to_list(stream)
parts = for %{event: %Events.ToolCallChunk{chunk: chunk}} <- events, is_binary(chunk.args), do: chunk.args
%{"order_id" => "A-1001"} = parts |> Enum.join() |> JSON.decode!()
[call] = for %{event: %Events.ToolStart{tool_name: "lookup_order"} = call} <- events, do: call
%{"order_id" => "A-1001"} = call.input
true = Enum.any?(events, &match?(%{event: %Events.ToolFinish{tool_call_id: id}} when id == call.tool_call_id, &1))
false = Enum.any?(events, &match?(%{event: %Events.Error{}}, &1))
```

An application handling several simultaneous calls must group chunks by call
ID/index before decoding. Partial JSON is display data, not an executable action.

## Structured output and caching

Z.ai uses JSON-object mode rather than native JSON Schema enforcement.
BeamWeaver supplies schema instructions and applies its local validation;
see [Structured Output](../structured_output.md) for its limits. Only automatic
tool choice is available, so a schema tool cannot always be forced.

Prefix caching is automatic. Inspect reported cache-read tokens; the agent
prompt-caching declaration adds no provider key here.

## Images, video and PDFs

Compatible GLM-5.3 Flash profiles accept images, video and PDFs. Other listed
profiles are text-only; audio is not supported by this integration. This
checkout example verifies the bundled image and PDF contents:

```elixir
alias BeamWeaver.Core.ContentBlock

question =
  Message.user([
    ContentBlock.text("Name the image colour and quote the PDF text."),
    ContentBlock.image(data: Base.encode64(File.read!("examples/fixtures/red-square.png")), mime_type: "image/png"),
    ContentBlock.file(
      data: Base.encode64(File.read!("examples/fixtures/sample.pdf")),
      mime_type: "application/pdf",
      filename: "sample.pdf"
    )
  ])

{:ok, reply} = ChatModel.invoke(model, [question])
text = reply |> Message.text() |> String.downcase()
true = text =~ "red"
true = text =~ "dummy"
```

Download [the image](../assets/fixtures/red-square.png) and
[the PDF](../assets/fixtures/sample.pdf) into the same relative paths for a consumer app. Remote media URLs must be
fetchable by Z.ai. Tool-returned media is carried in a following user message.
For video, save [the MP4 fixture](../assets/fixtures/red-square.mp4) as
`examples/fixtures/red-square.mp4`, then run:

```elixir
video = ContentBlock.video(
  data: Base.encode64(File.read!("examples/fixtures/red-square.mp4")),
  mime_type: "video/mp4"
)
{:ok, reply} = ChatModel.invoke(model, [Message.user([ContentBlock.text("What single colour fills this video?"), video])])
true = reply |> Message.text() |> String.downcase() |> String.contains?("red")
```

## Upload and remove a file

The Files endpoint is used directly; BeamWeaver's chat option consumes the
actual returned ID:

```elixir
files_url = "https://api.z.ai/api/paas/v4/files"
headers = [{"authorization", "Bearer " <> System.fetch_env!("ZAI_API_KEY")}]

upload =
  Req.post!(files_url,
    headers: headers,
    form_multipart: [purpose: "user_data", file: {File.read!("examples/fixtures/sample.pdf"), filename: "sample.pdf"}],
    retry: false,
    receive_timeout: 60_000
  )

true = upload.status in 200..299
file_id = Map.fetch!(upload.body, "id")

try do
  question = Message.user([ContentBlock.text("Quote the PDF text."), ContentBlock.file(file_id: file_id)])
  {:ok, reply} = ChatModel.invoke(model, [question])
  true = reply |> Message.text() |> String.downcase() |> String.contains?("dummy")
after
  deleted = Req.delete!(files_url <> "/" <> URI.encode(file_id), headers: headers, retry: false)
  true = deleted.status in 200..299
end
```

Do not copy account-specific IDs into examples or reuse resources from another
account. Your application owns upload lifetime and cleanup.

## Errors and limits

Content filtering and billing exhaustion are not transient retry targets.
Provider codes remain in error details. Network/resource finish reasons can
normalize to errors even after an HTTP-success response. A streamed inference
failure is not a successful partial answer.

`count_tokens/3` is a local estimate here, not a provider counting request.
Native hosted tools and non-chat operations are outside the wrapper.

## Models

Limits are local profile data. A dash means not applicable or not recorded,
not an unlimited allowance.

| Model | Input / output tokens | Operations and capabilities |
| --- | --- | --- |
| `zai:glm-4.6` | 200,000 / 131,072 | chat; text; tools; structured output; reasoning |
| `zai:glm-4.7` | 200,000 / 131,072 | chat; text; tools; structured output; reasoning |
| `zai:glm-5` | 200,000 / 131,072 | chat; text; tools; structured output; reasoning |
| `zai:glm-5.1` | 200,000 / 131,072 | chat; text; tools; structured output; reasoning |
| `zai:glm-5.2` | 1,000,000 / 131,072 | chat; text; tools; structured output; reasoning |
| `zai:glm-5.3` | 1,000,000 / 131,072 | chat; text; tools; structured output; reasoning |
| `zai:glm-5.3-flash` | 1,000,000 / 131,072 | chat; text, image, PDF, video; tools; structured output; reasoning |
| `zai:glm-5.3-flashx` | 1,000,000 / 131,072 | chat; text, image, PDF, video; tools; structured output; reasoning |


This table reflects local profiles. Live access and limits depend on your
account and selected endpoint.

## Further reading

The official [file API](https://docs.z.ai/api-reference/agents/file-upload) describes upload requirements. [Testing](../testing.md) covers deterministic application tests.
