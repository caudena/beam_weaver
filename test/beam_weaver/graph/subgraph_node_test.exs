defmodule BeamWeaver.Graph.SubgraphNodeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Messages
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Graph.Send

  defmodule SupportAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["Your order A-1001 shipped on Monday."]
    system_prompt "You are Acme's support agent."
  end

  defmodule ApprovalGraph do
    use BeamWeaver.Agent

    alias BeamWeaver.Graph

    def graph do
      Graph.new(name: "Approval")
      |> Graph.add_reducer(:notes, &(&1 ++ &2))
      |> Graph.add_node(:prepare, fn _state -> %{notes: ["prepared"]} end)
      |> Graph.add_node(:ask, fn %{amount: amount} ->
        approved = Graph.interrupt(%{question: "Refund $#{amount}?"}) == "yes"
        %{approved: approved, notes: ["asked"]}
      end)
      |> Graph.add_edge(Graph.start(), :prepare)
      |> Graph.add_edge(:prepare, :ask)
      |> Graph.add_edge(:ask, Graph.end_node())
    end
  end

  defp single_node_graph(graph, name, node, opts \\ []) do
    graph
    |> Graph.add_node(name, node, opts)
    |> Graph.add_edge(Graph.start(), name)
    |> Graph.add_edge(name, Graph.end_node())
    |> Graph.compile!()
  end

  defp notes_child(node_fun) do
    Graph.new(name: "Notes")
    |> Graph.add_reducer(:notes, &(&1 ++ &2))
    |> Graph.add_node(:work, node_fun)
    |> Graph.add_edge(Graph.start(), :work)
    |> Graph.add_edge(:work, Graph.end_node())
    |> Graph.compile!()
  end

  describe "an agent module as a node" do
    test "runs the agent and adds its messages to the conversation" do
      desk = single_node_graph(Graph.new(state_schema: Messages.state_schema()), :support, SupportAgent)

      assert {:ok, %{messages: messages}} =
               Compiled.invoke(desk, %{messages: ["Where is my order A-1001?"]})

      assert Enum.map(messages, &{&1.role, Message.text(&1)}) == [
               {:user, "Where is my order A-1001?"},
               {:assistant, "Your order A-1001 shipped on Monday."}
             ]

      assert Compiled.get_graph(desk).nodes["support"].metadata.module == SupportAgent
    end

    test "works with a plain messages key too" do
      desk = single_node_graph(Graph.new(), :support, SupportAgent)

      assert {:ok, %{messages: messages}} =
               Compiled.invoke(desk, %{messages: ["Where is my order A-1001?"]})

      assert Enum.map(messages, & &1.role) == [:user, :assistant]
    end

    test "pauses and resumes inside the module's graph" do
      saver = CheckpointETS.new()
      config = %{"configurable" => %{"thread_id" => "agent-node-interrupt"}}

      desk =
        Graph.new()
        |> Graph.add_reducer(:notes, &(&1 ++ &2))
        |> Graph.add_node(:approval, ApprovalGraph)
        |> Graph.add_edge(Graph.start(), :approval)
        |> Graph.add_edge(:approval, Graph.end_node())
        |> Graph.compile!(checkpointer: saver)

      assert {:interrupted, %{value: %{question: "Refund $40?"}}} =
               Compiled.invoke(desk, %{amount: 40, notes: ["opened"]}, config: config)

      assert {:ok, %{approved: true, notes: ["opened", "prepared", "asked"]}} =
               Compiled.resume(desk, "yes", config: config)
    end
  end

  describe "a subgraph and its parent's private keys" do
    test "a subgraph node gets the parent's public state, not its private keys" do
      saver = CheckpointETS.new()
      test_pid = self()

      child =
        Graph.new()
        |> Graph.add_node(:look, fn state ->
          send(test_pid, {:child_keys, state |> Map.keys() |> Enum.sort()})
          %{answer: "done"}
        end)
        |> Graph.add_edge(Graph.start(), :look)
        |> Graph.add_edge(:look, Graph.end_node())
        |> Graph.compile!()

      parent =
        Graph.new(
          state_schema: %{
            secret: Graph.private_channel(BeamWeaver.Graph.Channels.LastValue),
            topic: BeamWeaver.Graph.Channels.LastValue,
            answer: BeamWeaver.Graph.Channels.LastValue
          }
        )
        |> Graph.add_node(:prepare, fn _state -> %{secret: "token", topic: "refunds"} end)
        |> Graph.add_node(:child, child)
        |> Graph.add_edge(Graph.start(), :prepare)
        |> Graph.add_edge(:prepare, :child)
        |> Graph.add_edge(:child, Graph.end_node())
        |> Graph.compile!(checkpointer: saver)

      config = %{"configurable" => %{"thread_id" => "private-keys-subgraph"}}
      assert {:ok, %{answer: "done", topic: "refunds"}} = Compiled.invoke(parent, %{}, config: config)

      assert_received {:child_keys, keys}
      assert :topic in keys
      refute :secret in keys

      # Nothing the child saved, in its own namespace, holds the parent's
      # private key either.
      tuples = BeamWeaver.Checkpoint.list(saver, nil)
      namespaces = Enum.map(tuples, &get_in(&1, [:config, "configurable", "checkpoint_ns"]))
      assert Enum.any?(namespaces, &String.starts_with?(&1, "child:"))

      for %{checkpoint: %{"channel_values" => values}} <- tuples do
        refute Map.has_key?(values, :secret)
        refute Map.has_key?(values, "secret")
      end
    end
  end

  describe "a subgraph that shares keys with its parent" do
    test "doesn't pass back a reducer value it didn't change" do
      child = notes_child(fn _state -> %{done: true} end)
      parent = single_node_graph(Graph.new() |> Graph.add_reducer(:notes, &(&1 ++ &2)), :child, child)

      assert Compiled.invoke(parent, %{notes: ["a"]}) == {:ok, %{notes: ["a"], done: true}}
    end

    test "passes back only what it appended to a list" do
      child = notes_child(fn _state -> %{notes: ["b"]} end)
      parent = single_node_graph(Graph.new() |> Graph.add_reducer(:notes, &(&1 ++ &2)), :child, child)

      assert Compiled.invoke(parent, %{notes: ["a"]}) == {:ok, %{notes: ["a", "b"]}}
    end

    test "passes back new and changed map entries" do
      child =
        Graph.new(name: "Checks")
        |> Graph.add_reducer(:checks, &Map.merge/2)
        |> Graph.add_node(:work, fn _state -> %{checks: %{fraud: :clear, policy: :ok}} end)
        |> Graph.add_edge(Graph.start(), :work)
        |> Graph.add_edge(:work, Graph.end_node())
        |> Graph.compile!()

      test_pid = self()

      merge = fn left, right ->
        send(test_pid, {:merged, right})
        Map.merge(left, right)
      end

      parent =
        single_node_graph(Graph.new() |> Graph.add_reducer(:checks, merge), :child, child)

      assert {:ok, %{checks: %{fraud: :clear, policy: :ok, region: :eu}}} =
               Compiled.invoke(parent, %{checks: %{fraud: :pending, region: :eu}})

      assert_receive {:merged, %{fraud: :clear, policy: :ok} = merged}
      refute Map.has_key?(merged, :region)
    end

    test "replaces a reducer value the subgraph rewrote" do
      child = notes_child(fn _state -> %{notes: Overwrite.new(["summary"])} end)
      parent = single_node_graph(Graph.new() |> Graph.add_reducer(:notes, &(&1 ++ &2)), :child, child)

      assert Compiled.invoke(parent, %{notes: ["a", "b"]}) == {:ok, %{notes: ["summary"]}}
    end

    test "parallel subgraph workers each add their own result once" do
      worker = notes_child(fn %{order_id: id} -> %{notes: ["#{id}: shipped"]} end)

      parent =
        Graph.new()
        |> Graph.add_reducer(:notes, &(&1 ++ &2))
        |> Graph.add_node(:split, fn %{order_ids: ids} ->
          Enum.map(ids, &%Send{node: :check_order, update: %{order_id: &1}})
        end)
        |> Graph.add_node(:check_order, worker)
        |> Graph.add_edge(Graph.start(), :split)
        |> Graph.add_edge(:check_order, Graph.end_node())
        |> Graph.compile!()

      assert {:ok, %{notes: notes}} =
               Compiled.invoke(parent, %{order_ids: ["A-1001", "A-1002"], notes: ["start"]})

      assert hd(notes) == "start"
      assert Enum.sort(tl(notes)) == ["A-1001: shipped", "A-1002: shipped"]
    end

    test "keeps to its output_schema and input_schema" do
      child =
        Graph.new(name: "Scoring", input_schema: %{amount: :number}, output_schema: %{score: :number})
        |> Graph.add_node(:score, fn state ->
          %{score: state.amount / 100, scratch: Map.keys(state)}
        end)
        |> Graph.add_edge(Graph.start(), :score)
        |> Graph.add_edge(:score, Graph.end_node())
        |> Graph.compile!()

      parent = single_node_graph(Graph.new(), :scoring, child)

      assert Compiled.invoke(parent, %{amount: 40, customer: "Ada"}) ==
               {:ok, %{amount: 40, customer: "Ada", score: 0.4}}
    end

    test "an output: function still receives the subgraph's whole final state" do
      child = notes_child(fn _state -> %{notes: ["b"]} end)

      parent =
        single_node_graph(Graph.new(), :child, child,
          output: fn %{notes: notes, ticket: ticket} -> %{summary: "#{ticket}: #{Enum.join(notes, ", ")}"} end
        )

      assert {:ok, %{summary: "T-1: a, b"}} = Compiled.invoke(parent, %{notes: ["a"], ticket: "T-1"})
    end

    test "a resumed subgraph doesn't receive the parent's state a second time" do
      saver = CheckpointETS.new()
      config = %{"configurable" => %{"thread_id" => "shared-key-resume"}}

      child =
        Graph.new(name: "Review")
        |> Graph.add_reducer(:notes, &(&1 ++ &2))
        |> Graph.add_node(:first, fn _state -> %{notes: ["b"]} end)
        |> Graph.add_node(:ask, fn _state -> %{notes: ["c: #{Graph.interrupt("ok?")}"]} end)
        |> Graph.add_edge(Graph.start(), :first)
        |> Graph.add_edge(:first, :ask)
        |> Graph.add_edge(:ask, Graph.end_node())
        |> Graph.compile!()

      parent =
        Graph.new()
        |> Graph.add_reducer(:notes, &(&1 ++ &2))
        |> Graph.add_node(:review, child)
        |> Graph.add_edge(Graph.start(), :review)
        |> Graph.add_edge(:review, Graph.end_node())
        |> Graph.compile!(checkpointer: saver)

      assert {:interrupted, _interrupt} = Compiled.invoke(parent, %{notes: ["a"]}, config: config)
      assert {:ok, %{notes: ["a", "b", "c: yes"]}} = Compiled.resume(parent, "yes", config: config)
    end
  end

  describe "a subgraph whose task runs again" do
    test "a retry continues the subgraph where it failed and adds the parent's state once" do
      review = review_child(fails: 1)

      parent =
        Graph.new()
        |> Graph.add_reducer(:notes, &(&1 ++ &2))
        |> Graph.add_node(:review, review, retry: 1)
        |> Graph.add_edge(Graph.start(), :review)
        |> Graph.add_edge(:review, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      assert {:ok, %{notes: ["opened", "drafted", "checked"]}} =
               Compiled.invoke(parent, %{notes: ["opened"]}, config: thread("subgraph-retry"))

      assert_received :drafted
      refute_received :drafted
    end

    test "continuing the parent after a failure continues the subgraph" do
      parent = review_parent(review_child(fails: 1), CheckpointETS.new())
      config = thread("subgraph-continue")

      assert {:error, %Error{type: :outage}} = Compiled.invoke(parent, %{notes: ["opened"]}, config: config)
      assert {:ok, %{notes: ["opened", "drafted", "checked"]}} = Compiled.invoke(parent, %{}, config: config)

      assert_received :drafted
      refute_received :drafted
    end

    test "the continued subgraph gets what changed in its input since it first ran" do
      review =
        Graph.new(name: "Review")
        |> Graph.add_reducer(:notes, &(&1 ++ &2))
        |> Graph.add_node(:draft, fn _state -> %{notes: ["drafted"]} end)
        |> Graph.add_node(:check, fn state ->
          if state[:approved_by],
            do: %{notes: ["checked by #{state.approved_by}"]},
            else: {:error, Error.new(:outage, "no approver")}
        end)
        |> Graph.add_edge(Graph.start(), :draft)
        |> Graph.add_edge(:draft, :check)
        |> Graph.add_edge(:check, Graph.end_node())
        |> Graph.compile!()

      parent =
        Graph.new()
        |> Graph.add_reducer(:notes, &(&1 ++ &2))
        |> Graph.add_node(:review, review)
        |> Graph.add_node(:tag, fn _state -> %{notes: ["tagged"]} end)
        |> Graph.add_edge(Graph.start(), :review)
        |> Graph.add_edge(Graph.start(), :tag)
        |> Graph.add_edge(:review, Graph.end_node())
        |> Graph.add_edge(:tag, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("subgraph-continue-input")

      assert {:error, %Error{type: :outage}} = Compiled.invoke(parent, %{notes: ["opened"]}, config: config)

      assert {:ok, %{notes: notes}} = Compiled.invoke(parent, %{approved_by: "Ada"}, config: config)
      assert Enum.sort(notes) == Enum.sort(["opened", "tagged", "drafted", "checked by Ada"])
    end

    test "replaying the parent from an earlier checkpoint runs the subgraph afresh" do
      saver = CheckpointETS.new()
      config = thread("subgraph-replay")

      parent =
        Graph.new()
        |> Graph.add_reducer(:notes, &(&1 ++ &2))
        |> Graph.add_node(:open, fn _state -> %{notes: ["opened"]} end)
        |> Graph.add_node(:review, review_child(fails: 0))
        |> Graph.add_edge(Graph.start(), :open)
        |> Graph.add_edge(:open, :review)
        |> Graph.add_edge(:review, Graph.end_node())
        |> Graph.compile!(checkpointer: saver)

      assert {:ok, %{notes: ["opened", "drafted", "checked"]}} = Compiled.invoke(parent, %{notes: []}, config: config)

      before_review = parent |> Compiled.get_state_history(config) |> Enum.find(&(&1.next == ["review"]))

      assert {:ok, %{notes: ["opened", "drafted", "checked"]}} =
               Compiled.invoke(parent, %{}, config: before_review.config)

      assert_received :drafted
      assert_received :drafted
    end
  end

  describe "a subgraph that paused" do
    test "keeps what the nodes beside it wrote in the paused step when it resumes" do
      parent =
        Graph.new()
        |> Graph.add_reducer(:notes, &(&1 ++ &2))
        |> Graph.add_node(:approval, asking_child())
        |> Graph.add_node(:lookup, fn _state -> %{notes: ["looked up"], status: "shipped"} end)
        |> Graph.add_edge(Graph.start(), :approval)
        |> Graph.add_edge(Graph.start(), :lookup)
        |> Graph.add_edge(:approval, Graph.end_node())
        |> Graph.add_edge(:lookup, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("paused-subgraph-sibling")

      assert {:interrupted, _interrupt} =
               Compiled.invoke(parent, %{notes: [], status: "open"}, config: config)

      assert {:ok, %{notes: ["looked up", "prepared", "asked: yes"], status: "shipped"}} =
               Compiled.resume(parent, "yes", config: config)
    end

    test "keeps the update of a command that resumes it" do
      parent = review_parent(asking_child(), CheckpointETS.new())
      config = thread("paused-subgraph-command")

      assert {:interrupted, _interrupt} = Compiled.invoke(parent, %{notes: [], status: "open"}, config: config)

      assert {:ok, %{notes: ["prepared", "asked: yes"], status: "escalated"}} =
               Compiled.invoke(parent, %Command{resume: "yes", update: %{status: "escalated"}}, config: config)
    end

    test "continues where it stopped after update_state, and the update stays" do
      parent = review_parent(asking_child(), CheckpointETS.new())
      config = thread("paused-subgraph-update")

      assert {:interrupted, _interrupt} = Compiled.invoke(parent, %{notes: [], status: "open"}, config: config)
      assert_received {:prepared, "open"}

      assert {:ok, _config} = Compiled.update_state(parent, config, %{status: "escalated", owner: "Ada"})
      assert {:ok, %{next: ["review"], values: %{status: "escalated"}}} = Compiled.get_state(parent, config)

      assert {:ok, %{notes: ["prepared", "asked: yes"], status: "escalated", owner: "Ada"}} =
               Compiled.resume(parent, "yes", config: config)

      refute_received {:prepared, _status}
    end

    test "without checkpoints of its own, runs again on what it started with" do
      parent = review_parent(asking_child(checkpointer: false), CheckpointETS.new())
      config = thread("paused-subgraph-no-checkpointer")

      assert {:interrupted, _interrupt} = Compiled.invoke(parent, %{notes: [], status: "open"}, config: config)
      assert_received {:prepared, "open"}

      assert {:ok, %{notes: ["prepared", "asked: yes"], status: "open"}} =
               Compiled.resume(parent, "yes", config: config)

      assert_received {:prepared, "open"}
    end
  end

  describe "a subgraph that keeps one thread across calls" do
    test "a retry continues the call where it failed" do
      review = review_child(fails: 1, checkpointer: true)

      parent =
        Graph.new()
        |> Graph.add_reducer(:notes, &(&1 ++ &2))
        |> Graph.add_node(:review, review, retry: 1)
        |> Graph.add_edge(Graph.start(), :review)
        |> Graph.add_edge(:review, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      assert {:ok, %{notes: ["opened", "drafted", "checked"]}} =
               Compiled.invoke(parent, %{notes: ["opened"]}, config: thread("shared-retry"))
    end

    test "a call that a breakpoint held back still runs as a new call" do
      notes =
        Graph.new(name: "Notes")
        |> Graph.add_reducer(:notes, &(&1 ++ &2))
        |> Graph.add_node(:take_note, fn %{subject: subject} -> %{notes: [subject]} end)
        |> Graph.add_edge(Graph.start(), :take_note)
        |> Graph.add_edge(:take_note, Graph.end_node())
        |> Graph.compile!(checkpointer: true)

      desk =
        Graph.new()
        |> Graph.add_node(:notes, notes,
          input: [:subject],
          output: fn %{notes: notes} -> %{ticket_notes: notes} end
        )
        |> Graph.add_edge(Graph.start(), :notes)
        |> Graph.add_edge(:notes, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new(), interrupt_before: [:notes])

      config = thread("shared-breakpoint")

      assert {:interrupted, _interrupt} = Compiled.invoke(desk, %{subject: "Where is A-1001?"}, config: config)
      assert {:ok, %{ticket_notes: ["Where is A-1001?"]}} = Compiled.resume(desk, nil, config: config)

      assert {:interrupted, _interrupt} = Compiled.invoke(desk, %{subject: "Refund for A-1001"}, config: config)

      assert {:ok, %{ticket_notes: ["Where is A-1001?", "Refund for A-1001"]}} =
               Compiled.resume(desk, nil, config: config)
    end
  end

  # `draft`, then `check`, which fails the first `fails:` times.
  defp review_child(opts) do
    fails = Keyword.fetch!(opts, :fails)
    test_pid = self()
    attempts = :counters.new(1, [])

    Graph.new(name: "Review")
    |> Graph.add_reducer(:notes, &(&1 ++ &2))
    |> Graph.add_node(:draft, fn _state ->
      send(test_pid, :drafted)
      %{notes: ["drafted"]}
    end)
    |> Graph.add_node(:check, fn _state ->
      :counters.add(attempts, 1, 1)

      if :counters.get(attempts, 1) <= fails,
        do: {:error, Error.new(:outage, "check failed")},
        else: %{notes: ["checked"]}
    end)
    |> Graph.add_edge(Graph.start(), :draft)
    |> Graph.add_edge(:draft, :check)
    |> Graph.add_edge(:check, Graph.end_node())
    |> Graph.compile!(Keyword.take(opts, [:checkpointer]))
  end

  # `prepare`, which reports the status it saw, then `ask`, which pauses. The
  # subgraph holds the parent's `status` from when it started.
  defp asking_child(opts \\ []) do
    test_pid = self()

    Graph.new(name: "Approval")
    |> Graph.add_reducer(:notes, &(&1 ++ &2))
    |> Graph.add_node(:prepare, fn %{status: status} ->
      send(test_pid, {:prepared, status})
      %{notes: ["prepared"]}
    end)
    |> Graph.add_node(:ask, fn _state -> %{notes: ["asked: #{Graph.interrupt("Refund?")}"]} end)
    |> Graph.add_edge(Graph.start(), :prepare)
    |> Graph.add_edge(:prepare, :ask)
    |> Graph.add_edge(:ask, Graph.end_node())
    |> Graph.compile!(opts)
  end

  defp review_parent(review, saver) do
    Graph.new()
    |> Graph.add_reducer(:notes, &(&1 ++ &2))
    |> Graph.add_node(:review, review)
    |> Graph.add_edge(Graph.start(), :review)
    |> Graph.add_edge(:review, Graph.end_node())
    |> Graph.compile!(checkpointer: saver)
  end

  defp thread(id), do: %{"configurable" => %{"thread_id" => id}}
end
