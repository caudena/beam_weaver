# Tools

Tools let models and agents take actions: search data, call internal services,
run policy-governed commands, update graph state, and return observations to the
model.

BeamWeaver tools are normal Elixir values that implement
`BeamWeaver.Core.Tool`. You can create them at runtime with
`BeamWeaver.Core.Tool.from_function!/1`, define stable application tools with
`use BeamWeaver.Tool`, or implement the behaviour directly.

{% hint style="info" %}
**Tool Definition**

LangChain's Python docs start with the `@tool` decorator because Python can
attach schema metadata to function objects. Elixir functions are not mutable
metadata containers, and compile-time macros should produce ordinary modules.
BeamWeaver therefore offers two native paths: `%BeamWeaver.Core.Tool{}` values
for runtime-created tools and `use BeamWeaver.Tool` modules for stable tools.
{% endhint %}

## Create Tools

### Runtime Tool

Use `Tool.from_function!/1` when the tool is built from configuration, tests, or
runtime data:

```elixir
alias BeamWeaver.Core.Tool

search_database =
  Tool.from_function!(
    name: "search_database",
    description: "Search customer records matching a query.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Search terms"},
        "limit" => %{"type" => "integer", "default" => 10}
      },
      "required" => ["query"]
    },
    handler: fn input, _opts ->
      query = input["query"] || input[:query]
      limit = input["limit"] || input[:limit] || 10

      "Found #{limit} results for #{inspect(query)}"
    end
  )
```

The handler receives a map of validated input and a keyword list of call options.
Returning a plain value is accepted; returning `{:ok, value}` or
`{:error, %BeamWeaver.Core.Error{}}` is preferred when the tool does real work.

Tool names should use provider-safe characters: letters, numbers, underscores,
and hyphens. Provider renderers validate this before sending the tool schema to
OpenAI or Anthropic.

Runtime tools can also declare execution and parsing options:

```elixir
tool =
  Tool.from_function!(
    name: "lookup_order",
    description: "Lookup an order by numeric ID.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"order_id" => %{"type" => "integer"}},
      "required" => ["order_id"]
    },
    parse_args: fn
      %{"order_id" => id} when is_binary(id) -> {:ok, %{"order_id" => String.to_integer(id)}}
      _args -> :ok
    end,
    concurrent: false,
    max_result_chars: 2_000,
    handler: fn %{"order_id" => id}, _opts ->
      MyApp.Orders.fetch_summary!(id)
    end
  )
```

`parse_args` runs after model tool-call normalization and before schema
validation, so it can coerce raw LLM arguments before strict validation. It must
return `:ok`, `{:ok, parsed_map}`, or `{:error, reason}`. Parser errors,
exceptions, and invalid return shapes become `:invalid_input` errors and use the
same `handle_validation_error` policy as schema failures.

### Module Tool

Use `use BeamWeaver.Tool` for application tools that should compile to a normal
module:

```elixir
defmodule MyApp.Tools.SearchDatabase do
  use BeamWeaver.Tool

  name "search_database"
  description "Search customer records matching a query."
  tags [:customer_data]
  metadata %{owner: "support"}
  concurrent false
  max_result_chars 2_000

  schema do
    field :query, :string, description: "Search terms"
    field :limit, :integer, required: false, default: 10
  end

  @impl true
  def invoke(_tool, input, _opts) do
    query = input.query
    limit = Map.get(input, :limit, 10)

    {:ok, "Found #{limit} results for #{inspect(query)}"}
  end
end
```

Module tools can be passed as modules or structs:

```elixir
tools = [MyApp.Tools.SearchDatabase, %MyApp.Tools.SearchDatabase{}]
```

For lists that may include modules, structs, runtime tools, toolkits, or
runnable-compatible values, use `BeamWeaver.Tool.Converter.to_tools/2`.

Module tools can override `parse_args/2` directly when they need the same
pre-validation coercion:

```elixir
@impl true
def parse_args(_tool, %{"limit" => limit} = args) when is_binary(limit) do
  {:ok, %{args | "limit" => String.to_integer(limit)}}
end

def parse_args(_tool, _args), do: :ok
```

### Direct Behaviour Tool

When you need full control, implement `BeamWeaver.Core.Tool` directly:

