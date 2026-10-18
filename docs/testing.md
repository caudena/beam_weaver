# Testing Your Application

Use deterministic models to test your application's decisions, tool execution,
state and failure handling. Use live integrations to check the actual provider,
model and credentials. They answer different questions; neither replaces the
other.

Fake models are introduced here specifically for tests. Product guides use
real providers or ordinary deterministic Elixir workflows.

## Test an agent with ExUnit

Save this complete module as `test/support_agent_test.exs`. A normal Mix test
project already starts ExUnit in `test/test_helper.exs`; run it with
`mix test test/support_agent_test.exs`.

```elixir
defmodule MyApp.SupportAgentTest do
  use ExUnit.Case, async: true
  alias BeamWeaver.Core.Message

  defmodule Lookup do
    use BeamWeaver.Tool
    name "lookup_order"
    description "Read the test order."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, %{"order_id" => "A-1001"}, _opts), do: {:ok, "Thursday"}
  end

  defmodule SupportAgent do
    use BeamWeaver.Agent
    alias BeamWeaver.Models.FakeChatModel

    model "fake:chat",
      responses: [
        FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
        "The order arrives Thursday.",
        "You asked about A-1001."
      ],
      parent: self()

    system_prompt "Look up orders before answering."
    tools [MyApp.SupportAgentTest.Lookup]
  end

  test "executes the requested action and preserves its result" do
    {:ok, result} = SupportAgent.invoke(%{messages: ["Check A-1001."]})
    [_, request, tool_result, answer] = result.messages
    [call] = request.tool_calls
    assert call.args == %{"order_id" => "A-1001"}
    assert tool_result.tool_call_id == call.id
    assert Message.text(tool_result) == "Thursday"
    assert Message.text(answer) == "The order arrives Thursday."
    assert_received {:fake_chat_model_call, [system | _], opts}
    assert Message.text(system) =~ "Look up orders"
    assert Enum.any?(opts[:tools], &(BeamWeaver.Core.Tool.name(&1) == "lookup_order"))
  end

  test "continues only the selected thread" do
    saver = BeamWeaver.Checkpoint.ETS.new()
    opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "order"}}]
    {:ok, first} = SupportAgent.invoke(%{messages: ["Check A-1001."]}, opts)
    {:ok, second} = SupportAgent.invoke(%{messages: ["What did I ask?"]}, opts)
    assert length(second.messages) > length(first.messages)
    assert Message.text(List.last(second.messages)) == "You asked about A-1001."
  end
end
```

Exact text assertions are appropriate for scripted fixtures. For live model
answers, check required facts, schema, tool arguments and side effects rather
than one wording. Do not count a requested tool call as executed unless its
successful result or observable side effect exists.

## Script the model

`FakeChatModel` supports text, complete messages, `tool_call/2`,
`tool_calls/1` and `final/1` structured answers. Each entry is a model turn.
The conversation's `metadata.fake_turn` advances the script; a new conversation
starts over, and the last entry repeats after exhaustion.

Extra calls from retries or structured formatting affect turn position.
Inspect `fake_turn` if a test receives the wrong scripted answer.
`usage_metadata:` supplies fixture counters; those counters are not evidence
of provider billing or a cache hit.

## Check what the model received

`parent: self()` sends `{:fake_chat_model_call, messages, opts}` to the caller
for each request. Agent model declarations evaluate in the invoking process,
so it identifies the test process. Assert the prompt, offered tools and
request options that matter to your application.

For streaming, put `stream: true` on the agent model declaration. The fake
reports `:fake_chat_model_stream` and emits deterministic word chunks.
Real provider chunks can split anywhere, so consumer code should not depend
on those fixture boundaries.

A constructed fake can record one direct invocation in the current process:

```elixir
model = BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["Ready."], parent: self())
{:ok, _reply} = BeamWeaver.Core.ChatModel.invoke(model, "Hello")

receive do
  {:fake_chat_model_call, messages, _opts} ->
    "Hello" = BeamWeaver.Core.Message.text(List.last(messages))
after
  1_000 -> raise "No model invocation was observed"
end
```

## Simulate provider failures

A configured `error:` fails every request. This example proves the retry
budget by counting observed attempts:

```elixir
import ExUnit.Assertions

defmodule MyApp.OutageAgent do
  use BeamWeaver.Agent
  model "fake:chat", error: BeamWeaver.Core.Error.new(:rate_limit, "Busy"), parent: self()
  middleware [{BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 2}]
end

{:error, error} = MyApp.OutageAgent.invoke(%{messages: ["Hello"]})
:rate_limit = error.type
for _ <- 1..3, do: assert_received({:fake_chat_model_call, _, _})
refute_received {:fake_chat_model_call, _, _}
```

Also test nonretryable errors, exhausted limits and fallback selection. Use
zero delays in deterministic test policy rather than adding sleeps to make
assertions pass. Verify which provider/model supplied a live fallback result.

## Choose the model from config

A production agent can read your application's model setting in its `model`
declaration. Set a real provider in runtime config and a scripted model in
test config. If a test changes application environment at runtime, restore
its prior value on exit and use `async: false`, because that environment is
node-wide.

Prefer explicit constructed agents/models or per-test dependencies when you
can avoid shared configuration. New savers/stores belong in each test's setup;
their ETS tables disappear with the test owner. Never create shared mutable
resources inside a declaration evaluated for every invocation.

## Test tools and middleware

Call `Core.Tool.invoke/3` with string-keyed model arguments and explicit
atom-keyed injected values. Check argument validation and actual data access.
Call middleware hooks with a state/runtime or a request/handler fixture, then
exercise important ordering through an agent.

Only use `async: true` when the whole test is isolated. Fake models alone do
not make shared named processes, registries, files or application config safe
for concurrent tests.

