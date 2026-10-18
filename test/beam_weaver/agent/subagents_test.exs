defmodule BeamWeaver.Agent.SubagentsTest.Observer do
  # The test process that the scripted models and tools report to.
  def watch, do: :persistent_term.put(__MODULE__, self())
  def notify(message), do: send(:persistent_term.get(__MODULE__), message)
end

defmodule BeamWeaver.Agent.SubagentsTest.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund an order to the customer's card."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts) do
    BeamWeaver.Agent.SubagentsTest.Observer.notify({:refunded, order_id})
    {:ok, "Refunded #{order_id}."}
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.ClerkModel do
  # Refunds the order named in the task, then reports the tool result.
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message

  defstruct label: "clerk"

  @impl true
  def invoke(%__MODULE__{label: label}, messages, _opts) do
    BeamWeaver.Agent.SubagentsTest.Observer.notify({:model_call, label})

    case Enum.find(Enum.reverse(messages), &(&1.role == :tool)) do
      nil ->
        task = messages |> Enum.filter(&(&1.role == :user)) |> List.last() |> Message.text()
        [order_id] = Regex.run(~r/A-\d+/, task)
        call = %{id: "refund-#{order_id}", name: "issue_refund", args: %{"order_id" => order_id}}
        {:ok, Message.assistant("", tool_calls: [call])}

      tool_message ->
        {:ok, Message.assistant("#{label}: " <> Message.text(tool_message))}
    end
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.CountingModel do
  # Answers with a fixed text and reports every call.
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message

  defstruct [:label, :answer]

  @impl true
  def invoke(%__MODULE__{label: label, answer: answer}, _messages, _opts) do
    BeamWeaver.Agent.SubagentsTest.Observer.notify({:model_call, label})
    {:ok, Message.assistant(answer)}
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.RefundClerk do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  name "refund_clerk"
  description "Issues refunds."

  model "fake:chat",
    responses: [FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1"}), "Refunded A-1."]

  tools [BeamWeaver.Agent.SubagentsTest.IssueRefund]
  interrupt_on %{"issue_refund" => true}
end

defmodule BeamWeaver.Agent.SubagentsTest.Clerk do
  use BeamWeaver.Agent

  name "clerk"
  description "Refunds the order named in the task."
  model %BeamWeaver.Agent.SubagentsTest.ClerkModel{}
  tools [BeamWeaver.Agent.SubagentsTest.IssueRefund]
  interrupt_on %{"issue_refund" => true}
end

defmodule BeamWeaver.Agent.SubagentsTest.Historian do
  use BeamWeaver.Agent

  name "historian"
  description "Summarizes order history."
  model %BeamWeaver.Agent.SubagentsTest.CountingModel{label: "historian", answer: "Three orders."}
end

defmodule BeamWeaver.Agent.SubagentsTest.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up an order."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "#{order_id} shipped Monday."}
end

defmodule BeamWeaver.Agent.SubagentsTest.Noop do
  use BeamWeaver.Tool

  name "noop"
  description "Does nothing."

  schema do
    field :step, :integer
  end

  @impl true
  def invoke(_tool, _input, _opts), do: {:ok, "ok"}
end

defmodule BeamWeaver.Agent.SubagentsTest.LoopModel do
  # Never answers: it calls `noop` on every turn.
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message

  defstruct []

  @impl true
  def invoke(%__MODULE__{}, messages, _opts) do
    BeamWeaver.Agent.SubagentsTest.Observer.notify({:model_call, "loop"})
    step = Enum.count(messages, &(&1.role == :assistant))
    {:ok, Message.assistant("", tool_calls: [%{id: "noop-#{step}", name: "noop", args: %{"step" => step}}])}
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.InspectorModel do
  # Reports its prompt and tools, reads the refund skill, then answers with
  # what it read.
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool

  defstruct []

  @impl true
  def invoke(%__MODULE__{}, messages, opts) do
    prompt = Enum.map_join(for(%Message{role: :system} = message <- messages, do: message), "\n", &Message.text/1)

    BeamWeaver.Agent.SubagentsTest.Observer.notify(
      {:inspector, prompt, opts |> Keyword.get(:tools, []) |> Enum.map(&Tool.name/1)}
    )

    case Enum.find(Enum.reverse(messages), &(&1.role == :tool)) do
      nil ->
        args = %{"file_path" => "/skills/refund-policy/SKILL.md"}
        {:ok, Message.assistant("", tool_calls: [%{id: "read-1", name: "read_file", args: args}])}

      tool_message ->
        {:ok, Message.assistant(Message.text(tool_message))}
    end
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.ScriptedExpert do
  use BeamWeaver.Agent

  name "scripted_expert"
  description "Answers refund questions."
  model "fake:chat", responses: ["Orders can be refunded within 30 days."]
end

defmodule BeamWeaver.Agent.SubagentsTest.CountingExpert do
  use BeamWeaver.Agent

  name "counting_expert"
  description "Answers refund questions."
  model %BeamWeaver.Agent.SubagentsTest.CountingModel{label: "expert", answer: "Within 30 days."}
end

defmodule BeamWeaver.Agent.SubagentsTest.Coordinator do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  name "coordinator"
  description "Asks the expert."

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{"subagent_type" => "counting_expert", "description" => "Refund window?"}),
      "The expert says 30 days."
    ]

  subagents do
    subagent BeamWeaver.Agent.SubagentsTest.CountingExpert
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.PolicyReader do
  use BeamWeaver.Agent

  name "policy_reader"
  description "Reads Acme's policies."
  model %BeamWeaver.Agent.SubagentsTest.InspectorModel{}
  filesystem BeamWeaver.Filesystem.State.new()
  skills ["/skills"]
  memory ["/AGENTS.md"]
end

defmodule BeamWeaver.Agent.SubagentsTest.RecordedExpert do
  use BeamWeaver.Agent

  name "recorded_expert"
  description "Answers refund questions and keeps its own checkpoints."
  model "fake:chat", responses: ["Within 30 days."]
  checkpointer :persistent_term.get({BeamWeaver.Agent.SubagentsTest, :expert_saver}, nil)
end

defmodule BeamWeaver.Agent.SubagentsTest.Looper do
  use BeamWeaver.Agent

  name "looper"
  description "Never finishes."
  model %BeamWeaver.Agent.SubagentsTest.LoopModel{}
  tools [BeamWeaver.Agent.SubagentsTest.Noop]
end

defmodule BeamWeaver.Agent.SubagentsTest.ShortLooper do
  use BeamWeaver.Agent

  name "short_looper"
  description "Never finishes, in few steps."
  model %BeamWeaver.Agent.SubagentsTest.LoopModel{}
  tools [BeamWeaver.Agent.SubagentsTest.Noop]
  recursion_limit 3
end

