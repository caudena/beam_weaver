# DeepSeek

Use DeepSeek chat through Chat Completions (default) or Responses. Responses
adds native schema output and hosted search on V4 Pro; the endpoints do not have
identical state or tool contracts.

## Setup and first request

In your application's `config/runtime.exs`:

```elixir
import Config
config :beam_weaver, :deepseek, api_key: System.fetch_env!("DEEPSEEK_API_KEY")
```

```elixir
alias BeamWeaver.Core.{ChatModel, Message}
{:ok, model} = BeamWeaver.Models.init_chat_model("deepseek:deepseek-flash", max_tokens: 1_024, timeout: 120_000)
{:ok, reply} = ChatModel.invoke(model, "Explain parcel tracking in one sentence.")
true = byte_size(Message.text(reply)) > 0
true = reply.usage_metadata.total_tokens > 0
```

Use the same identifier in an agent's `model` declaration. Preserve complete
messages across tool rounds so required reasoning content can be replayed.

## Endpoint and reasoning choices

| Setting | Meaning |
| --- | --- |
| `api: :chat_completions` | Default chat endpoint |
| `api: :responses` | Responses endpoint with its own supported fields |
| `thinking:` | Enabled/disabled on Chat Completions |
| `reasoning_effort:` | Model-supported low/high/max; none disables thinking |
| `reasoning:` | Responses reasoning map |
| `beta:` | Beta request routing |
| `base_url:` | Native API root or gateway |

Thinking is enabled by default. Forced tool choice requires thinking disabled
where supported. Native Responses conversation IDs are not supported here:
DeepSeek receives full history each turn. Chat Completions uses JSON-object
mode with schema instructions/local checks; Responses supports native JSON
Schema. See [Structured Output](../structured_output.md) for validation limits.

On Flash, `top_p` takes effect in thinking mode and values below 0.95 are
treated as 0.95; non-thinking mode fixes it at 1.0. Chat Completions requires
`0 < top_p <= 1`. Streaming usage arrives on the last content chunk with its
finish reason, followed by `[DONE]`; a separate usage-only chunk is not required.

## Images

Flash supports image input; the V4 Pro profile is text-only. From a repository
checkout, use the bundled fixture:

```elixir
alias BeamWeaver.Core.ContentBlock

question =
  Message.user([
    ContentBlock.text("Name the single color filling this image."),
    ContentBlock.image(data: Base.encode64(File.read!("examples/fixtures/red-square.png")), mime_type: "image/png")
  ])

{:ok, reply} = ChatModel.invoke(model, [question])
true = reply |> Message.text() |> String.downcase() |> String.contains?("red")
```

Images are supported media here; PDF/audio/video input are not. Download/copy
[the image fixture](../assets/fixtures/red-square.png)
into the same relative path when running outside a checkout.

## Responses and hosted tools

Hosted web search is supported on V4 Pro; Flash ignores that declaration.
Use the supported model and inspect the preserved native search item:

```elixir
{:ok, responses} =
  BeamWeaver.Models.init_chat_model("deepseek:deepseek-v4-pro", api: :responses, max_tokens: 2_048, timeout: 120_000)

{:ok, reply} =
  ChatModel.invoke(
    responses,
    "Use web search to find the official Elixir programming language website. Return its URL.",
    tools: [BeamWeaver.DeepSeek.Tools.web_search()],
    tool_choice: %{type: "web_search"}
  )

true = byte_size(Message.text(reply)) > 0
true = Enum.any?(List.wrap(reply.content), &(Map.get(&1, :provider_type) == "web_search_call"))
```

`apply_patch` declares a client action; your application must implement the
executor. A declaration alone does not edit files. Beta routing also supports
strict function tools and prefix completion where the selected model allows it.

## Raw client

`DeepSeek.Client` exposes Search, Fetch, FIM completions, model discovery and account balance.

### Search and Fetch

The standalone endpoints work independently of the chat model. Create a client
from the configured DeepSeek credentials and send native request bodies:

```elixir
search_client = BeamWeaver.DeepSeek.Client.new(timeout: 60_000)
{:ok, search} = BeamWeaver.DeepSeek.Client.search(search_client, %{
  query: "Elixir site:elixir-lang.org",
  count: 5,
  need_content: true
})
true = is_list(search["results"])
{:ok, page} = BeamWeaver.DeepSeek.Client.fetch(search_client, %{url: "https://elixir-lang.org/"})
true = is_binary(page["content"])
```

`POST /v1/tools/search` and `POST /v1/tools/fetch` each cost **$0.75 per 1,000
successful requests**. Search is billable only with non-empty `results`; Fetch
requires returned page content. Failures, empty results and timeouts are free.
These are request charges, separate from model token usage. The temporary free
period through October 31 applies to server-side calls through DeepSeek Harness,
Claude Code and Codex, rather than direct standalone API calls. See the
[Search & Fetch guide](https://api-docs.deepseek.com/guides/search/) and
[pricing](https://api-docs.deepseek.com/quick_start/pricing/).

### FIM completions

FIM runs without thinking. This complete call checks actual generated code:

```elixir
client = BeamWeaver.DeepSeek.Client.new()

{:ok, completion} =
  BeamWeaver.DeepSeek.Client.completions(client, %{
    "model" => "deepseek-flash",
    "prompt" => "def add(a, b):\n    ",
    "suffix" => "\n",
    "max_tokens" => 64
  })

[text | _] = for choice <- completion["choices"], do: choice["text"]
true = is_binary(text) and byte_size(text) > 0
```

The [complete DeepSeek script](https://github.com/caudena/beam_weaver/blob/master/examples/deepseek.exs)
also exercises the Anthropic-style endpoint. Native account APIs are separate
from agent inference.

## Errors, caching and limits

Resource-exhaustion/aborted finish reasons normalize to server errors rather
than successful truncated answers. Content-filtered replies can remain replies;
inspect the outcome. Retry only within a deliberate budget.

Repeated prefix caching is automatic; inspect reported cache-read tokens.
There is no prompt-cache key added by BeamWeaver's caching middleware.
Request `metadata:` is unsupported; use trace metadata for application labels.

Time-based cost estimates use the registered UTC weekday pricing windows. They
do not include a Chinese public-holiday calendar; consult DeepSeek's
[pricing](https://api-docs.deepseek.com/quick_start/pricing/) for holiday exceptions.

## Models

Limits are local profile data. A dash means not applicable or not recorded,
not an unlimited allowance.

| Model | Input / output tokens | Operations and capabilities |
| --- | --- | --- |
| `deepseek:deepseek-flash` | 1,048,576 / 393,216 | chat; text, image; tools; structured output; reasoning |
| `deepseek:deepseek-v4-flash` | 1,048,576 / 393,216 | chat; text, image; tools; structured output; reasoning |
| `deepseek:deepseek-v4-flash-vision-exp` | 1,048,576 / 393,216 | chat; text, image; tools; structured output; reasoning |
| `deepseek:deepseek-v4-pro` | 1,048,576 / 393,216 | chat; text; tools; structured output; reasoning |


`deepseek-flash` serves DeepSeek V4.1-Flash-1017. The older V4 Flash identifiers
remain accepted aliases for the same model. Pinning an alias does not freeze
the provider's underlying model revision.

## Further reading

The official [tool-call contract](https://api-docs.deepseek.com/guides/tool_calls/) describes the native exchange. Use [Testing](../testing.md) for deterministic failure cases.
