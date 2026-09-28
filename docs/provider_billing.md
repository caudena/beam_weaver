# Provider Billing Observations

BeamWeaver preserves provider usage needed for cost analysis. Chat responses
record OpenAI hosted web/image/code calls, Gemini grounding query evidence, and
Anthropic code-execution calls and container IDs. These counts are observations,
not provider-billed totals: Gemini allowances and runtime/storage fees span
multiple responses and can span multiple applications.

When several BeamWeaver projects use one provider billing account, identify it
with a non-secret provider project or workspace reference in trace metadata:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, messages,
  trace: [metadata: %{provider_account_ref: "provider-project-id"}]
)
```

Do not place API keys in trace metadata.

## Direct OpenAI image generation

`BeamWeaver.OpenAI.generate_image/2` calls the Images API and emits a generation
run with the requested image model and the response's text/image token usage.
The returned image bytes are passed to the caller but excluded from the trace.

```elixir
{:ok, response} =
  BeamWeaver.OpenAI.generate_image("A blue square on white",
    model: "gpt-image-2.5-flare",
    quality: "low",
    size: "1024x1024"
  )

image = hd(response["data"])["b64_json"]
```

Responses API image-generation tool usage remains separate from the mainline
model's token usage. OpenAI does not return cached image-tool input counts, so
input cost derived from tool usage is an estimate.

## Account resource snapshots

`BeamWeaver.Provider.BillingSnapshot.fetch/2` uses the normal provider API key
to read one page of current resources:

```elixir
{:ok, openai} = BeamWeaver.Provider.BillingSnapshot.fetch(:openai, api_key: openai_key)
{:ok, google} = BeamWeaver.Provider.BillingSnapshot.fetch(:google, api_key: google_key)
{:ok, claude} = BeamWeaver.Provider.BillingSnapshot.fetch(:anthropic, api_key: claude_key)
```

- OpenAI: container memory, creation/activity/status, and vector-store bytes.
- Google: explicit cache model, token count, creation, and expiry.
- Anthropic: Managed Agents session cumulative `list_cost` and `active_seconds`.

Each result includes `observed_at` and pagination metadata. The snapshot never
contains an API key, image bytes, cached content, or session conversation.
Consumers must retain snapshots and follow cursors; a later snapshot cannot
recover a resource created and deleted between polls. `usage.list_cost` is the
authoritative Managed Agents session cost and already includes runtime.

The opt-in `scripts/provider_billing_live.exs` probe uses live provider calls
and prints selected billing fields. Run one case at a time with the matching
provider API key available; it is excluded from normal `mix test`. Cases cover
Search/Maps, code and image tools, direct Images API, cache lifecycle, and
resource snapshots. The probe deletes the resources it creates where the API
provides deletion.

Use [WeaveScope's account meter](https://weavescope.com) or your own accounting
code to apply shared allowances and resource-time rates across the provider
billing account. Provider invoices remain final. Pricing and behavior:
[OpenAI](https://developers.openai.com/api/docs/pricing),
[Anthropic](https://platform.claude.com/docs/en/about-claude/pricing), and
[Gemini](https://ai.google.dev/gemini-api/docs/pricing).
