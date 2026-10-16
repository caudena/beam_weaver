# Coming from LangChain

This page is for developers who know LangChain, LangGraph or Deep Agents in
Python and want to build the same kind of application in Elixir. It maps each
familiar concept to its place in BeamWeaver and lists what works differently
on purpose. BeamWeaver is not affiliated with LangChain.

Here is a support agent with one tool, in LangChain:

```python
from langchain.agents import create_agent
from langchain.tools import tool


@tool
def lookup_order(order_id: str) -> str:
    """Look up the shipping status of an order by its id."""
    return f"Order {order_id} shipped on Monday."


agent = create_agent(
    model="anthropic:claude-haiku-4-5",
    tools=[lookup_order],
    system_prompt="You are Acme's support agent. Look orders up before you answer.",
)

result = agent.invoke({"messages": [{"role": "user", "content": "Where is my order A-1001?"}]})
```

In BeamWeaver, the tool and the agent are modules. A scripted `"fake:chat"`
model stands in for Claude, so this example runs without an API key:

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

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday."
    ]

  system_prompt "You are Acme's support agent. Look orders up before you answer."
  tools [MyApp.Tools.LookupOrder]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
result.messages |> List.last() |> BeamWeaver.Core.Message.text()
#=> "Your order A-1001 shipped on Monday."
```

The docstring and type hints become `description` and `schema`, and the
arguments of `create_agent` become declarations. Write
`model "anthropic:claude-haiku-4-5"` to use the real model; the
[Quickstart](quickstart.md) walks through the rest.

## Concept map

| LangChain or LangGraph | BeamWeaver | Guide |
| --- | --- | --- |
| `create_agent(...)` | a module with `use BeamWeaver.Agent` | [Agents](agents.md) |
| `init_chat_model("provider:model")` | `BeamWeaver.Models.init_chat_model/2`, with the same model strings | [Models](models.md) |
| `model.invoke`, `model.batch`, `model.stream` | `BeamWeaver.Core.ChatModel.invoke/3`, `batch/3`, `stream_typed_events/3` | [Models](models.md) |
| `model.with_structured_output(...)` | `BeamWeaver.Models.with_structured_output/3` | [Structured Output](structured_output.md) |
| `HumanMessage`, `AIMessage`, `ToolMessage` | one `%BeamWeaver.Core.Message{}` struct with a `role` | [Messages](messages.md) |
| `trim_messages`, `filter_messages` | `BeamWeaver.Core.Messages.Utils` | [Messages](messages.md) |
| `@tool` | a module with `use BeamWeaver.Tool` | [Tools](tools.md) |
| `StructuredTool.from_function` | a tool built at runtime from a JSON Schema and a function | [Tools](tools.md#tools-built-at-runtime) |
| `ToolRuntime`, `InjectedState`, `InjectedToolCallId` | `injected :name, :source` in a tool | [Tools](tools.md) |
| Pydantic model or `TypedDict` as a schema | a module with `use BeamWeaver.Schema` | [Structured Output](structured_output.md) |
| `ToolStrategy`, `ProviderStrategy` | `response_schema MyApp.Schemas.Triage, strategy: :tool` | [Structured Output](structured_output.md) |
| `context_schema` and `context=` | `context_schema do ... end` and `context:` | [Runtime Context](runtime_context.md) |
| `AgentMiddleware`, `@before_model`, `@wrap_model_call` | a module with `use BeamWeaver.Agent.Middleware` | [Middleware](middleware.md) |
| `SummarizationMiddleware`, `PIIMiddleware`, `ModelRetryMiddleware` | `Summarization`, `PII`, `ModelRetry` under `BeamWeaver.Agent.Middleware` | [Built-in Middleware](builtin_middleware.md) |
| `HumanInTheLoopMiddleware(interrupt_on=...)` | `interrupt_on %{"issue_refund" => true}`, resumed with `resume_review/2` | [Human-in-the-Loop](human_in_the_loop.md) |
| `InMemorySaver`, `PostgresSaver` | `BeamWeaver.Checkpoint.ETS`, `BeamWeaver.Checkpoint.Ecto` | [Checkpoints](checkpoints.md) |
| `InMemoryStore`, `PostgresStore` | `BeamWeaver.Memory.ETS`, `BeamWeaver.Memory.Ecto` | [Long-Term Memory](long_term_memory.md) |
| `StateGraph`, `START`, `END` | `BeamWeaver.Graph.new/1`, `Graph.start()`, `Graph.end_node()` | [Graphs](graphs.md) |
| `add_conditional_edges` | `Graph.add_edge/4` with `when:`, or a node that returns a `Command` | [Graphs](graphs.md) |
| `Command`, `Send` | `%BeamWeaver.Graph.Command{}`, `%BeamWeaver.Graph.Send{}` | [Graphs](graphs.md) |
| `Annotated` reducers, `add_messages` | `Graph.add_reducer/3`, `BeamWeaver.Graph.Messages.state_schema/1` | [Graph State](graph_state.md) |
| `interrupt()`, `Command(resume=...)` | `BeamWeaver.Graph.interrupt/1`, `resume/2` | [Human-in-the-Loop](human_in_the_loop.md) |
| `get_state_history`, `update_state` | `BeamWeaver.Graph.Compiled.get_state_history/3`, `BeamWeaver.Graph.Compiled.update_state/4` | [Checkpoints](checkpoints.md) |
| `stream_mode="updates"`, `"messages"`, `"custom"` | `stream_events/2` with `stream_mode: :updates` (or `:messages`, `:custom`, a list of them) | [Streaming](streaming.md) |
| `RetryPolicy`, `CachePolicy` | the `retry:`, `timeout:` and `cache:` options of a node | [Graphs](graphs.md#node-options) |
| Embeddings, vector stores, retrievers | `BeamWeaver.Models.init_embeddings/2`, `BeamWeaver.VectorStore`, `BeamWeaver.Retriever` | [Retrieval](retrieval.md) |
| Prompt templates, output parsers | `BeamWeaver.Prompt`, `BeamWeaver.OutputParser` | [Prompts and Parsers](prompts_and_parsers.md) |
| LCEL chains | `BeamWeaver.Runnable.sequence/2`, or a function that formats the prompt, calls the model and parses the reply | [Prompts and Parsers](prompts_and_parsers.md#prompt-model-and-parser) |
| `GenericFakeChatModel`, fake embeddings | `"fake:chat"`, `"fake:embedding"` | [Testing](testing.md) |
| LangSmith | `BeamWeaver.Tracing`, with export to WeaveScope | [Tracing](tracing.md) |

## Deep agents

There is no `create_deep_agent`. A deep agent is an ordinary agent module,
and each option of `create_deep_agent` is a declaration:

| `create_deep_agent` option | BeamWeaver declaration | Guide |
| --- | --- | --- |
| `model`, `tools`, `system_prompt`, `middleware` | `model`, `tools`, `system_prompt`, `middleware` | [Agents](agents.md) |
| `subagents` | `subagents do subagent MyApp.PolicyExpert end`; `async_subagents` for remote agents | [Subagents](subagents.md) |
| `skills` | `skills ["/skills"]` | [Skills](skills.md) |
| `memory` | `memory ["/AGENTS.md"]` | [Memory Files](memory_files.md) |
| `backend` | `filesystem BeamWeaver.Filesystem.State.new()` | [Filesystem](filesystem.md) |
| `permissions` | `filesystem_permissions [...]` | [Filesystem](filesystem.md) |
| `interrupt_on` | `interrupt_on %{"issue_refund" => true}` | [Human-in-the-Loop](human_in_the_loop.md) |
| `response_format` | `response_schema MyApp.Schemas.Triage` | [Structured Output](structured_output.md) |
| `context_schema` | `context_schema do ... end` | [Runtime Context](runtime_context.md) |
| `checkpointer`, `store` | the `checkpointer:` and `store:` options of each call, or declarations for database storage | [Checkpoints](checkpoints.md) |
| `name`, `cache` | `name`, `cache` | [Agents](agents.md) |
| `debug` | no declaration; watch a run with streaming or tracing | [Tracing](tracing.md) |

`create_deep_agent` always adds planning, file tools, a `general-purpose`
subagent and summarization, plus prompt caching for Anthropic models. A
BeamWeaver agent starts without them, and you declare the ones you want:

```elixir
defmodule MyApp.PolicyExpert do
  use BeamWeaver.Agent

  name "policy_expert"
  description "Answers questions about Acme's refund and return policies."
  model "anthropic:claude-haiku-4-5"