```elixir
defmodule MyApp.Tools.Uppercase do
  @behaviour BeamWeaver.Core.Tool

  defstruct []

  def name(_tool), do: "uppercase"
  def description(_tool), do: "Uppercase a string."

  def input_schema(_tool) do
    %{
      "type" => "object",
      "properties" => %{"value" => %{"type" => "string"}},
      "required" => ["value"]
    }
  end

  def injected(_tool), do: %{}
  def return_direct(_tool), do: false
  def response_format(_tool), do: nil
  def output_schema(_tool), do: %{"type" => "string"}
  def tags(_tool), do: []
  def metadata(_tool), do: %{}
  def provider_opts(_tool), do: %{}

  def invoke(_tool, input, _opts) do
    {:ok, String.upcase(input["value"] || input[:value])}
  end
end
```

## Schemas

The model sees the tool name, description, and public input schema. BeamWeaver
uses JSON Schema-shaped maps at the provider boundary:

```elixir
weather_schema = %{
  "type" => "object",
  "properties" => %{
    "location" => %{"type" => "string", "description" => "City name or coordinates"},
    "units" => %{
      "type" => "string",
      "enum" => ["celsius", "fahrenheit"],
      "default" => "celsius"
    },
    "include_forecast" => %{"type" => "boolean", "default" => false}
  },
  "required" => ["location"]
}
```

The tool DSL builds the same shape from fields:

```elixir
schema do
  field :location, :string, description: "City name or coordinates"
  field :units, :string,
    required: false,
    default: "celsius",
    enum: ["celsius", "fahrenheit"]

  field :include_forecast, :boolean, required: false, default: false
end
```

`BeamWeaver.Tool.Schema.from/1` can convert explicit field declarations,
NimbleOptions-style specs, Ecto-style schema modules, and already-shaped JSON
Schema maps:

```elixir
{:ok, schema} =
  BeamWeaver.Tool.Schema.from([
    {:query, :string, description: "Search query"},
    {:limit, :integer, required: false, default: 5},
    {:filters, {:object, [{:section, :string, required: false}]}, required: false}
  ])
```

{% hint style="warning" %}
**Schema Inputs**

LangChain examples often use Pydantic models because Python can inspect those
classes at runtime and derive JSON Schema. Elixir structs and typespecs do not
carry runtime validation, field descriptions, and nested schema rules in that
way. BeamWeaver keeps schemas explicit: use JSON Schema maps, the tool DSL,
or `BeamWeaver.Tool.Schema.from/1` for native schema-like values.
{% endhint %}

### Runtime-Injected Arguments

Some inputs are for the tool implementation, not the model. Declare them in the
raw schema and mark them as injected:

```elixir
tool =
  Tool.from_function!(
    name: "search_private",
    description: "Search private data for the current user.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string"},
        "context" => %{"type" => "object"},
        "tool_call_id" => %{"type" => "string"}
      },
      "required" => ["query", "context", "tool_call_id"]
    },
    injected: [context: :context, tool_call_id: :tool_call_id],
    handler: fn input, _opts ->
      context = input[:context] || input["context"] || %{}
      user_id = context[:user_id] || context["user_id"]

      "Searching for #{input["query"] || input[:query]} as #{user_id}"
    end
  )

Tool.raw_input_schema(tool)
Tool.input_schema(tool)
```

`Tool.raw_input_schema/1` includes injected fields. `Tool.input_schema/1`
removes them before the schema is exposed to a model.

{% hint style="info" %}
**Injected Arguments**

LangChain hides `ToolRuntime` parameters by inspecting Python type
annotations, and reserves names such as `runtime` and `config`. BeamWeaver
makes injection declarative with the `:injected` map. The model-visible schema
stays clean, and the implementation still receives state, context, store,
runtime, config, checkpointer, or tool call ID when the tool runs inside an
agent or `ToolNode`.
{% endhint %}

Injected sources:

| Source | Value |
|---|---|
| `:state` | full graph or agent state |
| `{:state, field_or_path}` | one state field or nested path |
| `:context` | per-run context |
| `:store` | long-term memory store |
| `:runtime` | graph runtime struct/map |
| `:tool_runtime` | `%BeamWeaver.Core.ToolRuntime{}` |
| `:tool_call_id` | current model tool call ID |
| `:config` | runtime config |
| `:checkpointer` | checkpoint adapter |

