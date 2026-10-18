# Agent DSL and Lifecycle

An agent lets a model choose which tools to call and when it has enough
information to answer. You define the available actions and limits;
BeamWeaver manages the model/tool loop. Use a [graph](graphs.md) for steps
chosen by your application.

Complete [Installation](installation.md) first. These examples use OpenAI.
Run the blocks in order in IEx, or save module definitions under `lib/my_app/`
and run the calls in IEx.

## Declare an agent

The model chooses to call this tool; a local dataset supplies the order facts.
Replace that dataset with your application's lookup when integrating it.

```elixir
defmodule MyApp.OrderStatus do
  use BeamWeaver.Tool

  name "order_status"
  description "Read the shipping status of an order."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => "A-1001"}, _opts),
    do: {:ok, %{order_id: "A-1001", status: "shipped", delivery_day: "Thursday"}}

  def invoke(_tool, _input, _opts), do: {:error, "Order not found"}
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Always call order_status for order questions. Answer using its result."

  tools do
    tool MyApp.OrderStatus
  end

  middleware do
    use BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 2
  end

  validate_tools true
  recursion_limit 20
  run_timeout 120_000
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["When will order A-1001 arrive?"]})
tool_result = Enum.find(result.messages, &(&1.role == :tool and &1.name == "order_status"))
true = tool_result != nil
true = BeamWeaver.Core.Message.text(tool_result) =~ "Thursday"
answer = result.messages |> List.last() |> BeamWeaver.Core.Message.text()
true = byte_size(answer) > 0
IO.puts(answer)
```

`use BeamWeaver.Agent` supplies `invoke/2`, `stream_events/2`, `resume/2`,
`resume_review/2` and `get_state/1`. Every agent declares a model.
The short forms `tools [MyApp.OrderStatus]` and
`middleware [{BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 2}]`
are equivalent to the blocks above. Inside a collection block, `include`
inserts a list computed by your application.

## Declaration evaluation and resource ownership

Agent declarations are expressions evaluated **on each invocation**. A model
expression can read application configuration, so changes affect subsequent
calls without recompiling the module.

Do not create a process or ETS table in a declaration. Such resources need
an owner whose lifetime spans the calls using them. Direct ETS construction
in `checkpointer`, `store` or `cache` declarations is rejected. Create resources
under supervision, or in the caller for an experiment, and pass them as call
options. Database adapter structs can be declared because the supervised
repository owns their connections.