defmodule BeamWeaver.Agent.SubagentsTest.ShippingClerk do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  name "shipping_clerk"
  description "Looks orders up."
  model "fake:chat", responses: [FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1"}), "A-1 shipped Monday."]
  tools [BeamWeaver.Agent.SubagentsTest.LookupOrder]
end

defmodule BeamWeaver.Agent.SubagentsTest.LimitedExpert do
  use BeamWeaver.Agent

  name "limited_expert"
  description "Answers in one model call."
  model %BeamWeaver.Agent.SubagentsTest.CountingModel{label: "limited_expert", answer: "Within 30 days."}
  middleware [{BeamWeaver.Agent.Middleware.ModelCallLimit, run_limit: 1}]
end

defmodule BeamWeaver.Agent.SubagentsTest.DelegateModel do
  # Hands the task to the subagent named in the context, then says "Done.".
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message

  defstruct []

  @impl true
  def invoke(%__MODULE__{}, messages, opts) do
    if Enum.any?(messages, &(&1.role == :tool)) do
      {:ok, Message.assistant("Done.")}
    else
      args = %{"subagent_type" => opts[:context].subagent, "description" => "Refund A-7."}
      {:ok, Message.assistant("", tool_calls: [%{id: "task-1", name: "task", args: args}])}
    end
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.DelegatingDesk do
  # Hands one task to the subagent named in the context.
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.SubagentsTest

  model %SubagentsTest.DelegateModel{}
  recursion_limit 7
  middleware [{BeamWeaver.Agent.Middleware.ModelCallLimit, run_limit: 5}]

  subagents do
    subagent SubagentsTest.ScriptedExpert
    subagent SubagentsTest.Coordinator
    subagent SubagentsTest.PolicyReader
    subagent SubagentsTest.RecordedExpert
    subagent SubagentsTest.Looper
    subagent SubagentsTest.ShortLooper
    subagent SubagentsTest.ShippingClerk
    subagent SubagentsTest.LimitedExpert
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.Desk do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{"subagent_type" => "refund_clerk", "description" => "Refund A-1."}),
      "Done."
    ]

  subagents do
    subagent BeamWeaver.Agent.SubagentsTest.RefundClerk
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.RefundManager do
  # A subagent whose own subagent reviews refunds.
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  name "refund_manager"
  description "Delegates refunds to the clerk."

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{"subagent_type" => "refund_clerk", "description" => "Refund A-1."}),
      "The clerk refunded A-1."
    ]

  subagents do
    subagent BeamWeaver.Agent.SubagentsTest.RefundClerk
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.ManagedDesk do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{"subagent_type" => "refund_manager", "description" => "Get A-1 refunded."}),
      "Done."
    ]

  subagents do
    subagent BeamWeaver.Agent.SubagentsTest.RefundManager
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.BusyDesk do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_calls([
        {"task", %{"subagent_type" => "clerk", "description" => "Refund A-1."}},
        {"task", %{"subagent_type" => "historian", "description" => "Summarize Ada's orders."}},
        {"task", %{"subagent_type" => "clerk", "description" => "Refund A-2."}}
      ]),
      "Done."
    ]

  subagents do
    subagent BeamWeaver.Agent.SubagentsTest.Clerk
    subagent BeamWeaver.Agent.SubagentsTest.Historian
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.PerCallClerk do
  # Refunds two orders in one turn and reviews each call on its own.
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  name "per_call_clerk"
  description "Refunds the orders named in the task."

  model "fake:chat",
    responses: [
      FakeChatModel.tool_calls([{"issue_refund", %{"order_id" => "A-1"}}, {"issue_refund", %{"order_id" => "A-2"}}]),
      "Refunded both."
    ]

  tools [BeamWeaver.Agent.SubagentsTest.IssueRefund]

  middleware [
    {BeamWeaver.Agent.Middleware.HumanInTheLoop, interrupt_mode: :per_call, interrupt_on: %{"issue_refund" => true}}
  ]
end

defmodule BeamWeaver.Agent.SubagentsTest.PerCallDesk do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{"subagent_type" => "per_call_clerk", "description" => "Refund A-1 and A-2."}),
      "Done."
    ]

  subagents do
    subagent BeamWeaver.Agent.SubagentsTest.PerCallClerk
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.PlainClerk do
  use BeamWeaver.Agent

  name "clerk"
  description "Refunds the order named in the task."
  model %BeamWeaver.Agent.SubagentsTest.ClerkModel{}
end

defmodule BeamWeaver.Agent.SubagentsTest.ReviewedDesk do
  # The parent reviews refunds; its subagents take the rules unless their
  # line turns them off.
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.SubagentsTest.PlainClerk

  model %BeamWeaver.Agent.SubagentsTest.DelegateModel{}
  tools [BeamWeaver.Agent.SubagentsTest.IssueRefund]
  interrupt_on %{"issue_refund" => true}

  subagents do
    subagent PlainClerk
    subagent PlainClerk, name: "clerk_without_rules", interrupt_on: false
    subagent PlainClerk, name: "clerk_with_empty_rules", interrupt_on: %{}
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.CompiledDesk do
  # Runs the recorded expert exactly as it is.
  use BeamWeaver.Agent

  model %BeamWeaver.Agent.SubagentsTest.DelegateModel{}

  subagents [
    %BeamWeaver.Agent.Subagent.Compiled{
      name: "recorded_expert",
      description: "Answers refund questions.",
      agent: BeamWeaver.Agent.SubagentsTest.RecordedExpert
    }
  ]
end

defmodule BeamWeaver.Agent.SubagentsTest.ProbeToolkit do
  # Reports each time an agent reads its tools.
  @behaviour BeamWeaver.ToolKit

  @impl true
  def tools(_opts) do
    BeamWeaver.Agent.SubagentsTest.Observer.notify(:toolkit_read)
    [BeamWeaver.Agent.SubagentsTest.LookupOrder]
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.GraphProbe do
  # Reports when an agent with it builds its graph, which reads the state
  # schema of every middleware.
  use BeamWeaver.Agent.Middleware

  @impl true
  def state_schema(_middleware) do
    BeamWeaver.Agent.SubagentsTest.Observer.notify(:graph_built)
    nil
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.LazyDesk do
  # Never calls `task`; its subagent reports when it is checked or built.
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Hello."]

  subagents [
    %{
      name: "lookup_clerk",
      description: "Looks orders up.",
      tools: [BeamWeaver.Agent.SubagentsTest.ProbeToolkit],
      middleware: [BeamWeaver.Agent.SubagentsTest.GraphProbe]
    }
  ]
end

defmodule BeamWeaver.Agent.SubagentsTest.MisconfiguredDesk do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Hello."]
  subagents [%{name: "researcher", description: "Researches.", tools: ["web_search"]}]
end

defmodule BeamWeaver.Agent.SubagentsTest.Ledger do
  # Keeps a note in a private key of the agent's state.
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Graph

  @impl true
  def name(_middleware), do: :ledger

  @impl true
  def state_schema(_middleware), do: %{ledger: Graph.private_channel(BeamWeaver.Graph.Channels.LastValue)}

  @impl true
  def before_agent(_middleware, _state, _runtime), do: %{ledger: "parent only"}
end

defmodule BeamWeaver.Agent.SubagentsTest.StateProbe do
  # Reports the state keys an agent starts its run with.
  use BeamWeaver.Agent.Middleware

  @impl true
  def name(_middleware), do: :state_probe

  @impl true
  def before_agent(_middleware, state, _runtime) do
    BeamWeaver.Agent.SubagentsTest.Observer.notify({:starting_keys, Map.keys(state)})
    nil
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.ProbedExpert do
  use BeamWeaver.Agent

  name "probed_expert"
  description "Answers refund questions."
  model "fake:chat", responses: ["Within 30 days."]
  middleware [BeamWeaver.Agent.SubagentsTest.StateProbe]
end

defmodule BeamWeaver.Agent.SubagentsTest.LedgerDesk do
  # Keeps private state of its own: a ledger, and model and tool call counts.
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.ModelCallLimit
  alias BeamWeaver.Agent.Middleware.ToolCallLimit
  alias BeamWeaver.Agent.SubagentsTest

  model %SubagentsTest.DelegateModel{}
  middleware [SubagentsTest.Ledger, {ModelCallLimit, thread_limit: 5}, {ToolCallLimit, thread_limit: 5}]

  subagents do
    subagent SubagentsTest.ProbedExpert
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.Answer do
  use BeamWeaver.Schema

  field :answer, :string
end

defmodule BeamWeaver.Agent.SubagentsTest.Triage do
  # Names the escalation desk as a subagent, which names it back.
  use BeamWeaver.Agent

  name "triage"
  description "Sorts tickets."
  model "fake:chat", responses: ["Sorted."]

  subagents [
    %BeamWeaver.Agent.Subagent.Compiled{
      name: "escalation",
      description: "Handles escalations.",
      agent: BeamWeaver.Agent.SubagentsTest.Escalation
    }
  ]
end

defmodule BeamWeaver.Agent.SubagentsTest.Escalation do
  use BeamWeaver.Agent

  name "escalation"
  description "Handles escalations."
  model "fake:chat", responses: ["Escalated."]

  subagents [
    %BeamWeaver.Agent.Subagent.Compiled{
      name: "triage",
      description: "Sorts tickets.",
      agent: BeamWeaver.Agent.SubagentsTest.Triage
    }
  ]
end

defmodule BeamWeaver.Agent.SubagentsTest.LedgerKeeper do
  # Keeps a private ledger and reports it when the run ends.
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Graph

  @impl true
  def name(_middleware), do: :ledger_keeper

  @impl true
  def state_schema(_middleware), do: %{ledger: Graph.private_channel(BeamWeaver.Graph.Channels.LastValue)}

  @impl true
  def before_agent(_middleware, _state, _runtime), do: %{ledger: "parent only"}

  @impl true
  def after_agent(_middleware, state, _runtime) do
    BeamWeaver.Agent.SubagentsTest.Observer.notify({:parent_ledger, Map.get(state, :ledger)})
    nil
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.WriteLedger do
  use BeamWeaver.Tool

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command

  name "write_ledger"
  description "Writes a note in the ledger."
  injected :tool_call_id, :tool_call_id

  schema do
    field :note, :string
  end

  @impl true
  def invoke(_tool, %{"note" => note, tool_call_id: id}, _opts),
    do: {:ok, %Command{update: %{ledger: note, messages: [Message.tool("Noted.", tool_call_id: id)]}}}