end

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  model "anthropic:claude-sonnet-4-6"
  system_prompt "Research a customer's problem across orders and policies, then write up an answer."
  tools [MyApp.Tools.LookupOrder]

  middleware [BeamWeaver.Agent.Middleware.TodoList]
  filesystem BeamWeaver.Filesystem.State.new()
  compact_conversation true
  prompt_caching true

  subagents do
    subagent MyApp.PolicyExpert
  end
end
```

`subagents` adds the `task` tool with a `general-purpose` subagent next to
yours. The backends map to filesystems: `StateBackend` is
`BeamWeaver.Filesystem.State`, `FilesystemBackend` is
`BeamWeaver.Filesystem.Local`, `StoreBackend` is `BeamWeaver.Filesystem.Store`
and `CompositeBackend` is `BeamWeaver.Filesystem.Composite`. Sandboxes plug in
through `BeamWeaver.Filesystem.Sandbox` (see [Sandboxes](sandboxes.md)).

## What stays the same

- Model strings look the same: `"anthropic:claude-haiku-4-5"`,
  `"openai:gpt-5.4-mini"`.
- An agent is a graph underneath, so checkpoints, interrupts and streaming
  work the same way for agents and graphs.
- Middleware has the same six hooks, with the same names and order:
  `before_agent`, `before_model`, `wrap_model_call`, `after_model`,
  `wrap_tool_call` and `after_agent`.
- Tool review uses the same shapes: `allowed_decisions`, a review with
  `action_requests` and `review_configs`, and the decisions approve, edit and
  reject, plus respond.
- A thread is still picked with
  `config: %{"configurable" => %{"thread_id" => "ticket-42"}}`.
- Graphs run in steps, nodes return the keys they change, reducers merge
  updates, the default recursion limit is 25, and a node that called
  `interrupt` runs again from its start on resume.
- Deep agent tools keep their names (`write_todos`, `ls`, `read_file`,
  `write_file`, `edit_file`, `glob`, `grep`, `execute` and `task`), skills are
  folders with a `SKILL.md`, and memory files are Markdown such as
  `/AGENTS.md`.

## What is different on purpose

- **No functional API.** There is no `@entrypoint` or `@task`. Write plain
  functions, and make a step a graph node when it must survive a restart: a
  node is what BeamWeaver checkpoints, retries and resumes.
- **Processes, not async.** There is no `ainvoke` or `astream`. A call blocks
  the process that makes it, which is cheap on the BEAM, and
  `Task.async_stream/3` runs calls in parallel. Parallel graph branches and a
  model's parallel tool calls already run in their own processes.
- **String keys from the model.** A tool's `invoke/3` receives
  `%{"order_id" => "A-1001"}`, as the model sent it in JSON, and injected
  values such as `context` arrive under atom keys. A structured answer is a
  map with string keys, not an object.
- **One message struct.** Roles are the atoms `:system`, `:user`,
  `:assistant` and `:tool`. `BeamWeaver.Core.Message.from/1`, prompt
  templates and a graph's messages key don't accept the role names `"human"`
  and `"ai"`, so convert them when you import stored conversations or
  prompts.
- **Subgraphs pass back their changes.** A subgraph added as a node returns
  the keys it changed, not its whole state: a list key with a reducer gets only
  what the subgraph appended, so the parent's list is not added twice.
- **Errors are values.** Calls return `{:ok, result}`,
  `{:interrupted, interrupt}` or `{:error, %BeamWeaver.Core.Error{}}`. Retry
  middleware matches error types such as `:rate_limit`, not exception classes.
- **Interrupts are results.** A paused run returns `{:interrupted, interrupt}`
  instead of an `__interrupt__` key. `resume/2` continues it, and
  `resume_review/2` continues a tool approval with the reviewer's decisions.
  `BeamWeaver.Graph.interrupt/1` works in graph nodes but not inside tools;
  to pause before a tool runs, use `interrupt_on`.
- **One event stream.** `stream_events/2` returns typed events for tokens,
  tools, updates and your own payloads, subgraphs included. There is no
  `version` or `subgraphs=True`; `stream_mode:` takes atoms such as
  `[:messages, :updates]`, and `live: true` reads events while the run works.
- **No `state_schema` on agents.** A middleware declares the state keys it
  uses with `state_schema/1`, and a tool changes state by returning a
  `BeamWeaver.Graph.Command`.
- **Explicit retries and limits.** Providers don't retry failed calls: add
  `ModelRetry`. `ModelCallLimit` and `ToolCallLimit` have no default limit:
  set `run_limit`, `thread_limit` or both.
- **PII rules edit before the reply is saved.** `PII` edits the same message
  text as `PIIMiddleware` and leaves tool-call arguments, reasoning and
  metadata alone, but an output rule edits the reply inside the model call,
  so no checkpoint holds the raw text. A stream isn't redacted on its own:
  pass it through `PII.stream_transform/1`.
- **Context is per call.** `context:` is not saved with the thread, so pass it
  again on every call, including `resume/2`.
- **No hosted platform.** There is no agent server, `langgraph.json` or
  Studio: agents and graphs run in your own supervision tree. Tables for
  checkpoints and stores come from Ecto migrations (see [Storage](storage.md)).

## Reference

- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): agent modules and their declarations
- [`BeamWeaver.Tool`](https://hexdocs.pm/beam_weaver/BeamWeaver.Tool.html): tool modules
- [`BeamWeaver.Agent.Middleware`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.html): the middleware hooks
- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): graphs, commands and interrupts
- [`BeamWeaver.Models`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.html): chat and embedding models from model strings
- [`BeamWeaver.Core.Message`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.Message.html): the message struct