## Access Runtime Data

Runtime injection is available when a tool is executed by an agent or
`BeamWeaver.Graph.Nodes.ToolNode`. Direct `Tool.invoke/3` calls are plain
function calls; pass any implementation-only values yourself when calling tools
outside a graph runtime.

### State

State is short-term conversation data. Inject the full state or a specific
field:

```elixir
get_last_user_message =
  Tool.from_function!(
    name: "get_last_user_message",
    description: "Get the most recent user message.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"state" => %{"type" => "object"}},
      "required" => ["state"]
    },
    injected: [state: :state],
    handler: fn input, _opts ->
      state = input[:state] || input["state"] || %{}

      state
      |> Map.get(:messages, Map.get(state, "messages", []))
      |> Enum.reverse()
      |> Enum.find(&match?(%BeamWeaver.Core.Message{role: :user}, &1))
      |> case do
        nil -> "No user messages found."
        message -> BeamWeaver.Core.Message.text(message)
      end
    end
  )
```

### Context

Context is immutable per-run data passed to the agent invocation:

```elixir
account_tool =
  Tool.from_function!(
    name: "get_account_info",
    description: "Get account information for the current user.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"context" => %{"type" => "object"}},
      "required" => ["context"]
    },
    injected: [context: :context],
    handler: fn input, _opts ->
      context = input[:context] || input["context"] || %{}
      user_id = context[:user_id] || context["user_id"]

      "Account for #{user_id}: Premium"
    end
  )
```

Invoke the agent with both a stable `thread_id` for checkpoints and per-run
context for tools:

```elixir
MyApp.Agent.invoke(
  %{messages: [BeamWeaver.Core.Message.user("What is my balance?")]},
  config: %{"configurable" => %{"thread_id" => "thread-123"}},
  context: %{user_id: "user-123"}
)
```

### Store

Stores are long-term memory. Inject the store and use the `BeamWeaver.Memory`
API:

```elixir
save_user_info =
  Tool.from_function!(
    name: "save_user_info",
    description: "Save user information.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "user_id" => %{"type" => "string"},
        "info" => %{"type" => "object"},
        "store" => %{"type" => "object"}
      },
      "required" => ["user_id", "info", "store"]
    },
    injected: [store: :store],
    handler: fn input, _opts ->
      store = input[:store] || input["store"]
      user_id = input["user_id"] || input[:user_id]
      info = input["info"] || input[:info]

      :ok = BeamWeaver.Memory.put(store, ["users"], user_id, info)
      "Saved user information."
    end
  )
```

Use `BeamWeaver.Memory.ETS` for local/test storage and
`BeamWeaver.Memory.Ecto` for durable Postgres-backed storage.

### Stream Writer

Inject `:tool_runtime` to emit tool progress events:

```elixir
streaming_tool =
  Tool.from_function!(
    name: "stream_tool",
    description: "Emit progress while running.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "text" => %{"type" => "string"},
        "tool_runtime" => %{"type" => "object"}
      },
      "required" => ["text", "tool_runtime"]
    },
    injected: [tool_runtime: :tool_runtime],
    handler: fn input, _opts ->
      runtime = input[:tool_runtime] || input["tool_runtime"]
      text = input["text"] || input[:text]

      BeamWeaver.Core.ToolRuntime.emit_output_delta(runtime, "starting")
      BeamWeaver.Core.ToolRuntime.emit_output_delta(runtime, "finished")

      text
    end
  )
```

Tool progress is visible in agent or graph streams that use typed events.

### Execution And Deployment Metadata

`%BeamWeaver.Core.ToolRuntime{}` includes `tool_call_id`, `tool_call`,
`execution_info`, and `server_info` fields:

```elixir
handler = fn input, _opts ->
  runtime = input[:tool_runtime] || input["tool_runtime"]
  %{tool_call_id: runtime.tool_call_id, execution: runtime.execution_info}
end
```

{% hint style="info" %}
**Server Metadata**

LangChain's docs include LangGraph Server-specific `server_info`. BeamWeaver's
runtime has a `server_info` slot so your own OTP service can pass deployment
metadata through the graph runtime. The public tool API does not depend on a
hosted LangGraph server, SDK, or CLI.
{% endhint %}

## Tool Execution

### Direct Invocation