end

defmodule BeamWeaver.Agent.SubagentsTest.LedgerWriter do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  name "ledger_writer"
  description "Writes a note in its ledger."
  model "fake:chat", responses: [FakeChatModel.tool_call("write_ledger", %{"note" => "child note"}), "Noted."]
  tools [BeamWeaver.Agent.SubagentsTest.WriteLedger]
end

defmodule BeamWeaver.Agent.SubagentsTest.LedgerKeepingDesk do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.SubagentsTest

  model %SubagentsTest.DelegateModel{}
  middleware [SubagentsTest.LedgerKeeper]

  subagents do
    subagent SubagentsTest.LedgerWriter
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.DraftModel do
  # The parent hands "Write the draft." to the general-purpose subagent, which
  # writes /draft.md. Each call reports the task it works on and the tools it
  # was offered, then its system prompt and the tools' descriptions.
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Agent.SubagentsTest.Observer
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool

  defstruct []

  @impl true
  def invoke(%__MODULE__{}, messages, opts) do
    task = messages |> Enum.filter(&(&1.role == :user)) |> List.last() |> Message.text()
    tools = Keyword.get(opts, :tools, [])
    prompt = Enum.map_join(for(%Message{role: :system} = message <- messages, do: message), "\n", &Message.text/1)

    Observer.notify({:offered, task, Enum.map(tools, &Tool.name/1)})
    Observer.notify({:prompted, task, prompt, Map.new(tools, &{Tool.name(&1), Tool.description(&1)})})

    case {task, Enum.filter(messages, &(&1.role == :tool))} do
      {"Write the draft.", []} ->
        args = %{"file_path" => "/draft.md", "content" => "Your refund is on its way."}
        {:ok, Message.assistant("", tool_calls: [%{id: "write-1", name: "write_file", args: args}])}

      {_task, []} ->
        args = %{"subagent_type" => "general-purpose", "description" => "Write the draft."}
        {:ok, Message.assistant("", tool_calls: [%{id: "task-1", name: "task", args: args}])}

      {_task, tool_messages} ->
        {:ok, Message.assistant(tool_messages |> List.last() |> Message.text())}
    end
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.DraftStamp do
  # Reports each model call it wraps, with the task the agent works on.
  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Message

  def name(_middleware), do: :draft_stamp

  def wrap_model_call(_middleware, request, handler) do
    task = request.messages |> Enum.filter(&(&1.role == :user)) |> List.last() |> Message.text()
    BeamWeaver.Agent.SubagentsTest.Observer.notify({:stamped, task})
    handler.(request)
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.AskBudget do
  # Asks for the budget, a whole number, before the model's call.
  use BeamWeaver.Agent.Middleware

  def name(_middleware), do: :ask_budget

  def before_model(_middleware, _state, _runtime) do
    BeamWeaver.Graph.interrupt("Budget?", response_schema: %{"type" => "integer"})
    nil
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.BudgetClerk do
  use BeamWeaver.Agent

  name "budget_clerk"
  description "Checks the budget."
  model "fake:chat", responses: ["Within budget."]
  middleware [BeamWeaver.Agent.SubagentsTest.AskBudget]
end

defmodule BeamWeaver.Agent.SubagentsTest.BudgetDesk do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{"subagent_type" => "budget_clerk", "description" => "Check the budget."}),
      "Done."
    ]

  subagents do
    subagent BeamWeaver.Agent.SubagentsTest.BudgetClerk
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.StatusGraph do
  # A graph module that answers with the status of the order in its task.
  use BeamWeaver.Graph

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph

  def graph do
    Graph.new(state_schema: Graph.Messages.state_schema())
    |> Graph.add_node(:look_up, &look_up/1)
    |> Graph.add_edge(Graph.start(), :look_up)
    |> Graph.add_edge(:look_up, Graph.end_node())
  end

  def look_up(%{messages: messages}) do
    [order_id] = Regex.run(~r/A-\d+/, messages |> List.last() |> Message.text())
    %{messages: [Message.assistant("#{order_id} shipped on Monday.")]}
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.RefundGraph do
  # A graph module that asks a person before it refunds the order in its task.
  use BeamWeaver.Graph

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph

  def graph do
    Graph.new(state_schema: Graph.Messages.state_schema())
    |> Graph.add_node(:refund, &refund/1)
    |> Graph.add_edge(Graph.start(), :refund)
    |> Graph.add_edge(:refund, Graph.end_node())
  end

  def refund(%{messages: messages}) do
    [order_id] = Regex.run(~r/A-\d+/, messages |> List.last() |> Message.text())
    approved? = Graph.interrupt(%{question: "Refund #{order_id}?"}) == "yes"
    %{messages: [Message.assistant(if(approved?, do: "Refunded #{order_id}.", else: "Kept #{order_id}."))]}
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.PollingGraph do
  # A graph module that polls until its own recursion limit stops it.
  use BeamWeaver.Graph

  alias BeamWeaver.Graph

  recursion_limit 2

  def graph do
    Graph.new()
    |> Graph.add_node(:poll, fn _state -> BeamWeaver.Agent.SubagentsTest.Observer.notify(:polled) && %{} end)
    |> Graph.add_edge(Graph.start(), :poll)
    |> Graph.add_edge(:poll, :poll)
  end
end

defmodule BeamWeaver.Agent.SubagentsTest.GraphDesk do
  # Hands one task to the graph module named in the context.
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Subagent.Compiled
  alias BeamWeaver.Agent.SubagentsTest

  model %SubagentsTest.DelegateModel{}
  recursion_limit 7

  subagents [
    %Compiled{name: "status_graph", description: "Looks orders up.", agent: SubagentsTest.StatusGraph},
    %Compiled{name: "refund_graph", description: "Refunds what a person approves.", agent: SubagentsTest.RefundGraph},
    %Compiled{name: "polling_graph", description: "Polls an order.", agent: SubagentsTest.PollingGraph}
  ]
end