Tool and schema declarations describe their modules at compilation. Read
request-specific data through [injected arguments](tools.md#injected-arguments),
not through a tool declaration.

## Run an agent

Input is a state map. Strings in `messages` become user messages; use
`BeamWeaver.Core.Message` for other roles or media.

| Result | Meaning | Application action |
| --- | --- | --- |
| `{:ok, state}` | The run finished | Read the last message or `structured_response` |
| `{:interrupted, interrupt}` | The run paused | Collect a resume value or review decision |
| `{:error, error}` | The run failed | Inspect `error.type`, `error.message` and `error.details` |

The state includes the conversation, tool results and keys added by middleware.
A completed run can still contain a failed business operation: the model may
explain a tool error in its final answer. Inspect the relevant tool result or
use [structured output](structured_output.md) when code depends on the outcome.

### Per-call options

| Option | Purpose |
| --- | --- |
| `context:` | Trusted caller data; supply it on every call |
| `config:` | Run configuration, including a thread ID under `"configurable"` |
| `checkpointer:`, `store:`, `cache:` | Reuse application-owned storage |
| `model_opts:` | Override model options for this run |
| `recursion_limit:` | Override the graph step budget |
| `run_timeout:`, `step_timeout:` | Bound the run and each step in milliseconds |
| `trace:` | Attach a name, user ID, thread ID or metadata to traces |

Call options override declared storage and limits. Model options must be
supported by the selected provider and model; see [Models](models.md).

A required context field is validated before the model runs; then invoke with trusted caller data:

```elixir
defmodule MyApp.AccountGreeter do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000
  system_prompt "Greet the user briefly. Do not claim to have checked account records."

  context_schema do
    field :customer_id, :string, required: true
  end
end

{:error, %BeamWeaver.Core.Error{type: :invalid_context}} = MyApp.AccountGreeter.invoke(%{messages: ["Hello"]})
{:ok, result} = MyApp.AccountGreeter.invoke(%{messages: ["Hello"]}, context: %{customer_id: "ada"}, run_timeout: 70_000)
true = byte_size(BeamWeaver.Core.Message.text(List.last(result.messages))) > 0
```

## Continue a conversation

Reuse a checkpointer and thread ID. Pass only new messages; saved history is
loaded for you.

```elixir
saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "order-A-1001"}}]

{:ok, first} = MyApp.SupportAgent.invoke(%{messages: ["Check order A-1001."]}, opts)
{:ok, second} = MyApp.SupportAgent.invoke(%{messages: ["Summarize what we learned."]}, opts)
true = length(second.messages) > length(first.messages)
{:ok, snapshot} = MyApp.SupportAgent.get_state(opts)
true = is_map(snapshot.values)
```

This ETS saver belongs to your IEx process and disappears when it ends.
Choose [persistent storage](storage.md) for restart recovery. Use distinct
thread IDs for distinct conversations and enforce access in your application.

## Declarations

| Concern | Declarations | Details |
| --- | --- | --- |
| Identity | `name`, `description` | Trace names and descriptions for parent agents |
| Model | `model`, `model_opts`, `system_prompt` | [Models](models.md); `model_opts` overrides options following `model` |
| Actions | `tools`, `validate_tools`, `exclude_tools`, `tool_descriptions` | [Tools](tools.md) |
| Hooks | `middleware` | [Middleware](middleware.md) |
| Final answer | `response_schema`, `response_format` | [Structured Output](structured_output.md) |
| Caller contract | `context_schema` | [Runtime Context](runtime_context.md) |
| State contract | `input_schema`, `output_schema` | Maps of `BeamWeaver.Agent.Schema.field/3`; undeclared keys are filtered |
| Storage | `checkpointer`, `store`, `cache` | Resources must outlive the call |
| Human review | `interrupt_on`, `interrupt_before`, `interrupt_after`, `interrupts` | [Human Review](human_in_the_loop.md) |
| Limits | `recursion_limit`, `tool_timeout`, `step_timeout`, `run_timeout` | Step counts and millisecond timeouts are separate budgets |
| Workspace | `filesystem`, `filesystem_permissions`, `skills`, `memory` | [Deep Agents](deep_agents.md) |
| Delegation | `subagents`, `async_subagents`, `execution_mode` | [Subagents](subagents.md) |
| Context policy | `compact_conversation`, `overflow_recovery`, `prompt_caching` | [Context Management](context_management.md) |
| Model defaults | `capability_profile` | [Capability Profiles](profiles.md) |

State schemas are distinct from response schemas. Empty input used to continue
saved work and `BeamWeaver.Graph.Command` resume values bypass the ordinary
input-schema check. Context fields are optional unless marked required;
tool and response-schema fields are required by default.

## How the loop stops

A model reply without tool calls normally ends the loop. A structured answer,
a successful direct-return tool, middleware or an interrupt can also end or
pause it. Model steps, tool rounds and state hooks consume graph steps.
Set a budget appropriate to the work.

If too few steps remain for another tool round and final answer, the agent
can answer that it needs more steps. Hitting the hard limit returns
`:recursion_limit`. Neither is a reason to blindly repeat external actions;
see [Durable Execution](durable_execution.md).

## Stream, pause and inspect

Use `stream_events/2` for progress, `resume_review/2` for tool approvals and
`resume/2` for other interrupts. Continuation calls use the original
checkpointer and thread configuration; pass current context again.
`get_state/1` reads a snapshot without invoking a model.

Complete flows appear in [Streaming](streaming.md),
[Human Review](human_in_the_loop.md) and [Checkpoints](checkpoints.md).

Use the support agent defined above. Consume its stream once; read its saved state through the same saver:

```elixir
saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "agent-stream"}}]

{:ok, events} =
  MyApp.SupportAgent.stream_events(
    %{messages: ["Look up A-1001 and report its status."]},
    Keyword.put(opts, :live, true)
  )

events = Enum.to_list(events)
true = Enum.any?(events, &match?(%{event: %BeamWeaver.Stream.Events.ToolStart{}}, &1))
{:ok, saved} = MyApp.SupportAgent.get_state(opts)
true = Enum.any?(saved.values.messages, &(&1.role == :tool))
```

## Agents built at runtime

Use a module for agents defined by application code. Use `build/1` when tools
or instructions come from runtime data:

```elixir
{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4-mini",
    model_opts: [max_tokens: 128, timeout: 60_000],
    system_prompt: "Reply briefly.",
    tools: [MyApp.OrderStatus]
  )

{:ok, result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Say hello."]})
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
```

Options mirror declarations; use `response_format:` for a schema or strategy.
Build errors identify invalid models, tools, middleware, subagents or options.
The module-level runtime functions accept the built agent first, followed by
the same input and call options.

`declarations/1` returns an agent module's declarations under the same
option names, evaluated when it is called. Read the declared model or system
prompt from it, or build the same agent with one declaration changed:

```elixir
declared = BeamWeaver.Agent.declarations(MyApp.SupportAgent)
true = declared.model == "openai:gpt-5.4-mini"
{:ok, _french} = BeamWeaver.Agent.build(%{declared | system_prompt: declared.system_prompt <> " Answer in French."})
```