Call tools directly with `Tool.invoke/3`:

```elixir
{:ok, result} = BeamWeaver.Core.Tool.invoke(search_database, %{"query" => "Ada", "limit" => 3})
```

For a single-input tool, scalar input is accepted:

```elixir
echo =
  Tool.from_function!(
    name: "echo",
    description: "Echo one value.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"]
    },
    handler: fn input, _opts -> input["query"] || input[:query] end
  )

{:ok, "beam"} = Tool.invoke(echo, "beam")
```

Use Task-backed helpers for explicit async work:

```elixir
task = BeamWeaver.Core.Tool.async_invoke(echo, "beam")
{:ok, "beam"} = BeamWeaver.Core.Async.await(task)
```

### Model Tool Calls

When the input is a tool-call map, BeamWeaver validates the call, injects the
tool call ID, and wraps the result as a tool message:

```elixir
tool_call = %{
  "type" => "tool_call",
  "name" => "echo",
  "id" => "call_123",
  "args" => %{"query" => "beam"}
}

{:ok, %BeamWeaver.Core.Message{role: :tool} = message} =
  BeamWeaver.Core.Tool.invoke(echo, tool_call)
```

Standalone model calls only request tool execution. Agents and `ToolNode` run
the loop automatically.

### ToolNode

`BeamWeaver.Graph.Nodes.ToolNode` executes one or more tool calls, handles
parallel calls with supervised tasks, injects runtime data, emits stream events,
and returns tool messages or graph commands:

```elixir
alias BeamWeaver.Graph.Nodes.ToolNode

node = ToolNode.new([search_database], timeout: 5_000)

messages =
  ToolNode.invoke(node, [
    %{id: "call_search", name: "search_database", args: %{"query" => "Ada"}}
  ])
```

In graph state, the node reads assistant tool calls from `:messages` and returns
tool messages that a reducer can append.

ToolNode preserves the model's original tool-call order in its returned
messages. Consecutive tools are executed concurrently by default. Set
`concurrent: false` on `Tool.from_function!/1` tools, or declare
`concurrent false` in `use BeamWeaver.Tool`, when a tool must act as an ordering
barrier. Consecutive concurrent tools before and after that barrier run in
separate supervised groups.

`max_result_chars` limits only model-visible textual tool message content. It
does not change direct handler return values before normalization, graph
commands, artifacts, structured metadata, or non-text values.

## Return Values

Tools can return several shapes.

### String Or Structured Data

Return text when the model should read a simple observation:

```elixir
handler: fn input, _opts ->
  "It is sunny in #{input["city"] || input[:city]}."
end
```

Return maps or lists when structure helps model reasoning. Tool messages encode
non-text values as JSON:

```elixir
handler: fn input, _opts ->
  %{city: input["city"] || input[:city], temperature_c: 22, conditions: "sunny"}
end
```

### ToolResult And Artifacts

Use `%BeamWeaver.Core.ToolResult{}` or `response_format: :content_and_artifact`
when model-visible content and application-only data should differ:

```elixir
lookup =
  Tool.from_function!(
    name: "lookup",
    description: "Look up a record.",
    input_schema: %{
      "type" => "object",
      "properties" => %{"id" => %{"type" => "string"}},
      "required" => ["id"]
    },
    handler: fn input, _opts ->
      id = input["id"] || input[:id]

      BeamWeaver.Core.ToolResult.success("record #{id}",
        artifact: %{id: id, raw: %{score: 10}},
        metadata: %{source: "records"}
      )
    end
  )
```

The model sees `"record #{id}"`. The artifact remains available on the tool
message metadata or artifacts for application code, tracing, retrieval UIs, and
checkpointed state.

### Command

Return `BeamWeaver.Graph.Command` when a tool needs to update state or route the
graph. Include a matching tool message in the command update when the model
needs an observation:

```elixir
alias BeamWeaver.Core.Message
alias BeamWeaver.Graph.Command

set_user_name =
  Tool.from_function!(
    name: "set_user_name",
    description: "Set the user's name in state.",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "new_name" => %{"type" => "string"},
        "tool_call_id" => %{"type" => "string"}
      },
      "required" => ["new_name", "tool_call_id"]
    },
    injected: [tool_call_id: :tool_call_id],
    handler: fn input, _opts ->
      name = input["new_name"] || input[:new_name]
      call_id = input[:tool_call_id] || input["tool_call_id"]

      %Command{
        update: %{
          user_name: name,
          messages: [Message.tool("User name set to #{name}.", tool_call_id: call_id)]
        }
      }
    end
  )
```

