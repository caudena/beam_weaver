# Benchmarks of the agent and graph hot paths, to compare two checkouts.
# Development only: not part of the package or the test suite.
#
#     MIX_ENV=prod mix run scripts/bench/hot_paths.exs
#     MIX_ENV=prod mix run scripts/bench/hot_paths.exs --reps 9 --only agent_invoke,graph_seq10_checkpointer
#     MIX_ENV=prod mix run scripts/bench/hot_paths.exs --out /tmp/current.tsv
#
# Each case runs a warmup, then `--reps` timed repetitions of its operation
# and reports the median, minimum and maximum milliseconds per operation. Run
# the same file in two checkouts with the same MIX_ENV to compare them: it
# uses only APIs that older checkouts have too, and prints a note when a
# result shows that a checkout behaves differently (such as ignoring a
# per-call checkpointer). The `_one_thread` cases call the agent 20 times on
# one thread, which grows by four messages a call, and report the mean.

defmodule Bench.Script do
  alias BeamWeaver.Models.FakeChatModel

  # One tool call and one answer per user message, for `turns` messages.
  def tool_then_answer(turns) do
    Enum.flat_map(1..turns, fn turn ->
      [FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-#{1000 + turn}"}), "Order A-#{1000 + turn} shipped."]
    end)
  end
end

defmodule Bench.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped on Monday."}
end

defmodule Bench.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday."
    ]

  system_prompt "You are Acme's support agent."
  tools [Bench.Tools.LookupOrder]
end

defmodule Bench.LimitedAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday."
    ]

  system_prompt "You are Acme's support agent."
  tools [Bench.Tools.LookupOrder]
  middleware [{Middleware.ModelCallLimit, run_limit: 5}, {Middleware.ToolCallLimit, run_limit: 5}]
end

defmodule Bench.ThreadAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: Bench.Script.tool_then_answer(60)
  system_prompt "You are Acme's support agent."
  tools [Bench.Tools.LookupOrder]
end

defmodule Bench.PolicyExpert do
  use BeamWeaver.Agent

  name "policy_expert"
  description "Answers questions about Acme's refund and return policies."

  model BeamWeaver.Models.init_chat_model!("fake:chat",
          responses: ["Yes. Orders can be refunded within 30 days of delivery, so A-1001 qualifies."]
        )

  system_prompt "You know Acme's refund policy. Answer in one or two sentences."
end

defmodule Bench.Researcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{
        "subagent_type" => "policy_expert",
        "description" => "Order A-1001 was delivered 10 days ago. Can the customer get a refund?"
      }),
      "Good news: order A-1001 can be refunded."
    ]

  system_prompt "You are Acme's support researcher. Ask the policy expert about refund rules."

  subagents do
    subagent Bench.PolicyExpert
  end
end

defmodule Bench.Graphs do
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Send

  def sequential(count) do
    names = Enum.map(1..count, &:"step_#{&1}")

    graph =
      Enum.reduce(names, Graph.new(), fn name, graph ->
        Graph.add_node(graph, name, fn %{count: count} -> %{count: count + 1} end)
      end)

    {graph, last} =
      Enum.reduce(names, {graph, Graph.start()}, fn name, {graph, previous} ->
        {Graph.add_edge(graph, previous, name), name}
      end)

    Graph.add_edge(graph, last, Graph.end_node())
  end

  # `split` sends one `work` task per id; `collect` runs once they are done,
  # after a plain edge (`:edge`) or a join (`:join`).
  def fan_out(join) do
    split = fn %{ids: ids} -> Enum.map(ids, &%Send{node: :work, update: %{id: &1}}) end
    work = fn %{id: id} -> %{results: [id * 2]} end
    collect = fn %{results: results} -> %{total: Enum.sum(results)} end

    graph =
      Graph.new()
      |> Graph.add_reducer(:results, &(&1 ++ &2))
      |> Graph.add_node(:split, split)
      |> Graph.add_node(:work, work)
      |> Graph.add_node(:collect, collect)
      |> Graph.add_edge(Graph.start(), :split)
      |> Graph.add_edge(:collect, Graph.end_node())

    case join do
      :edge -> Graph.add_edge(graph, :work, :collect)
      :join -> Graph.add_join(graph, [:work], :collect)
    end
  end
end