## Emulate tools with side effects

`ToolEmulator` replaces selected action execution with a scripted/model-generated
result. Specify `tools:` narrowly; without it every tool can be emulated.
Mark and inspect `metadata.emulated?` so an emulator cannot be mistaken for a
successful real integration. Model-generated emulator output is invented test
data, not evidence that a payment, message or external write occurred.

For unit tests, an injected application dependency or a deterministic handler
is often simpler. Keep real external side-effect tests in an explicitly
controlled integration environment.

A tool emulator replaces only the selected side effect. The real tool raises here so the example fails if it is accidentally executed:

```elixir
defmodule MyApp.Tools.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund an order to the customer's card."

  schema do
    field :order_id, :string
  end

  # The real tool calls the payment provider.
  @impl true
  def invoke(_tool, _args, _opts), do: raise("tests must not issue real refunds")
end

defmodule MyApp.RefundAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.ToolEmulator
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001"}), "Your refund is on its way."]

  tools [MyApp.Tools.IssueRefund]

  middleware [
    {ToolEmulator,
     tools: ["issue_refund"], model: BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["Refunded A-1001."])}
  ]
end

{:ok, result} = MyApp.RefundAgent.invoke(%{messages: ["Please refund order A-1001."]})
refund = Enum.find(result.messages, &(&1.role == :tool))
{BeamWeaver.Core.Message.text(refund), refund.metadata.emulated?}
#=> {"Refunded A-1001.", true}
```

## Test streaming

Consume a live stream once. Assert relevant typed events and final outcomes,
including terminal errors, retries and interrupts. An enumerable returned
without consumption has performed no work. A model `Done` event does not
necessarily finish an agent's multi-turn run. [Streaming](streaming.md) defines
ownership and cancellation behavior.

For application consumer tests, deterministic word chunks let you assert the emitted sequence:

```elixir
defmodule MyApp.StreamingAgent do
  use BeamWeaver.Agent

  model "fake:chat", stream: true, responses: ["Your order A-1001 shipped on Monday."]
end

{:ok, events} = MyApp.StreamingAgent.stream_events(%{messages: ["Where is my order A-1001?"]})

for %{event: %BeamWeaver.Stream.Events.Token{text: text}} <- events, do: text
#=> ["Your ", "order ", "A-1001 ", "shipped ", "on ", "Monday."]
```

## Test graphs and human review

Test node functions directly, then representative routes and joins. Validate
parallel reducers and partial-failure continuation. For human review, assert
the initial interrupt, pending arguments, unchanged side-effect state before
approval and actual approved/rejected behavior after resume.

Use the production storage adapter for persistence/restart integration checks.
An ETS-only test cannot prove database migrations or cross-process durability.

## Fake embeddings

`fake:embedding` deterministically maps text to vectors without semantic meaning.
Use it to test indexing plumbing, IDs and error handling. Its `parent:` option
reports embedded query/document inputs; `dimensions:` controls fixture shape.
Use real embeddings and known relevant/irrelevant sources to assess ranking,
as in [Retrieval](retrieval.md).

Fake vectors verify wiring and requested operations, not semantic relevance:

```elixir
import ExUnit.Assertions
alias BeamWeaver.VectorStore

{:ok, embeddings} = BeamWeaver.Models.init_embeddings("fake:embedding", parent: self())
store = VectorStore.ETS.new(embedding: embeddings)

{:ok, _ids} = VectorStore.add_texts(store, ["Refunds take 5 business days.", "Orders ship within 2 days."])
{:ok, results} = VectorStore.similarity_search(store, "How long do refunds take?", k: 1)

assert_received {:fake_embedding_query, "How long do refunds take?", _opts}
length(results)
#=> 1
```

## Replay provider responses

Replay tests the adapter's request shape and decoding without contacting the
provider. This complete cassette uses synthetic nonsecret content:

```elixir
cassette = """
requests:
- method: POST
  uri: https://api.openai.com/v1/responses
  body: '{"model": "gpt-5.4-mini", "stream": false, "input": [{"type": "message", "role": "user", "content": "Where is my order A-1001?"}]}'
responses:
- status: {code: 200, message: OK}
  headers: {content-type: [application/json]}
  body:
    string: '{"status": "completed", "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Order A-1001 shipped on Monday."}]}]}'
"""

path = Path.join(System.tmp_dir!(), "beam-weaver-cassette-#{System.unique_integer([:positive])}.yml")
File.write!(path, cassette)

try do
  {:ok, model} =
    BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini",
      api_key: "test-key",
      transport: BeamWeaver.Transport.Replay,
      transport_opts: [cassette_path: path]
    )

  {:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Where is my order A-1001?")
  "Order A-1001 shipped on Monday." = BeamWeaver.Core.Message.text(reply)
  {:error, error} = BeamWeaver.Core.ChatModel.invoke(model, "A different question")
  :cassette_mismatch = error.details.reason
after
  File.rm!(path)
end
```

Matching compares method, URL and JSON body, independent of JSON key order.
Headers are not matched; never retain credentials in cassettes. Gzipped YAML
is supported. A mismatch returns request/expected details to help diagnose the
fixture. BeamWeaver does not include an automatic recorder.

Replay success proves the stored interaction was matched and decoded. It does
not prove the model still exists, the credential works or the live endpoint
accepts that request.

## Live integration checks

Check real provider response and model identity, nonempty/structured output,
required tool arguments/results, stream completion and any storage or artifact
changes. Do not silently fall back to another provider while claiming the
selected one passed. Keep missing credentials and unavailable resources
visible as incomplete verification.

The repository's existing `mix examples.live` and `mix docs.verify` commands
run examples separately from the library test suite. [Examples](examples.md)
explains their selectors and reports. No documentation-specific tests need to
be installed in your application.