If multiple tools update the same state field in parallel, define graph reducers
for that field.

### Return Direct

Use `return_direct: true` when a successful tool result should stop the agent
loop after the tool observation:

```elixir
Tool.from_function!(
  name: "finish",
  description: "Return the final answer.",
  input_schema: %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "string"}},
    "required" => ["answer"]
  },
  return_direct: true,
  handler: fn input, _opts -> input["answer"] || input[:answer] end
)
```

## Error Handling

Tools return tagged errors for recoverable failures:

```elixir
{:error, %BeamWeaver.Core.Error{type: :tool_exception}}
```

You can let the error bubble, or format it as model-visible content:

```elixir
Tool.from_function!(
  name: "fragile_lookup",
  description: "Lookup that can fail.",
  input_schema: %{"type" => "object", "required" => []},
  handle_tool_error: fn error -> "Lookup failed: #{error.message}" end,
  handle_validation_error: true,
  handler: fn _input, _opts -> raise "network unavailable" end
)
```

When invoked as a tool-call map, handled errors become
`%BeamWeaver.Core.Message{role: :tool, status: :error}` with the original
`tool_call_id`.

At the agent boundary, use middleware:

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.ToolRetry,
   max_retries: 2,
   on_failure: :continue}
]
```

For custom behavior, implement `wrap_tool_call/2` middleware:

```elixir
defmodule MyApp.ToolErrors do
  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.Message

  def wrap_tool_call(%ToolCallRequest{} = request, handler) do
    case handler.(request) do
      {:error, error} ->
        call_id = Map.get(request.tool_call, :id) || Map.get(request.tool_call, "id")

        Message.tool("Tool error: #{error.message}",
          tool_call_id: call_id
        )

      other ->
        other
    end
  end
end
```

{% hint style="info" %}
**Middleware Instead Of Decorators**

LangChain demonstrates tool error handling with decorator helpers such as
`@wrap_tool_call`. BeamWeaver uses middleware modules and structs. The hook is
the same lifecycle point, but the implementation is explicit data in the agent
spec and composes with OTP supervision, telemetry, retries, and graph commands.
{% endhint %}

## Dynamic Tools

Agents can filter or add tools at the model-call boundary:

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.ToolSelection,
   allow: ["public_search"],
   deny: ["delete_data"],
   tags: [:support],
   tools: fn request ->
     runtime = request.runtime || %{}
     context = Map.get(runtime, :context) || %{}
     authenticated? = Map.get(context, :authenticated?) || Map.get(context, "authenticated?")

     if authenticated? do
       [MyApp.Tools.PrivateSearch]
     else
       []
     end
   end}
]
```

When tools are added dynamically, pair model-time registration with tool-time
routing. A `wrap_model_call/2` hook exposes the tool to the model, and
`wrap_tool_call/2` can provide the concrete tool when execution starts. See
[Agents](agents.md) for the full runtime-registration example.

## Provider Rendering And Model Binding

Bind tools to a standalone model:

```elixir
model_with_tools =
  BeamWeaver.Models.bind_tools(model, [search_database],
    tool_choice: :auto,
    parallel_tool_calls: true
  )
```

Render provider schemas directly when building provider-specific requests:

```elixir
{:ok, openai_tool} = BeamWeaver.Tool.Renderer.openai_tool(search_database, strict: true)
{:ok, anthropic_tool} = BeamWeaver.Tool.Renderer.anthropic_tool(search_database)
```

Provider renderers strip injected fields from schemas and validate provider-safe
names. OpenAI strict rendering closes object schemas and makes every declared
property required; Google rendering sanitizes Gemini function declarations by
dereferencing local `$ref` values and removing unsupported JSON Schema keywords.

## Prebuilt Tools

BeamWeaver includes a small set of native tools that are useful in agents and
graphs.

### File Search

Search a retriever or local filesystem roots:

```elixir
tool =
  BeamWeaver.Tools.FileSearch.new(
    roots: ["docs"],
    include: ["**/*.md"],
    max_results: 5,
    query_mode: :literal
  )
```