defmodule Bench do
  alias BeamWeaver.Agent
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled

  @question %{messages: ["Where is my order A-1001?"]}
  @answer "Your order A-1001 shipped on Monday."

  def main(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [reps: :integer, warmup: :integer, only: :string, out: :string, scale: :float])

    only = opts |> Keyword.get(:only, "") |> String.split(",", trim: true)
    selected = Enum.filter(cases(), &(only == [] or &1.name in only))

    IO.puts("""
    BeamWeaver #{Application.spec(:beam_weaver, :vsn)}, Elixir #{System.version()}, \
    OTP #{System.otp_release()}, MIX_ENV=#{Mix.env()}, #{System.schedulers_online()} schedulers
    """)

    IO.puts(String.pad_trailing("case", 44) <> "  median ms    min ms    max ms  ops/rep  note")

    results =
      Enum.map(selected, fn bench_case ->
        result = run_case(bench_case, opts)

        IO.puts(
          String.pad_trailing(bench_case.name, 44) <>
            format_ms(result.median) <>
            format_ms(result.min) <>
            format_ms(result.max) <>
            String.pad_leading(Integer.to_string(result.iters), 9) <> "  " <> result.note
        )

        result
      end)

    if path = opts[:out] do
      lines = Enum.map(results, &Enum.join([&1.name, &1.median, &1.min, &1.max, &1.note], "\t"))
      File.write!(path, Enum.join(lines, "\n") <> "\n")
    end
  end

  # Runs one case: its check, a warmup, then the timed repetitions. Each
  # repetition gets a fresh context from `setup` (not timed) and runs
  # `iters` operations.
  defp run_case(bench_case, opts) do
    reps = Keyword.get(opts, :reps, 7)
    warmup = Keyword.get(opts, :warmup, 2)
    iters = max(round(bench_case.iters * Keyword.get(opts, :scale, 1.0)), 1)

    note =
      with_context(bench_case, fn context -> bench_case.check.(bench_case.run.(context, 0), context) end)

    for _rep <- 1..warmup, do: with_context(bench_case, &run_iters(bench_case, &1, iters))

    samples =
      for _rep <- 1..reps do
        with_context(bench_case, fn context ->
          :erlang.garbage_collect()
          started = System.monotonic_time()
          run_iters(bench_case, context, iters)
          elapsed = System.monotonic_time() - started
          System.convert_time_unit(elapsed, :native, :microsecond) / 1000 / iters
        end)
      end

    sorted = Enum.sort(samples)

    %{
      name: bench_case.name,
      median: Enum.at(sorted, div(length(sorted), 2)),
      min: List.first(sorted),
      max: List.last(sorted),
      iters: iters,
      note: note
    }
  end

  defp run_iters(bench_case, context, iters) do
    for index <- 1..iters, do: bench_case.run.(context, index)
    :ok
  end

  defp with_context(bench_case, fun) do
    context = bench_case.setup.()

    try do
      fun.(context)
    after
      teardown(context)
    end
  end

  defp teardown(%{saver: %Checkpoint.ETS{} = saver}) do
    for table <- [saver.checkpoints, saver.writes, saver.counter], do: :ets.delete(table)
    :ok
  end

  defp teardown(_context), do: :ok

  defp format_ms(ms), do: ms |> :erlang.float_to_binary(decimals: 3) |> String.pad_leading(10)

  defp cases do
    [
      %{
        name: "agent_invoke",
        iters: 100,
        setup: fn -> %{} end,
        run: fn _context, _index -> Bench.SupportAgent.invoke(@question) end,
        check: fn result, _context -> check_answer(result) end
      },
      %{
        name: "agent_invoke_middleware",
        iters: 100,
        setup: fn -> %{} end,
        run: fn _context, _index -> Bench.LimitedAgent.invoke(@question) end,
        check: fn result, _context -> check_answer(result) end
      },
      %{
        name: "agent_invoke_checkpointer",
        iters: 100,
        setup: fn -> %{saver: Checkpoint.ETS.new()} end,
        run: fn %{saver: saver}, index ->
          Bench.SupportAgent.invoke(@question, checkpointer: saver, config: thread("t#{index}"))
        end,
        check: fn result, _context -> check_answer(result) end
      },
      %{
        name: "agent_invoke_checkpointer_one_thread",
        iters: 20,
        setup: fn -> %{saver: Checkpoint.ETS.new()} end,
        run: fn %{saver: saver}, _index ->
          Bench.ThreadAgent.invoke(%{messages: ["And my next order?"]}, checkpointer: saver, config: thread("one"))
        end,
        check: fn {:ok, %{messages: messages}}, _context -> "#{length(messages)} messages after one call" end
      },
      %{
        name: "agent_stream_collected",
        iters: 100,
        setup: fn -> %{} end,
        run: fn _context, _index -> Bench.SupportAgent.stream_events(@question) end,
        check: fn {:ok, events}, _context -> "#{length(events)} events" end
      },
      %{
        name: "agent_stream_live",
        iters: 100,
        setup: fn -> %{} end,
        run: fn _context, _index ->
          {:ok, stream} = Bench.SupportAgent.stream_events(@question, live: true)
          Enum.to_list(stream)
        end,
        check: fn events, _context -> "#{length(events)} events" end
      },
      %{
        name: "built_invoke",
        iters: 100,
        setup: fn -> %{agent: build_agent([])} end,
        run: fn %{agent: agent}, _index -> Agent.invoke(agent, @question) end,
        check: fn result, _context -> check_answer(result) end
      },
      %{
        name: "built_invoke_build_checkpointer",
        iters: 100,
        setup: fn ->
          saver = Checkpoint.ETS.new()
          %{saver: saver, agent: build_agent(checkpointer: saver)}
        end,
        run: fn %{agent: agent}, index -> Agent.invoke(agent, @question, config: thread("t#{index}")) end,
        check: fn result, _context -> check_answer(result) end
      },
      %{
        name: "built_invoke_call_checkpointer",
        iters: 100,
        setup: fn -> %{saver: Checkpoint.ETS.new(), agent: build_agent([])} end,
        run: fn %{saver: saver, agent: agent}, index ->
          Agent.invoke(agent, @question, checkpointer: saver, config: thread("t#{index}"))
        end,
        check: fn result, %{saver: saver, agent: agent} ->
          check_answer(result) <> saved_note(Agent.get_state(agent, checkpointer: saver, config: thread("t0")))
        end
      },
      %{
        name: "built_invoke_call_checkpointer_one_thread",
        iters: 20,
        setup: fn -> %{saver: Checkpoint.ETS.new(), agent: build_agent([], Bench.Script.tool_then_answer(60))} end,
        run: fn %{saver: saver, agent: agent}, _index ->
          Agent.invoke(agent, %{messages: ["And my next order?"]}, checkpointer: saver, config: thread("one"))
        end,
        check: fn {:ok, %{messages: messages}}, _context -> "#{length(messages)} messages after one call" end
      },
      %{
        name: "graph_seq10_checkpointer",
        iters: 100,
        setup: fn ->
          saver = Checkpoint.ETS.new()
          %{saver: saver, graph: Graph.compile!(Bench.Graphs.sequential(10), checkpointer: saver)}
        end,
        run: fn %{graph: graph}, index -> Compiled.invoke(graph, %{count: 0}, config: thread("t#{index}")) end,
        check: fn {:ok, %{count: 10}}, _context -> "" end
      },
      %{
        name: "graph_send50",
        iters: 50,
        setup: fn -> %{graph: Graph.compile!(Bench.Graphs.fan_out(:edge))} end,
        run: fn %{graph: graph}, _index -> Compiled.invoke(graph, fan_out_input()) end,
        check: fn result, _context -> check_fan_out(result) end
      },
      %{
        name: "graph_send50_checkpointer",
        iters: 50,
        setup: fn ->
          saver = Checkpoint.ETS.new()
          %{saver: saver, graph: Graph.compile!(Bench.Graphs.fan_out(:edge), checkpointer: saver)}
        end,
        run: fn %{graph: graph}, index -> Compiled.invoke(graph, fan_out_input(), config: thread("t#{index}")) end,
        check: fn result, _context -> check_fan_out(result) end
      },
      %{
        name: "graph_send50_join_checkpointer",
        iters: 50,
        setup: fn ->
          saver = Checkpoint.ETS.new()
          %{saver: saver, graph: Graph.compile!(Bench.Graphs.fan_out(:join), checkpointer: saver)}
        end,
        run: fn %{graph: graph}, index -> Compiled.invoke(graph, fan_out_input(), config: thread("t#{index}")) end,
        check: fn result, _context -> check_fan_out(result) end
      },
      %{
        name: "graph_get_state_50_checkpoints",
        iters: 200,
        setup: fn ->
          saver = Checkpoint.ETS.new()
          graph = Graph.compile!(Bench.Graphs.sequential(10), checkpointer: saver)

          fill_thread(fn -> Compiled.invoke(graph, %{count: 0}, config: thread("one")) end, fn ->
            Compiled.get_state_history(graph, thread("one"))
          end)

          %{saver: saver, graph: graph}
        end,
        run: fn %{graph: graph}, _index -> Compiled.get_state(graph, thread("one")) end,
        check: fn {:ok, %{values: %{count: 10}}}, _context -> "" end
      },
      %{
        name: "agent_get_state_50_checkpoints",
        iters: 100,
        setup: fn ->
          saver = Checkpoint.ETS.new()
          opts = [checkpointer: saver, config: thread("one")]

          fill_thread(fn -> Bench.ThreadAgent.invoke(%{messages: ["Where is my order?"]}, opts) end, fn ->
            {:ok, graph} = Agent.compiled_graph(Bench.ThreadAgent, checkpointer: saver)
            Compiled.get_state_history(graph, thread("one"))
          end)

          %{saver: saver, opts: opts}
        end,
        run: fn %{opts: opts}, _index -> Bench.ThreadAgent.get_state(opts) end,
        check: fn {:ok, %{values: %{messages: messages}}}, _context -> "#{length(messages)} messages" end
      },
      %{
        name: "built_get_state_call_checkpointer",
        iters: 100,
        setup: fn ->
          saver = Checkpoint.ETS.new()
          agent = build_agent([])
          opts = [checkpointer: saver, config: thread("one")]
          {:ok, _state} = Agent.invoke(agent, @question, opts)
          %{saver: saver, agent: agent, opts: opts}
        end,
        run: fn %{agent: agent, opts: opts}, _index -> Agent.get_state(agent, opts) end,
        check: fn result, _context -> saved_note(result) end
      },
      %{
        name: "deep_agent_task",
        iters: 50,
        setup: fn -> %{} end,
        run: fn _context, _index -> Bench.Researcher.invoke(%{messages: ["Can I get a refund for order A-1001?"]}) end,
        check: fn {:ok, %{messages: messages}}, _context ->
          tool = Enum.find(messages, &(&1.role == :tool))
          "task answer: #{inspect(String.slice(Message.text(tool), 0, 24))}"
        end
      }
    ]
  end

  # The support agent built with `Agent.build/1`, with extra build options
  # and, optionally, another script for its model.
  defp build_agent(opts, responses \\ nil) do
    responses =
      responses ||
        [
          BeamWeaver.Models.FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
          @answer
        ]

    {:ok, agent} =
      Agent.build(
        [
          model: "fake:chat",
          model_opts: [responses: responses],
          system_prompt: "You are Acme's support agent.",
          tools: [Bench.Tools.LookupOrder]
        ] ++ opts
      )

    agent
  end

  # Runs `invoke` on one thread until it has about 50 checkpoints.
  defp fill_thread(invoke, history) do
    Enum.reduce_while(1..100, 0, fn _call, _count ->
      {:ok, _result} = invoke.()
      count = length(history.())
      if count >= 50, do: {:halt, count}, else: {:cont, count}
    end)
  end

  defp thread(id), do: %{"configurable" => %{"thread_id" => id}}

  defp fan_out_input, do: %{ids: Enum.to_list(1..50), results: []}

  defp check_answer({:ok, %{messages: messages}}) do
    case List.last(messages) do
      %Message{} = message ->
        if Message.text(message) == @answer and length(messages) == 4,
          do: "",
          else: "unexpected answer: #{inspect(Message.text(message))}"
    end
  end

  defp check_fan_out({:ok, %{total: 2550}}), do: ""

  defp saved_note({:ok, %{values: %{messages: messages}}}), do: " (thread saved, #{length(messages)} messages)"
  defp saved_note(:error), do: " (per-call checkpointer ignored: nothing saved)"
end

Bench.main(System.argv())