defmodule BeamWeaver.Agent.SubagentsTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.CapabilityProfile
  alias BeamWeaver.Agent.GeneralPurposeSubagentProfile
  alias BeamWeaver.Agent.HITL
  alias BeamWeaver.Agent.Middleware.Filesystem
  alias BeamWeaver.Agent.Middleware.ModelCallLimit
  alias BeamWeaver.Agent.Middleware.Skills
  alias BeamWeaver.Agent.Middleware.Subagents
  alias BeamWeaver.Agent.Middleware.Summarization
  alias BeamWeaver.Agent.Middleware.TodoList
  alias BeamWeaver.Agent.Middleware.ToolCallNormalization
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.Subagent.Compiled
  alias BeamWeaver.Agent.Subagent.RunStream
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Agent.Subagent.StreamTransformer
  alias BeamWeaver.Agent.SubagentsTest.Answer
  alias BeamWeaver.Agent.SubagentsTest.BudgetDesk
  alias BeamWeaver.Agent.SubagentsTest.BusyDesk
  alias BeamWeaver.Agent.SubagentsTest.CompiledDesk
  alias BeamWeaver.Agent.SubagentsTest.DelegatingDesk
  alias BeamWeaver.Agent.SubagentsTest.DraftModel
  alias BeamWeaver.Agent.SubagentsTest.DraftStamp
  alias BeamWeaver.Agent.SubagentsTest.Desk
  alias BeamWeaver.Agent.SubagentsTest.GraphDesk
  alias BeamWeaver.Agent.SubagentsTest.GraphProbe
  alias BeamWeaver.Agent.SubagentsTest.LazyDesk
  alias BeamWeaver.Agent.SubagentsTest.LedgerDesk
  alias BeamWeaver.Agent.SubagentsTest.LedgerKeepingDesk
  alias BeamWeaver.Agent.SubagentsTest.ManagedDesk
  alias BeamWeaver.Agent.SubagentsTest.MisconfiguredDesk
  alias BeamWeaver.Agent.SubagentsTest.PerCallDesk
  alias BeamWeaver.Agent.SubagentsTest.ProbeToolkit
  alias BeamWeaver.Agent.SubagentsTest.RefundClerk
  alias BeamWeaver.Agent.SubagentsTest.ReviewedDesk
  alias BeamWeaver.Agent.SubagentsTest.Triage
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Stream.Events

  setup do
    BeamWeaver.Agent.SubagentsTest.Observer.watch()
  end

  defp thread(id), do: [checkpointer: Checkpoint.ETS.new(), config: %{"configurable" => %{"thread_id" => id}}]

  defp tool_texts(result) do
    for %Message{role: :tool} = message <- result.messages, do: Message.text(message)
  end

  defp delegate(subagent, opts \\ []) do
    DelegatingDesk.invoke(%{messages: ["Help, please."]}, Keyword.put(opts, :context, %{subagent: subagent}))
  end

  defp received_count(message, count \\ 0) do
    receive do
      ^message -> received_count(message, count + 1)
    after
      0 -> count
    end
  end

  defp received_model_calls(label, count \\ 0) do
    receive do
      {:model_call, ^label} -> received_model_calls(label, count + 1)
    after
      0 -> count
    end
  end

  defp received(message, count \\ 0) do
    receive do
      ^message -> received(message, count + 1)
    after
      0 -> count
    end
  end

  defp checkpoint_namespaces(saver, thread_id) do
    for record <- Checkpoint.list(saver, %{"configurable" => %{"thread_id" => thread_id}}),
        do: record.config["configurable"]["checkpoint_ns"]
  end

  describe "a subagent module runs as declared" do
    test "with the options after its model" do
      assert {:ok, result} = delegate("scripted_expert")
      assert tool_texts(result) == ["Orders can be refunded within 30 days."]
    end

    test "with its own filesystem, skills and memory files" do
      skill = "---\nname: refund-policy\ndescription: Decide refunds.\n---\n\nDamaged items: full refund.\n"
      files = %{"/skills/refund-policy/SKILL.md" => skill, "/AGENTS.md" => "- Ada prefers email.\n"}

      assert {:ok, result} =
               DelegatingDesk.invoke(%{messages: ["What is the refund policy?"], files: files},
                 context: %{subagent: "policy_reader"}
               )

      assert_received {:inspector, prompt, tools}
      assert prompt =~ "refund-policy"
      assert prompt =~ "Ada prefers email."
      assert "read_file" in tools
      assert [answer] = tool_texts(result)
      assert answer =~ "Damaged items: full refund."
    end

    test "with its own subagents" do
      assert {:ok, result} = delegate("coordinator")
      assert received_model_calls("expert") == 1
      assert tool_texts(result) == ["The expert says 30 days."]
    end

    test "with its own call counts, not the parent's" do
      assert {:ok, result} = delegate("limited_expert")
      assert received_model_calls("limited_expert") == 1
      assert tool_texts(result) == ["Within 30 days."]
    end

    test "from the parent's public state, without the parent's private keys" do
      # Keys only the parent declares private, such as a middleware's own key
      # or the call-limit counts, used to reach the subagent's state and
      # checkpoints.
      parent_only = [
        :ledger,
        :thread_model_call_count,
        :run_model_call_count,
        :thread_tool_call_count,
        :run_tool_call_count
      ]

      opts = thread("parent-private-keys")

      assert {:ok, result} =
               LedgerDesk.invoke(
                 %{messages: ["Help, please."], customer: "Ada"},
                 [context: %{subagent: "probed_expert"}] ++ opts
               )

      assert tool_texts(result) == ["Within 30 days."]

      assert_received {:starting_keys, keys}
      assert :customer in keys
      assert Enum.filter(parent_only, &(&1 in keys)) == []

      saved =
        for record <- Checkpoint.list(opts[:checkpointer], %{"configurable" => %{"thread_id" => "parent-private-keys"}}),
            String.contains?(record.config["configurable"]["checkpoint_ns"], "subagent.probed_expert"),
            key <- Map.keys(record.checkpoint["channel_values"]),
            uniq: true,
            do: key

      assert :customer in saved
      assert Enum.filter(parent_only, &(&1 in saved)) == []
    end

    test "and a key the parent keeps private stays the parent's when the subagent writes it" do
      assert {:ok, result} =
               LedgerKeepingDesk.invoke(%{messages: ["Note it."]}, context: %{subagent: "ledger_writer"})

      assert tool_texts(result) == ["Noted."]
      assert_received {:parent_ledger, "parent only"}
    end

    test "with its own checkpointer, under the parent's thread" do
      expert_saver = Checkpoint.ETS.new()
      :persistent_term.put({__MODULE__, :expert_saver}, expert_saver)
      on_exit(fn -> :persistent_term.erase({__MODULE__, :expert_saver}) end)
      opts = thread("own-checkpointer")

      assert {:ok, result} = delegate("recorded_expert", opts)
      assert tool_texts(result) == ["Within 30 days."]

      thread_config = %{"configurable" => %{"thread_id" => "own-checkpointer"}}

      namespaces = fn saver ->
        for record <- Checkpoint.list(saver, thread_config), do: record.config["configurable"]["checkpoint_ns"]
      end

      assert Enum.any?(namespaces.(expert_saver), &String.contains?(&1, "subagent.recorded_expert"))
      refute Enum.any?(namespaces.(opts[:checkpointer]), &String.contains?(&1, "subagent.recorded_expert"))
    end

    test "as a compiled subagent, with its own checkpointer" do
      # The module's checkpointer/0 returned nil, so it saved with the parent's.
      expert_saver = Checkpoint.ETS.new()
      :persistent_term.put({__MODULE__, :expert_saver}, expert_saver)
      on_exit(fn -> :persistent_term.erase({__MODULE__, :expert_saver}) end)
      opts = thread("compiled-own-checkpointer")

      assert {:ok, result} =
               CompiledDesk.invoke(%{messages: ["Help, please."]}, [context: %{subagent: "recorded_expert"}] ++ opts)

      assert tool_texts(result) == ["Within 30 days."]

      own = checkpoint_namespaces(expert_saver, "compiled-own-checkpointer")
      parents = checkpoint_namespaces(opts[:checkpointer], "compiled-own-checkpointer")
      assert Enum.any?(own, &String.contains?(&1, "subagent.recorded_expert"))
      refute Enum.any?(parents, &String.contains?(&1, "subagent.recorded_expert"))
    end

    test "with its own checkpointer, in a parent run without a thread" do
      # Every task failed with "checkpoint config requires thread_id". The
      # subagent now saves in a thread named after the parent run.
      expert_saver = Checkpoint.ETS.new()
      :persistent_term.put({__MODULE__, :expert_saver}, expert_saver)
      on_exit(fn -> :persistent_term.erase({__MODULE__, :expert_saver}) end)

      for run_id <- ["desk-run-1", "desk-run-2"] do
        assert {:ok, result} = delegate("recorded_expert", run_id: run_id)
        assert tool_texts(result) == ["Within 30 days."]
        assert Enum.any?(checkpoint_namespaces(expert_saver, run_id), &String.contains?(&1, "subagent.recorded_expert"))
      end

      assert {:ok, result} =
               CompiledDesk.invoke(%{messages: ["Help, please."]},
                 context: %{subagent: "recorded_expert"},
                 run_id: "compiled-desk-run"
               )

      assert tool_texts(result) == ["Within 30 days."]

      assert Enum.any?(
               checkpoint_namespaces(expert_saver, "compiled-desk-run"),
               &String.contains?(&1, "subagent.recorded_expert")
             )
    end
  end

  describe "checkpointer, store and recursion limit" do
    test "a subagent saves its checkpoints with the parent's per-call checkpointer" do
      opts = thread("per-call")

      assert {:ok, _result} = delegate("scripted_expert", opts)

      namespaces =
        for record <- Checkpoint.list(opts[:checkpointer], %{"configurable" => %{"thread_id" => "per-call"}}),
            do: record.config["configurable"]["checkpoint_ns"]

      assert Enum.any?(namespaces, &String.contains?(&1, "subagent.scripted_expert"))
    end

    test "a subagent takes the parent's recursion limit unless it sets its own" do
      # A model call and a tool call take one step each: seven steps allow four
      # model calls, three steps two.
      assert {:ok, _result} = delegate("looper")
      assert received_model_calls("loop") == 4

      assert {:ok, _result} = delegate("short_looper")
      assert received_model_calls("loop") == 2
    end
  end

  describe "a graph module as a compiled subagent" do
    test "runs its graph and answers with its last message" do
      assert {:ok, result} = GraphDesk.invoke(%{messages: ["Help, please."]}, context: %{subagent: "status_graph"})
      assert tool_texts(result) == ["A-7 shipped on Monday."]
    end

    test "pauses the parent, and resuming the parent finishes the graph" do
      opts = Keyword.put(thread("refund-graph"), :context, %{subagent: "refund_graph"})

      assert {:interrupted, %{value: %{question: "Refund A-7?"}}} =
               GraphDesk.invoke(%{messages: ["Help, please."]}, opts)

      assert {:ok, result} = GraphDesk.resume("yes", opts)
      assert tool_texts(result) == ["Refunded A-7."]
    end

    test "keeps its own recursion limit" do
      assert {:ok, _result} = GraphDesk.invoke(%{messages: ["Help, please."]}, context: %{subagent: "polling_graph"})
      assert received_count(:polled) == 2
    end

    test "isn't a subagent spec, which builds an agent" do
      assert_raise ArgumentError,
                   ~r/StatusGraph is a graph module; run it as a %BeamWeaver.Agent.Subagent.Compiled{}/,
                   fn ->
                     Spec.from_agent_module(BeamWeaver.Agent.SubagentsTest.StatusGraph)
                   end
    end
  end

  describe "building subagents" do
    test "building an agent checks each subagent and names the one it can't build" do
      # Each of these used to show up only as a tool error, when a task called
      # the subagent; an unknown option raised ArgumentError.
      problems = [
        {[bogus: 1], "unknown subagent option :bogus"},
        {[middleware: [String]], "String does not `use BeamWeaver.Agent.Middleware`"},
        {[tools: ["web_search"]], ~s("web_search" is not a tool)},
        {[model: "nope:model"], "unsupported provider"},
        {[response_format: BeamWeaver.Agent.SubagentsTest.NoSuchSchema],
         "response_format BeamWeaver.Agent.SubagentsTest.NoSuchSchema is not a module"},
        {[response_format: String], "response_format String declares no schema"},
        {[execution_mode: :research_then_generate, response_format: String],
         "response_format String declares no schema"}
      ]

      for {options, problem} <- problems do
        researcher = Map.new([name: "researcher", description: "Researches."] ++ options)

        assert {:error, %Error{type: :invalid_subagent, message: message, details: %{subagent: "researcher"}}} =
                 Agent.build(model: "fake:chat", subagents: [researcher])

        assert message =~ ~s(subagent "researcher": #{problem})
      end
    end

    test "a subagent's own subagents are checked too, and so are compiled subagents" do
      fact_checker = %{name: "fact_checker", description: "Checks facts.", tools: ["web_search"]}
      researcher = %{name: "researcher", description: "Researches.", subagents: [fact_checker]}

      assert {:error, %Error{type: :invalid_subagent, message: message}} =
               Agent.build(model: "fake:chat", subagents: [researcher])

      assert message =~ ~s(subagent "researcher": subagent "fact_checker": "web_search" is not a tool)

      historian = %Compiled{name: "historian", description: "Summarizes order history.", agent: String}

      assert {:error,
              %Error{type: :invalid_subagent, message: ~s(subagent "historian": String is not an agent or graph module)}} =
               Agent.build(model: "fake:chat", subagents: [historian])
    end

    test "an agent module with a subagent it can't build fails on its first call" do
      assert {:error, %Error{type: :invalid_subagent, details: %{subagent: "researcher"}}} =
               MisconfiguredDesk.invoke(%{messages: ["Hello?"]})

      assert {:error, %Error{type: :invalid_subagent}} = Agent.compiled_graph(MisconfiguredDesk)
      assert_raise ArgumentError, ~r/subagent "researcher"/, fn -> MisconfiguredDesk.graph() end
    end

    test "an agent module checks its subagents on its first call only, without building them" do
      assert {:ok, _result} = LazyDesk.invoke(%{messages: ["Hello?"]})
      assert received(:toolkit_read) == 1
      assert {:ok, _result} = LazyDesk.invoke(%{messages: ["Hello?"]})
      assert received(:toolkit_read) == 0
      assert received(:graph_built) == 0
    end

    test "a built agent checks its subagents when it is built and builds one when a task calls it" do
      clerk = %{
        name: "lookup_clerk",
        description: "Looks orders up.",
        model: %FakeChatModel{response: "A-1 shipped Monday."},
        tools: [ProbeToolkit],
        middleware: [GraphProbe]
      }

      task = FakeChatModel.tool_call("task", %{"subagent_type" => "lookup_clerk", "description" => "Where is A-1?"})

      assert {:ok, agent} =
               Agent.build(
                 model: "fake:chat",
                 model_opts: [responses: [task, "It shipped Monday."]],
                 subagents: [clerk]
               )

      assert received(:toolkit_read) == 1
      assert received(:graph_built) == 0

      assert {:ok, result} = Agent.invoke(agent, %{messages: ["Where is A-1?"]})
      assert tool_texts(result) == ["A-1 shipped Monday."]
      assert received(:graph_built) == 1
    end

    test "the middleware on its own builds a subagent when a task calls it" do
      # Without a model of its own or a parent model, "unbuildable" can't be built.
      unbuildable = Spec.new(name: "unbuildable", description: "Has no model.")
      expert = Spec.new(name: "expert", description: "Answers.", model: %FakeChatModel{response: "30 days."})
      [task] = [subagents: [unbuildable, expert]] |> Subagents.new() |> Subagents.tools()

      call = fn subagent_type ->
        args = %{"subagent_type" => subagent_type, "description" => "Refund window?"}

        case Tool.invoke(task, Map.merge(args, %{state: %{}, tool_call_id: "call-1"})) do
          {:ok, %{update: %{messages: [message]}}} -> Message.text(message)
          {:ok, text} when is_binary(text) -> text
        end
      end

      assert call.("expert") == "30 days."
      assert call.("unbuildable") =~ "Subagent error: BeamWeaver.Agent.build/1 requires a :model option"
    end

    test "fractional summarization takes each subagent's model's context window" do
      # The general-purpose subagent got no context window, so building any
      # agent with subagents and this setting failed with :invalid_subagent.
      researcher = %{
        name: "researcher",
        description: "Researches.",
        model: "fake:chat",
        model_opts: [profile: %{max_input_tokens: 50_000}],
        base_middleware: [:deepagents]
      }

      assert {:ok, agent} =
               Agent.build(
                 model: %FakeChatModel{response: "Done.", profile: %{max_input_tokens: 200_000}},
                 compact_conversation: [summarization: [trigger: {:fraction, 0.8}, keep: {:messages, 20}]],
                 subagents: [researcher]
               )

      middleware = Enum.find(agent.spec.middleware, &match?(%Subagents{}, &1))

      summarization = fn name ->
        assert {:ok, %Compiled{agent: %Agent.Built{spec: spec}}} = Subagents.build_subagent(middleware, name)
        Enum.find(spec.middleware, &match?(%Summarization{}, &1))
      end

      assert %Summarization{trigger: {:fraction, 0.8}, max_input_tokens: 200_000} = summarization.("general-purpose")
      assert %Summarization{trigger: {:fraction, 0.8}, max_input_tokens: 50_000} = summarization.("researcher")
    end

    test "a subagent's own call limit replaces the one-call limit of its execution mode" do
      # The subagent got a second ModelCallLimit: it was built, but every task
      # failed with "graph contains duplicate declarations".
      for mode <- [:structured_once, :research_then_generate] do
        worker = %{
          name: "worker",
          description: "Answers.",
          model: "fake:chat",
          model_opts: [responses: [FakeChatModel.final(%{answer: "42"})]],
          execution_mode: mode,
          response_format: Answer,
          middleware: [{ModelCallLimit, thread_limit: 3}]
        }

        assert {:ok, agent} =
                 Agent.build(
                   model: "fake:chat",
                   model_opts: [
                     responses: [
                       FakeChatModel.tool_call("task", %{"subagent_type" => "worker", "description" => "Q?"}),
                       "Done."
                     ]
                   ],
                   subagents: [worker]
                 )

        assert {:ok, result} = Agent.invoke(agent, %{messages: ["Q?"]})
        assert tool_texts(result) == [~s({"answer":"42"})]
      end
    end

    test "a subagent's own middleware replaces the base_middleware entry of the same module" do
      # Its own Skills with the `:deepagents` set failed the build with
      # duplicate declarations, and its own Filesystem with a base one ran
      # both: two filesystem prompt sections, one set of file tools hidden.
      own_skills = Skills.new(backend: BeamWeaver.Filesystem.State.new(), skills: ["/expert-skills"])
      own_files = Filesystem.new(backend: BeamWeaver.Filesystem.State.new())

      experts = [
        %{name: "skilled", description: "Answers.", base_middleware: [:deepagents], middleware: [own_skills]},
        %{name: "filer", description: "Answers.", base_middleware: [Filesystem], middleware: [own_files]}
      ]

      assert {:ok, agent} =
               Agent.build(
                 model: "fake:chat",
                 filesystem: BeamWeaver.Filesystem.State.new(),
                 skills: ["/skills"],
                 subagents: experts
               )

      middleware = Enum.find(agent.spec.middleware, &match?(%Subagents{}, &1))

      entries = fn name, module ->
        assert {:ok, %Compiled{agent: %Agent.Built{spec: spec}}} = Subagents.build_subagent(middleware, name)
        Enum.filter(spec.middleware, &is_struct(&1, module))
      end

      assert entries.("skilled", Skills) == [own_skills]
      assert entries.("filer", Filesystem) == [own_files]
    end

    test "the :deepagents set gives file tools and skills, and TodoList adds a task list" do
      experts = [
        %{name: "deep", description: "Answers.", base_middleware: [:deepagents]},
        %{name: "planner", description: "Plans.", base_middleware: [:deepagents, TodoList]}
      ]

      assert {:ok, agent} =
               Agent.build(
                 model: "fake:chat",
                 filesystem: BeamWeaver.Filesystem.State.new(),
                 skills: ["/skills"],
                 subagents: experts
               )

      middleware = Enum.find(agent.spec.middleware, &match?(%Subagents{}, &1))

      modules = fn name ->
        assert {:ok, %Compiled{agent: %Agent.Built{spec: spec}}} = Subagents.build_subagent(middleware, name)
        for %module{} <- spec.middleware, do: module
      end

      assert Filesystem in modules.("deep")
      assert Skills in modules.("deep")
      refute TodoList in modules.("deep")
      assert TodoList in modules.("planner")
    end

    test "building an agent finds middleware that a subagent lists twice" do
      worker = %{
        name: "worker",
        description: "Answers.",
        middleware: [{ModelCallLimit, run_limit: 2}, {ModelCallLimit, thread_limit: 3}]
      }

      assert {:error, %Error{type: :invalid_subagent, message: message, details: %{subagent: "worker"}}} =
               Agent.build(model: "fake:chat", subagents: [worker])

      assert message ==
               ~s(subagent "worker": graph contains duplicate declarations: ) <>
                 "model_call_limit.before_model, model_call_limit.after_model"
    end
  end

  describe "declaring subagents" do
    test "unknown options raise instead of being ignored" do
      assert_raise ArgumentError, ~r/unknown subagent option :base_middlware/, fn ->
        Spec.new(name: "worker", description: "Works.", base_middlware: [])
      end

      assert_raise ArgumentError, ~r/unknown subagent option :tool/, fn ->
        Spec.from_agent_module(BeamWeaver.Agent.SubagentsTest.ScriptedExpert, tool: [])
      end
    end

    test "a compiled subagent can capture its answer" do
      historian = %Compiled{
        name: "historian",
        description: "Summarizes order history.",
        agent: BeamWeaver.Agent.SubagentsTest.Historian,
        capture_output: :history
      }

      [task] = [subagents: [historian]] |> Subagents.new() |> Subagents.tools()
      input = %{"subagent_type" => "historian", "description" => "Summarize.", state: %{}, tool_call_id: "c1"}

      assert {:ok, %Command{update: update}} = Tool.invoke(task, input)
      assert update.subagent_outputs == %{"history" => "Three orders."}
    end
  end

  describe "what the parent's model reads" do
    setup do
      worker =
        Spec.new(name: "worker", description: "Answers refund questions.", model: %FakeChatModel{response: "30 days."})

      %{subagents: [GeneralPurposeSubagentProfile.new(enabled: false), worker]}
    end

    test "the task tool's description is short and lists the subagents", %{subagents: subagents} do
      # It was about 6,900 characters, most of them worked examples.
      [task] = [subagents: subagents] |> Subagents.new() |> Subagents.tools()
      description = Tool.description(task)

      assert String.length(description) < 1_200
      assert description =~ "\n- worker: Answers refund questions.\n"
      assert description =~ "stateless"
      refute description =~ "<example>"
      refute description =~ "{{"
    end

    test "task_description: replaces the description, with the subagents for %{available_agents}", %{
      subagents: subagents
    } do
      [task] =
        [subagents: subagents, task_description: "Delegate:\n%{available_agents}"]
        |> Subagents.new()
        |> Subagents.tools()

      assert Tool.description(task) == "Delegate:\n- worker: Answers refund questions."
    end

    test "the system prompt gets no task section unless the middleware is given one", %{subagents: subagents} do
      {:ok, agent} =
        Agent.build(
          model: %FakeChatModel{response: "Hello!", parent: self()},
          system_prompt: "You are Acme's support agent.",
          subagents: subagents
        )

      assert {:ok, _result} = Agent.invoke(agent, %{messages: ["Hi"]})
      assert_received {:fake_chat_model_call, [%Message{role: :system} = system | _rest], _opts}
      assert Message.text(system) == "You are Acme's support agent."

      middleware = Subagents.new(subagents: subagents, system_prompt: "Delegate refund questions.")
      request = ModelRequest.new(system_prompt: "You are Acme's support agent.")
      assert %ModelRequest{system_message: message} = Subagents.wrap_model_call(middleware, request, & &1)

      assert Message.text(message) ==
               "You are Acme's support agent.\n\nDelegate refund questions.\n\n" <>
                 "Available subagent types:\n\n- worker: Answers refund questions."
    end
  end

  describe "the general-purpose subagent" do
    test "a disabled profile in the subagents list leaves it out" do
      worker = Spec.new(name: "worker", description: "Does work.", model: %FakeChatModel{response: "worked"})

      middleware =
        Subagents.new(
          model: %FakeChatModel{response: "unused"},
          subagents: [GeneralPurposeSubagentProfile.new(enabled: false), worker]
        )

      assert Enum.map(middleware.subagents, & &1.name) == ["worker"]
      [task] = Subagents.tools(middleware)
      refute Tool.description(task) =~ "- general-purpose:"

      assert_raise ArgumentError, ~r/no subagents/, fn ->
        Subagents.new(
          model: %FakeChatModel{response: "unused"},
          subagents: [%{enabled: false} |> GeneralPurposeSubagentProfile.new()]
        )
      end
    end

    test "it isn't offered a tool the parent excludes" do
      {:ok, agent} =
        Agent.build(
          model: %DraftModel{},
          filesystem: BeamWeaver.Filesystem.State.new(),
          exclude_tools: ["write_file"],
          subagents: [GeneralPurposeSubagentProfile.new()]
        )

      assert {:ok, result} = Agent.invoke(agent, %{messages: ["Draft a reply."]})
      assert_received {:offered, "Write the draft.", tools}
      assert "read_file" in tools
      refute "write_file" in tools
      refute Map.has_key?(Map.get(result, :files) || %{}, "/draft.md")
    end

    test "it keeps the permissions of the parent's own filesystem entry" do
      deny_writes = BeamWeaver.Filesystem.Permission.new(operations: [:write], paths: ["/**"], mode: :deny)

      {:ok, agent} =
        Agent.build(
          model: %DraftModel{},
          filesystem: BeamWeaver.Filesystem.State.new(),
          middleware: [{BeamWeaver.Agent.Middleware.Filesystem, permissions: [deny_writes]}],
          subagents: [GeneralPurposeSubagentProfile.new()]
        )

      assert {:ok, result} = Agent.invoke(agent, %{messages: ["Draft a reply."]})
      assert [answer] = tool_texts(result)
      assert answer =~ ~r/denied/i
      refute Map.has_key?(Map.get(result, :files) || %{}, "/draft.md")
    end

    test "a profile's description and prompt configure it" do
      profile =
        GeneralPurposeSubagentProfile.new(
          description: "Researches one question.",
          system_prompt: "Answer in two sentences."
        )

      middleware =
        Subagents.new(model: %FakeChatModel{response: "two sentences", parent: self()}, subagents: [profile])

      [task] = Subagents.tools(middleware)
      assert Tool.description(task) =~ "- general-purpose: Researches one question."

      assert {:ok, _command} =
               Tool.invoke(task, %{
                 "subagent_type" => "general-purpose",
                 "description" => "What is the refund window?",
                 state: %{},
                 tool_call_id: "call-gp"
               })

      assert_received {:fake_chat_model_call, [%Message{role: :system} = system | _rest], _opts}
      assert Message.text(system) =~ "Answer in two sentences."
    end

    test "it has no task list" do
      {:ok, agent} =
        Agent.build(
          model: %DraftModel{},
          filesystem: BeamWeaver.Filesystem.State.new(),
          subagents: [GeneralPurposeSubagentProfile.new()]
        )

      assert {:ok, _result} = Agent.invoke(agent, %{messages: ["Draft a reply."]})
      assert_received {:offered, "Write the draft.", tools}
      assert "write_file" in tools
      refute "write_todos" in tools
    end

    test "it sees the tool descriptions the parent sets" do
      {:ok, agent} =
        Agent.build(
          model: %DraftModel{},
          filesystem: BeamWeaver.Filesystem.State.new(),
          tool_descriptions: %{"write_file" => "Save a reply draft for Acme support."},
          subagents: [GeneralPurposeSubagentProfile.new()]
        )

      assert {:ok, _result} = Agent.invoke(agent, %{messages: ["Draft a reply."]})

      assert_received {:prompted, "Write the draft.", _prompt,
                       %{"write_file" => "Save a reply draft for Acme support."}}
    end

    test "it gets the parent's capability profile: its prompt text, tools and middleware" do
      profile =
        CapabilityProfile.new(
          prompt_suffix: "Keep drafts under 50 words.",
          tool_descriptions: %{"read_file" => "Read an Acme support file."},
          middleware: [DraftStamp]
        )

      {:ok, agent} =
        Agent.build(
          model: %DraftModel{},
          filesystem: BeamWeaver.Filesystem.State.new(),
          capability_profile: profile,
          subagents: [GeneralPurposeSubagentProfile.new()]
        )

      assert {:ok, _result} = Agent.invoke(agent, %{messages: ["Draft a reply."]})
      assert_received {:prompted, "Write the draft.", prompt, %{"read_file" => "Read an Acme support file."}}
      assert prompt =~ "contains the complete answer.\n\nKeep drafts under 50 words.\n\n"
      assert_received {:stamped, "Write the draft."}
    end

    test "it runs the parent's own entries for its capabilities, and none of the parent's other middleware" do
      files = BeamWeaver.Filesystem.State.new()
      own_files = Filesystem.new(backend: files, tool_token_limit_before_evict: 5_000)
      own_summary = Summarization.new(model: %FakeChatModel{response: "Summary."}, trigger: {:messages, 50})
      own_normalization = ToolCallNormalization.new(max_argument_chars: 500)
      researcher = %{name: "researcher", description: "Researches.", base_middleware: [:deepagents]}

      {:ok, agent} =
        Agent.build(
          model: "fake:chat",
          filesystem: files,
          middleware: [
            own_files,
            {Skills, skills: ["/team-skills"]},
            own_summary,
            own_normalization,
            {ModelCallLimit, run_limit: 5}
          ],
          subagents: [researcher]
        )

      middleware = Enum.find(agent.spec.middleware, &match?(%Subagents{}, &1))

      entries = fn name, module ->
        assert {:ok, %Compiled{agent: %Agent.Built{spec: spec}}} = Subagents.build_subagent(middleware, name)
        Enum.filter(spec.middleware, &(is_struct(&1, module) or match?({^module, _opts}, &1)))
      end

      assert entries.("general-purpose", Filesystem) == [own_files]
      assert [{Skills, opts}] = entries.("general-purpose", Skills)
      assert {opts[:skills], opts[:backend]} == {["/team-skills"], files}
      assert entries.("general-purpose", Summarization) == [own_summary]
      assert entries.("general-purpose", ToolCallNormalization) == [own_normalization]
      assert entries.("general-purpose", ModelCallLimit) == []

      # A declared subagent keeps its own capabilities.
      assert [%Filesystem{} = researcher_files] = entries.("researcher", Filesystem)
      refute researcher_files == own_files
      assert entries.("researcher", Summarization) == []
    end

    test "the parent's own entry in place of a profile's middleware takes that place in it too" do
      profile = CapabilityProfile.new(middleware: [ModelCallLimit.new(run_limit: 9)])

      {:ok, agent} =
        Agent.build(
          model: "fake:chat",
          capability_profile: profile,
          middleware: [ModelCallLimit.new(run_limit: 5)],
          subagents: [GeneralPurposeSubagentProfile.new()]
        )

      middleware = Enum.find(agent.spec.middleware, &match?(%Subagents{}, &1))
      assert {:ok, %Compiled{agent: %Agent.Built{spec: spec}}} = Subagents.build_subagent(middleware, "general-purpose")
      assert [%ModelCallLimit{run_limit: 5}] = Enum.filter(spec.middleware, &is_struct(&1, ModelCallLimit))
    end
  end

  describe "streaming" do
    defp subagent_events(events), do: Enum.filter(events, &(&1.metadata[:tool_call_id] == "task-1"))

    test "a subagent's events reach the parent's stream under its namespace, live or collected" do
      opts = [context: %{subagent: "shipping_clerk"}]
      input = %{messages: ["Where is A-1?"]}

      assert {:ok, live} = DelegatingDesk.stream_events(input, [live: true] ++ opts)
      live = Enum.to_list(live)
      assert {:ok, collected} = DelegatingDesk.stream_events(input, opts)

      child = subagent_events(live)
      assert child != []
      assert Enum.all?(child, &(&1.namespace == ["tools", "subagent.shipping_clerk"]))
      assert Enum.all?(child, &(&1.metadata.subagent_name == "shipping_clerk"))
      assert Enum.any?(child, &match?(%{event: %Events.ToolStart{tool_name: "lookup_order"}}, &1))

      shape = fn events -> for envelope <- subagent_events(events), do: envelope.event.__struct__ end
      assert shape.(collected) == shape.(live)
    end

    test "StreamTransformer turns the events into one run per task call" do
      {:ok, events} =
        DelegatingDesk.stream_events(%{messages: ["Where is A-1?"]}, live: true, context: %{subagent: "shipping_clerk"})

      transformer = StreamTransformer.new(subagent_names: ["shipping_clerk"])
      {:ok, transformer, [_started]} = StreamTransformer.process_many(transformer, events)

      assert [%RunStream{status: :completed} = run] = transformer.log
      assert run.graph_name == "shipping_clerk"
      assert run.path == ["tools", "subagent.shipping_clerk"]
      assert run.task_input == "Refund A-7."
      assert RunStream.cause(run) == %{"type" => "toolCall", "tool_call_id" => "task-1"}

      assert run |> RunStream.output() |> Map.fetch!(:messages) |> List.last() |> Message.text() ==
               "A-1 shipped Monday."
    end
  end

  describe "human review inside a subagent" do
    test "a subagent's pause carries its response_schema, and an answer that doesn't match waits for another" do
      opts = thread("budget-1")
      schema = %{"type" => "integer"}

      assert {:interrupted, %{response_schema: ^schema, interrupts: [%{response_schema: ^schema}]}} =
               BudgetDesk.invoke(%{messages: ["Check the budget."]}, opts)

      assert {:error, %Error{type: :invalid_resume}} = BudgetDesk.resume("plenty", opts)
      assert {:ok, result} = BudgetDesk.resume(100, opts)
      assert result.messages |> List.last() |> Message.text() == "Done."
    end

    test "pauses the parent with the subagent's review and resuming the parent finishes the task" do
      opts = thread("review-1")

      assert {:interrupted, interrupt} = Desk.invoke(%{messages: ["Refund A-1, please."]}, opts)
      refute_received {:refunded, _order}

      assert {:ok, review} = HITL.from_interrupt(interrupt)
      assert [%{name: "issue_refund", args: %{"order_id" => "A-1"}}] = review.action_requests
      assert review.metadata.subagent_name == "refund_clerk"

      assert {:ok, result} = Desk.resume_review([HITL.decision(:approve)], opts)
      assert_received {:refunded, "A-1"}
      assert tool_texts(result) == ["Refunded A-1."]
      assert result.messages |> List.last() |> Message.text() == "Done."
    end

    test "a review two subagents deep pauses the top run and resumes all the way down" do
      opts = thread("review-nested")

      assert {:interrupted, interrupt} = ManagedDesk.invoke(%{messages: ["Refund A-1."]}, opts)
      assert {:ok, review} = HITL.from_interrupt(interrupt)
      assert [%{name: "issue_refund"}] = review.action_requests
      assert review.metadata.subagent_name == "refund_clerk"

      assert {:ok, result} = ManagedDesk.resume_review([HITL.decision(:approve)], opts)
      assert_received {:refunded, "A-1"}
      assert tool_texts(result) == ["The clerk refunded A-1."]
    end

    test "a rejection reaches the subagent's model" do
      opts = thread("review-reject")

      assert {:interrupted, _interrupt} = Desk.invoke(%{messages: ["Refund A-1, please."]}, opts)
      assert {:ok, result} = Desk.resume_review([HITL.decision(:reject, message: "Not today.")], opts)

      refute_received {:refunded, _order}
      assert result.messages |> List.last() |> Message.text() == "Done."
    end

    test "parallel subagents pause one review at a time, and a finished sibling doesn't run again" do
      opts = thread("review-parallel")

      assert {:interrupted, first} = BusyDesk.invoke(%{messages: ["Refund A-1 and A-2."]}, opts)
      assert {:ok, %{action_requests: [%{args: %{"order_id" => "A-1"}}]}} = HITL.from_interrupt(first)
      assert received_model_calls("historian") == 1

      assert {:interrupted, second} = BusyDesk.resume_review([HITL.decision(:approve)], opts)
      assert_received {:refunded, "A-1"}
      refute_received {:refunded, "A-2"}
      assert {:ok, %{action_requests: [%{args: %{"order_id" => "A-2"}}]}} = HITL.from_interrupt(second)

      assert {:ok, result} = BusyDesk.resume_review([HITL.decision(:approve)], opts)
      assert_received {:refunded, "A-2"}
      refute_received {:refunded, "A-1"}
      assert received_model_calls("historian") == 0

      assert tool_texts(result) == ["clerk: Refunded A-1.", "Three orders.", "clerk: Refunded A-2."]
    end

    test "a subagent that reviews each call on its own pauses the parent with every review" do
      opts = thread("review-per-call")

      assert {:interrupted, interrupt} = PerCallDesk.invoke(%{messages: ["Refund A-1 and A-2."]}, opts)
      refute_received {:refunded, _order}

      assert interrupt.interrupts |> Enum.map(& &1.value.args["order_id"]) |> Enum.sort() == ["A-1", "A-2"]
      assert Enum.all?(interrupt.interrupts, &(&1.metadata.subagent_name == "per_call_clerk"))
      assert {:ok, snapshot} = PerCallDesk.get_state(opts)

      assert snapshot.interrupts |> Enum.map(& &1.id) |> Enum.sort() ==
               interrupt.interrupts |> Enum.map(& &1.id) |> Enum.sort()

      approve_a1 = Enum.find(interrupt.interrupts, &(&1.value.args["order_id"] == "A-1"))
      assert {:interrupted, second} = PerCallDesk.resume_review(%{approve_a1.id => HITL.decision(:approve)}, opts)
      assert_received {:refunded, "A-1"}
      assert [%{value: %{args: %{"order_id" => "A-2"}}}] = second.interrupts

      answers = Map.new(second.interrupts, &{&1.id, HITL.decision(:reject, message: "Not A-2.")})
      assert {:ok, result} = PerCallDesk.resume_review(answers, opts)
      refute_received {:refunded, "A-2"}
      refute_received {:refunded, "A-1"}
      assert tool_texts(result) == ["Refunded both."]
    end

    test "a new message while a subagent's review waits cancels the review, and the parent answers it" do
      opts = thread("review-new-message")

      assert {:interrupted, _interrupt} = Desk.invoke(%{messages: ["Refund A-1, please."]}, opts)
      assert {:ok, result} = Desk.invoke(%{messages: ["Never mind."]}, opts)
      refute_received {:refunded, _order}

      assert Enum.map(result.messages, & &1.role) == [:user, :assistant, :tool, :user, :assistant]

      assert [%Message{status: "error", tool_call_id: "call_0_0"} = cancelled] =
               Enum.filter(result.messages, &(&1.role == :tool))

      assert Message.text(cancelled) ==
               "Tool call task with id call_0_0 was not run: a new message came in while it waited for review."

      assert {:ok, snapshot} = Desk.get_state(opts)
      assert snapshot.interrupts == []
      assert Enum.map(snapshot.values.messages, & &1.role) == Enum.map(result.messages, & &1.role)
    end

    test "a new message cancels parallel subagents' reviews, and a finished sibling's answer stays with its turn" do
      opts = thread("review-parallel-new-message")

      assert {:interrupted, _first} = BusyDesk.invoke(%{messages: ["Refund A-1 and A-2."]}, opts)
      assert received_model_calls("historian") == 1

      assert {:ok, result} = BusyDesk.invoke(%{messages: ["Stop."]}, opts)
      refute_received {:refunded, _order}
      assert received_model_calls("historian") == 0

      assert Enum.map(result.messages, & &1.role) == [:user, :assistant, :tool, :tool, :tool, :user, :assistant]
      assert [a1, "Three orders.", a2] = tool_texts(result)
      assert a1 =~ "was not run: a new message came in while it waited for review."
      assert a2 =~ "was not run: a new message came in while it waited for review."
    end

    test "decisions that don't fit the subagent's review fail the parent's resume" do
      opts = thread("review-invalid")

      assert {:interrupted, _interrupt} = Desk.invoke(%{messages: ["Refund A-1, please."]}, opts)

      assert {:error, %Error{type: :invalid_human_decision}} =
               Desk.resume_review([HITL.decision(:approve), HITL.decision(:approve)], opts)

      refute_received {:refunded, _order}

      # The review is still pending, and one valid resume finishes it.
      assert {:ok, _result} = Desk.resume_review([HITL.decision(:approve)], opts)
      assert_received {:refunded, _order}
    end

    test "a parent without a checkpointer refuses to start when a subagent reviews tools" do
      assert {:error, %Error{type: :missing_checkpointer}} = Desk.invoke(%{messages: ["Refund A-1, please."]})
    end

    test "a parent without a checkpointer refuses to start when a subagent's own subagent reviews tools" do
      # The clerk two levels down used to run without a checkpointer and fail
      # inside the task.
      assert {:error, %Error{type: :missing_checkpointer}} = ManagedDesk.invoke(%{messages: ["Refund A-1."]})
      refute_received {:refunded, _order}

      manager = fn clerk ->
        %{
          name: "refund_manager",
          description: "Delegates refunds to the clerk.",
          model: "fake:chat",
          model_opts: [
            responses: [
              FakeChatModel.tool_call("task", %{"subagent_type" => "refund_clerk", "description" => "Refund A-1."}),
              "The clerk refunded A-1."
            ]
          ],
          subagents: [clerk]
        }
      end

      desk = fn clerk ->
        Agent.build(
          model: "fake:chat",
          model_opts: [
            responses: [
              FakeChatModel.tool_call("task", %{"subagent_type" => "refund_manager", "description" => "Refund A-1."}),
              "Done."
            ]
          ],
          subagents: [manager.(clerk)]
        )
      end

      assert {:ok, agent} = desk.(Spec.from_agent_module(RefundClerk))
      assert {:error, %Error{type: :missing_checkpointer}} = Agent.invoke(agent, %{messages: ["Refund A-1."]})

      assert {:ok, agent} = desk.(Spec.from_agent_module(RefundClerk, interrupt_on: false))
      assert {:ok, result} = Agent.invoke(agent, %{messages: ["Refund A-1."]})
      assert_received {:refunded, "A-1"}
      assert tool_texts(result) == ["The clerk refunded A-1."]
    end

    test "agent modules that name each other as subagents run without a checkpointer" do
      assert {:ok, result} = Triage.invoke(%{messages: ["Hello?"]})
      assert result.messages |> List.last() |> Message.text() == "Sorted."
    end

    test "a subagent takes the parent's review rules unless its line turns them off" do
      input = %{messages: ["Refund A-7."]}

      assert {:interrupted, interrupt} =
               ReviewedDesk.invoke(input, thread("rules-inherited") ++ [context: %{subagent: "clerk"}])

      assert {:ok, %{action_requests: [%{name: "issue_refund"}]}} = HITL.from_interrupt(interrupt)
      refute_received {:refunded, _order}

      for name <- ["clerk_without_rules", "clerk_with_empty_rules"] do
        assert {:ok, result} = ReviewedDesk.invoke(input, thread("rules-#{name}") ++ [context: %{subagent: name}])
        assert_received {:refunded, "A-7"}
        assert tool_texts(result) == ["clerk: Refunded A-7."]
      end
    end
  end
end