Retrievers can also become tools:

```elixir
tool =
  BeamWeaver.Retriever.as_tool(retriever,
    name: "knowledge_search",
    response_format: :content_and_artifact
  )
```

### Shell

Shell access is policy-governed. The policy allow list is required:

```elixir
tool =
  BeamWeaver.Tools.Shell.new(
    policy: [
      allow: ["git status", "mix test"],
      cwd: File.cwd!(),
      timeout: 10_000,
      max_output_bytes: 20_000
    ]
  )
```

Use narrow allow rules and prefer deterministic commands. Session-backed shell
tools can use graph state to keep a supervised shell session.

### Todo

`BeamWeaver.Tools.Todo` updates explicit agent state with graph commands:

```elixir
tool = BeamWeaver.Tools.Todo.new(state_key: :todos)
```

It injects state and the tool call ID, updates the TODO list, and returns a tool
message in the command update.

### Toolkits

Group tools with `BeamWeaver.ToolKit`:

```elixir
defmodule MyApp.SupportTools do
  @behaviour BeamWeaver.ToolKit

  def tools(_opts) do
    [MyApp.Tools.SearchDatabase, BeamWeaver.Tools.Todo.new()]
  end
end

{:ok, tools} = BeamWeaver.Tool.Converter.to_tools(MyApp.SupportTools)
```

{% hint style="warning" %}
**Prebuilt Scope**

LangChain has many Python integration packages for search vendors, databases,
browsers, code interpreters, and SaaS APIs. BeamWeaver keeps prebuilt tools
small and native. Product-specific integrations should be ordinary Elixir
modules that implement `BeamWeaver.Core.Tool`, use supervised clients, and
expose explicit schemas.
{% endhint %}

## Server-Side Provider Tools

Some model providers execute tools inside the provider request. Those are
provider request declarations, not local `BeamWeaver.Core.Tool` implementations.

OpenAI:

```elixir
tools = [
  BeamWeaver.OpenAI.ToolCalling.web_search(),
  BeamWeaver.OpenAI.ToolCalling.code_interpreter(%{"type" => "auto"}),
  BeamWeaver.OpenAI.ToolCalling.file_search(["vs_123"])
]

BeamWeaver.Core.ChatModel.invoke(model, "Find current release notes.", tools: tools)
```

Anthropic:

```elixir
tools = [
  BeamWeaver.Anthropic.Tools.web_search(),
  BeamWeaver.Anthropic.Tools.code_execution()
]

BeamWeaver.Core.ChatModel.invoke(model, "Search and summarize.", tools: tools)
```

Google:

```elixir
tools = [
  BeamWeaver.Google.Tools.google_search(),
  BeamWeaver.Google.Tools.url_context(),
  BeamWeaver.Google.Tools.code_execution()
]

BeamWeaver.Core.ChatModel.invoke(model, "Search and summarize.", tools: tools)
```

xAI:

```elixir
tools = [
  BeamWeaver.XAI.Tools.web_search(search_depth: :deep),
  BeamWeaver.XAI.Tools.x_search(),
  BeamWeaver.XAI.Tools.code_execution(),
  BeamWeaver.XAI.Tools.file_search()
]

BeamWeaver.Core.ChatModel.invoke(model, "Search and summarize.", tools: tools)
```

For xAI Chat Completions search tools, use `BeamWeaver.XAI.Tools.live_search/1`.

Server-side tool calls and results are represented as message content blocks and
response metadata. There is no local `ToolNode` execution step for work the
provider already performed.

## Related Guides

- [Agents](agents.md)
- [Context Engineering](context_engineering.md)
- [Models](models.md)
- [Structured Output](structured_output.md)
- [Messages](messages.md)
- [Short-Term Memory](short_term_memory.md)
- [Long-Term Memory](long_term_memory.md)
- [Middleware](middleware.md)
- [Custom Middleware](custom_middleware.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Guardrails](guardrails.md)
- [Runtime](runtime.md)
- [Event Streaming](event_streaming.md)
- [Graph](graph.md)
- [Retrieval](retrieval.md)
- [OpenAI](partners/openai.md)
- [Anthropic](partners/anthropic.md)
- [Google](partners/google.md)
- [xAI](partners/xai.md)
