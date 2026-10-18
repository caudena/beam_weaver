defmodule BeamWeaver.Graph.CompiledTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.ExecutionPolicy
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Messages
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Graph.Send
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.TimeoutPolicy

  @uuidv7_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  defmodule StructState do
    defstruct foo: ""
  end

  defmodule ContextSchema do
    def json_schema do
      %{
        "type" => "object",
        "properties" => %{
          "x" => %{"type" => "integer", "title" => "X"},
          "y" => %{"type" => "string", "title" => "Y", "default" => "foo"}
        },
        "required" => ["x"]
      }
    end
  end

  defmodule RejectingChannel do
    use BeamWeaver.Graph.Channel

    defstruct [:key, value: Channel.missing()]

    def new(opts \\ []), do: %__MODULE__{key: Keyword.get(opts, :key)}

    @impl true
    def update(channel, _updates) do
      {:error,
       Channel.invalid_update("rejecting channel update failed", %{
         channel: channel.key
       })}
    end

    @impl true
    def get(%__MODULE__{value: value, key: key}) do
      if value == Channel.missing(), do: {:error, Channel.empty_error(key)}, else: {:ok, value}
    end

    @impl true
    def checkpoint(%__MODULE__{value: value}), do: value

    @impl true
    def from_checkpoint(channel, checkpoint), do: %{channel | value: checkpoint}

    @impl true
    def available?(%__MODULE__{value: value}), do: value != Channel.missing()
  end

  defmodule FailingCache do
    defstruct []

    def lookup(%__MODULE__{}, _namespace, _key, _opts), do: :miss

    def put(%__MODULE__{}, _namespace, _key, _value, _opts) do
      {:error, BeamWeaver.Core.Error.new(:cache_write_failed, "cache write failed")}
    end

    def delete(%__MODULE__{}, _namespace, _key, _opts), do: :ok
    def clear(%__MODULE__{}, _namespace, _opts), do: :ok
  end

  test "declared channel errors are returned instead of falling back to plain state writes" do
    graph =
      Graph.new()
      |> Graph.add_channel(:blocked, RejectingChannel)
      |> Graph.add_node(:echo, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :echo)
      |> Graph.add_edge(:echo, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :invalid_update,
              message: "rejecting channel update failed",
              details: %{channel: :blocked}
            }} = Compiled.invoke(graph, %{blocked: "hidden"})
  end

  test "a run that fails before its first step closes its trace run" do
    graph =
      Graph.new(name: "RejectedInputGraph")
      |> Graph.add_channel(:blocked, RejectingChannel)
      |> Graph.add_node(:echo, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :echo)
      |> Graph.add_edge(:echo, Graph.end_node())
      |> Graph.compile!()

    {result, root_id} =
      BeamWeaver.Tracing.with_run("rejected input", fn ->
        {Compiled.invoke(graph, %{blocked: "hidden"}), BeamWeaver.Tracing.capture_context().run_id}
      end)

    assert {:error, %Error{type: :invalid_update}} = result
    assert {:ok, %{children: [graph_run]}} = BeamWeaver.Tracing.get_tree(root_id)
    assert %{name: "RejectedInputGraph", status: :error, error: %{type: :invalid_update}} = graph_run.run
  end

  test "cached node put errors fail the task instead of reporting success" do
    graph =
      Graph.new()
      |> Graph.add_node(:cached, fn _state -> %{answer: 42} end, cache: true)
      |> Graph.add_edge(Graph.start(), :cached)
      |> Graph.add_edge(:cached, Graph.end_node())
      |> Graph.compile!(cache: %FailingCache{})

    assert {:error, %Error{type: :cache_write_failed, message: "cache write failed"}} =
             Compiled.invoke(graph, %{})
  end

  test "pending write merge errors are returned when restoring latest state" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :first, update: %{}},
          %Send{node: :second, update: %{}},
          %Send{node: :fail, update: %{}}
        ]
      end)
      |> Graph.add_node(:first, fn _state -> %{kept: "first"} end)
      |> Graph.add_node(:second, fn _state -> %{kept: "second"} end)
      |> Graph.add_node(:fail, fn _state -> {:error, Error.new(:node_failed, "boom")} end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:first, Graph.end_node())
      |> Graph.add_edge(:second, Graph.end_node())
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "bad-pending-write-merge"}}

    assert {:error, %Error{type: :node_failed}} = Compiled.invoke(graph, %{}, config: config)

    assert {:error,
            %Error{
              type: :invalid_update,
              message: "last-value channel can receive only one value per step",
              details: %{channel: :kept}
            }} = Compiled.get_state(graph, config)
  end

  test "runs a conditional graph and merges parallel node updates through reducers" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:items, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:route, fn state ->
        if state[:fanout], do: %Command{goto: :fanout}, else: %Command{goto: :direct}
      end)
      |> Graph.add_node(:direct, fn _state -> %{items: [:direct]} end)
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :worker, update: %{item: :a}},
          %Send{node: :worker, update: %{item: :b}}
        ]
      end)
      |> Graph.add_node(:worker, fn state -> %{items: [state.item]} end)
      |> Graph.add_edge(Graph.start(), :route)
      |> Graph.add_edge(:direct, Graph.end_node())
      |> Graph.add_edge(:worker, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{items: [:direct]}} = Compiled.invoke(graph, %{fanout: false, items: []})

    assert {:ok, %{items: items}} = Compiled.invoke(graph, %{fanout: true, items: []})
    assert Enum.sort(items) == [:a, :b]
  end

  test "mixed command and map node returns preserve ordered reducer writes" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:foo, fn existing, update -> existing <> update end)
      |> Graph.add_node(:my_node, fn _state ->
        [
          %Command{update: %{foo: "a"}},
          %{foo: "b"}
        ]
      end)
      |> Graph.add_edge(Graph.start(), :my_node)
      |> Graph.add_edge(:my_node, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{foo: "ab"}} = Compiled.invoke(graph, %{foo: ""})
  end

  test "command update accepts native schema structs" do
    graph =
      Graph.new()
      |> Graph.add_node(:node_a, fn _state ->
        %Command{update: %StructState{foo: "foo"}, goto: :node_b}
      end)
      |> Graph.add_node(:node_b, fn state -> %{foo: state.foo <> "bar"} end)
      |> Graph.add_edge(Graph.start(), :node_a)
      |> Graph.add_edge(:node_b, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{foo: "foobar"}} = Compiled.invoke(graph, %StructState{})
  end

  test "compiled graph exposes context JSON schema from native schema modules" do
    graph =
      Graph.new(context_schema: ContextSchema)
      |> Graph.add_node(:node, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :node)
      |> Graph.add_edge(:node, Graph.end_node())
      |> Graph.compile!()

    assert Compiled.get_context_json_schema(graph) == %{
             "type" => "object",
             "properties" => %{
               "x" => %{"type" => "integer", "title" => "X"},
               "y" => %{"type" => "string", "title" => "Y", "default" => "foo"}
             },
             "required" => ["x"]
           }
  end

  test "compiled graph loads unloaded context schema modules before falling back to type schema" do
    module = Module.concat(__MODULE__, :"UnloadedContextSchema#{System.unique_integer([:positive])}")
    tmp_dir = Path.join(System.tmp_dir!(), "beam_weaver_graph_schema_#{System.unique_integer([:positive])}")
    source_file = Path.join(tmp_dir, "unloaded_context_schema.ex")

    File.mkdir_p!(tmp_dir)

    File.write!(source_file, """
    defmodule #{inspect(module)} do
      def __beam_weaver_schema__ do
        %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}},
          "required" => ["value"]
        }
      end
    end
    """)

    assert {_output, 0} = System.cmd("elixirc", ["-o", tmp_dir, source_file], stderr_to_stdout: true)
    true = Code.prepend_path(String.to_charlist(tmp_dir))

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      Code.delete_path(String.to_charlist(tmp_dir))
      File.rm_rf(tmp_dir)
    end)

    :code.purge(module)
    :code.delete(module)
    assert :code.is_loaded(module) == false

    graph =
      Graph.new(context_schema: module)
      |> Graph.add_node(:node, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :node)
      |> Graph.add_edge(:node, Graph.end_node())
      |> Graph.compile!()

    assert Compiled.get_context_json_schema(graph) == %{
             "type" => "object",
             "properties" => %{"value" => %{"type" => "string"}},
             "required" => ["value"]
           }
  end

  test "compiled graph surfaces context schema module load failures" do
    module = Module.concat(__MODULE__, :"UnloadableContextSchema#{System.unique_integer([:positive])}")
    tmp_dir = Path.join(System.tmp_dir!(), "beam_weaver_bad_graph_schema_#{System.unique_integer([:positive])}")
    source_file = Path.join(tmp_dir, "unloadable_context_schema.ex")

    File.mkdir_p!(tmp_dir)

    File.write!(source_file, """
    defmodule #{inspect(module)} do
      @on_load :boom

      def boom, do: :erlang.error(:on_load_failed)

      def __beam_weaver_schema__, do: %{"type" => "object"}
    end
    """)

    assert {_output, 0} = System.cmd("elixirc", ["-o", tmp_dir, source_file], stderr_to_stdout: true)
    true = Code.prepend_path(String.to_charlist(tmp_dir))

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      Code.delete_path(String.to_charlist(tmp_dir))
      File.rm_rf(tmp_dir)
    end)

    graph =
      Graph.new(context_schema: module)
      |> Graph.add_node(:node, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :node)
      |> Graph.add_edge(:node, Graph.end_node())
      |> Graph.compile!()

    capture_log(fn ->
      assert_raise ArgumentError, ~r/:on_load_failure/, fn ->
        Compiled.get_context_json_schema(graph)
      end
    end)
  end

  test "graph input and output schemas project public state while reducers prepare node input" do
    graph =
      Graph.new(
        state_schema: Messages.state_schema(),
        input_schema: %{hello: :string, bye: :string, messages: :list},
        output_schema: %{messages: :list}
      )
      |> Graph.add_node(
        :a,
        fn state ->
          assert %{hello: "there", messages: [%Message{role: :user, content: "hello"}]} = state
          nil
        end,
        input: [:hello, :messages]
      )
      |> Graph.add_node(
        :b,
        fn state ->
          assert state == %{bye: "world"}
          %{now: 123, hello: "again"}
        end,
        input: [:bye]
      )
      |> Graph.add_node(
        :c,
        fn state ->
          assert state == %{hello: "again", now: 123}
          nil
        end,
        input: [:hello, :now]
      )
      |> Graph.add_edge(Graph.start(), :a)
      |> Graph.add_edge(:a, :b)
      |> Graph.add_edge(:b, :c)
      |> Graph.add_edge(:c, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{messages: [%Message{role: :user, content: "hello"}]}} =
             Compiled.invoke(graph, %{
               hello: "there",
               bye: "world",
               messages: "hello",
               now: 345
             })

    assert Compiled.get_input_json_schema(graph) == %{
             hello: :string,
             bye: :string,
             messages: :list
           }

    assert Compiled.get_output_json_schema(graph) == %{messages: :list}
  end

  test "single node input/output schemas support fixed and computed writes" do
    graph =
      Graph.new(
        input_schema: %{input: :integer},
        output_schema: %{output: :integer, fixed: :integer, output_plus_one: :integer}
      )
      |> Graph.add_node(
        :one,
        fn state ->
          output = state.input + 1
          %{output: output, fixed: 5, output_plus_one: output + 1, internal: :hidden}
        end,
        input: [:input]
      )
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(:one, Graph.end_node())
      |> Graph.compile!()

    assert Compiled.get_context_json_schema(graph) == %{}

    assert {:ok, %{output: 3, fixed: 5, output_plus_one: 4}} =
             Compiled.invoke(graph, %{input: 2, ignored: true})

    assert Compiled.get_graph(graph).output_channels == [
             "fixed",
             "output",
             "output_plus_one"
           ]
  end

  test "rejects parallel writes to a last-value state key" do
    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :worker, update: %{item: :a}},
          %Send{node: :worker, update: %{item: :b}}
        ]
      end)
      |> Graph.add_node(:worker, fn state -> %{answer: state.item} end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:worker, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :invalid_update,
              message: "last-value channel can receive only one value per step",
              details: %{channel: :answer}
            }} = Compiled.invoke(graph, %{})
  end

  test "overwrites reducer state once within a parallel step" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:items, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :reset},
          %Send{node: :append}
        ]
      end)
      |> Graph.add_node(:reset, fn _state -> %{items: %Overwrite{value: [:reset]}} end)
      |> Graph.add_node(:append, fn _state -> %{items: [:new]} end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:reset, Graph.end_node())
      |> Graph.add_edge(:append, Graph.end_node())
      |> Graph.compile!()

    # an Overwrite.
    assert {:ok, %{items: [:reset]}} = Compiled.invoke(graph, %{items: [:old]})
  end

  test "times out slow nodes and cancels pending siblings" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :slow},
          %Send{node: :sibling}
        ]
      end)
      |> Graph.add_node(:slow, fn _state -> Process.sleep(:infinity) end, timeout: 200)
      |> Graph.add_node(:sibling, hanging_node(parent), timeout: :infinity)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.add_edge(:sibling, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :node_timeout,
              message: "node timed out",
              details: %{node: "slow", step: 1, timeout: 200}
            }} = Compiled.invoke(graph, %{})

    assert_started_nodes_cancelled()
  end

  test "a node option the graph doesn't know is an error, not ignored" do
    result =
      Graph.new()
      |> Graph.add_node(:answer, fn _state -> %{} end, retry_policy: [max_attempts: 3])
      |> Graph.add_edge(Graph.start(), :answer)
      |> Graph.add_edge(:answer, Graph.end_node())
      |> Graph.compile()

    assert {:error, %Error{type: :invalid_graph, message: "graph contains invalid nodes", details: details}} = result
    assert [%{node: "answer", error: error}] = details.invalid
    assert error =~ ":retry_policy"
  end

  test "nodes and tool nodes have no time limit unless one is set" do
    graph =
      Graph.new()
      |> Graph.add_node(:answer, fn _state -> %{} end)
      |> Graph.add_node(:checked, fn _state -> %{} end, timeout: 200)
      |> Graph.add_edge(Graph.start(), :answer)
      |> Graph.add_edge(:answer, :checked)
      |> Graph.add_edge(:checked, Graph.end_node())
      |> Graph.compile!()

    assert graph.graph.nodes["answer"].timeout == :infinity
    assert graph.graph.nodes["checked"].timeout == 200
    assert BeamWeaver.Agent.ToolNode.new([]).timeout == :infinity
    assert {:ok, %{}} = Compiled.invoke(graph, %{})
  end

  test "an execution policy without a timeout sets no time limit" do
    graph =
      Graph.new()
      |> Graph.add_node(:options, fn _state -> %{} end, timeout: [max_concurrency: 2])
      |> Graph.add_node(:policy, fn _state -> %{} end, timeout: ExecutionPolicy.new!(metadata: %{team: :billing}))
      |> Graph.add_edge(Graph.start(), :options)
      |> Graph.add_edge(:options, :policy)
      |> Graph.add_edge(:policy, Graph.end_node())
      |> Graph.compile!()

    assert graph.graph.nodes["options"].timeout == :infinity
    assert graph.graph.nodes["policy"].timeout == :infinity
    assert {:ok, %{}} = Compiled.invoke(graph, %{})
  end

  test "a send's timeout takes the forms of a node's timeout" do
    stuck =
      fn timeout ->
        Graph.new()
        |> Graph.add_node(:fanout, fn _state -> %Send{node: :slow, timeout: timeout} end)
        |> Graph.add_node(:slow, fn _state -> Process.sleep(:infinity) end)
        |> Graph.add_edge(Graph.start(), :fanout)
        |> Graph.add_edge(:slow, Graph.end_node())
        |> Graph.compile!()
      end

    for timeout <- [ExecutionPolicy.new!(timeout: 10), [timeout: 10], %{"timeout" => 10}] do
      assert {:error, %Error{type: :node_timeout, details: %{node: "slow", timeout: 10}}} =
               Compiled.invoke(stuck.(timeout), %{})
    end

    assert {:error, %Error{type: :invalid_graph, message: "invalid node timeout policy"}} =
             Compiled.invoke(stuck.(-1), %{})
  end

  test "send timeout overrides the target node timeout" do
    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        %Send{node: :slow, update: %{source: :send}, timeout: 10}
      end)
      |> Graph.add_node(
        :slow,
        fn _state -> Process.sleep(:infinity) end,
        timeout: 1_000
      )
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :node_timeout,
              details: %{node: "slow", step: 1, timeout: 10}
            }} = Compiled.invoke(graph, %{})
  end

  test "float timeout durations normalize to milliseconds and report active budgets" do
    graph =
      Graph.new()
      |> Graph.add_node(
        :slow,
        fn _state -> Process.sleep(:infinity) end,
        timeout: 0.01
      )
      |> Graph.add_edge(Graph.start(), :slow)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!(step_timeout: 0.5, run_timeout: 1.0)

    assert {:error,
            %Error{
              type: :node_timeout,
              details: %{
                node: "slow",
                timeout: 10,
                node_timeout: 10,
                step_timeout: 500,
                run_timeout: 1_000
              }
            }} = Compiled.invoke(graph, %{})
  end

  test "timeout policy structs normalize at graph and dynamic send boundaries" do
    graph =
      Graph.new()
      |> Graph.add_node(
        :slow,
        fn _state -> Process.sleep(:infinity) end,
        timeout: TimeoutPolicy.new!(idle_timeout: 0.01, run_timeout: 0.5)
      )
      |> Graph.add_edge(Graph.start(), :slow)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :node_timeout,
              details: %{node: "slow", timeout: 10, node_timeout: 10}
            }} = Compiled.invoke(graph, %{})

    send_graph =
      Graph.new()
      |> Graph.add_node(
        :fanout,
        fn _state ->
          %Send{
            node: :slow,
            update: %{source: :send},
            timeout: TimeoutPolicy.new!(idle_timeout: 0.01)
          }
        end
      )
      |> Graph.add_node(
        :slow,
        fn _state -> Process.sleep(:infinity) end,
        timeout: 1_000
      )
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :node_timeout,
              details: %{node: "slow", timeout: 10, node_timeout: 10}
            }} = Compiled.invoke(send_graph, %{})
  end

  test "node timeout participates in retry policy before surfacing error" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    graph =
      Graph.new()
      |> Graph.add_node(
        :flaky_timeout,
        fn _state ->
          attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

          # The first attempt hangs until its timeout kills it; the retry
          # returns at once, well within its own budget.
          if attempt == 1, do: Process.sleep(:infinity)

          %{attempt: attempt}
        end,
        timeout: 500,
        retry:
          BeamWeaver.RetryPolicy.new!(
            max_attempts: 2,
            initial_delay: 0,
            retry_on: :node_timeout
          )
      )
      |> Graph.add_edge(Graph.start(), :flaky_timeout)
      |> Graph.add_edge(:flaky_timeout, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{attempt: 2}} = Compiled.invoke(graph, %{})
    assert Agent.get(attempts, & &1) == 2
  end

  test "a node timeout reports the configured timeout when the task backstop fires" do
    # The node times out after 10ms and its error handler then hangs, so the
    # awaiter's backstop for the whole task fires, not the per-attempt timeout.
    graph =
      Graph.new()
      |> Graph.add_node(:slow, fn _state -> Process.sleep(:infinity) end,
        timeout: 10,
        error_handler: fn _error -> Process.sleep(:infinity) end
      )
      |> Graph.add_edge(Graph.start(), :slow)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :node_timeout,
              details: %{node: "slow", timeout: 10, node_timeout: 10}
            }} = Compiled.invoke(graph, %{})
  end

  test "step timeout caps the whole superstep" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :slow_a},
          %Send{node: :slow_b}
        ]
      end)
      |> Graph.add_node(:slow_a, hanging_node(parent), timeout: 60_000)
      |> Graph.add_node(:slow_b, hanging_node(parent), timeout: 60_000)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:slow_a, Graph.end_node())
      |> Graph.add_edge(:slow_b, Graph.end_node())
      |> Graph.compile!(step_timeout: 10)

    assert {:error,
            %Error{
              type: :step_timeout,
              message: "graph step timed out",
              details: %{timeout: 10}
            }} = Compiled.invoke(graph, %{})

    assert_started_nodes_cancelled()
  end

  test "run timeout caps the whole invocation" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :slow_a},
          %Send{node: :slow_b}
        ]
      end)
      |> Graph.add_node(:slow_a, hanging_node(parent), timeout: 60_000)
      |> Graph.add_node(:slow_b, hanging_node(parent), timeout: 60_000)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:slow_a, Graph.end_node())
      |> Graph.add_edge(:slow_b, Graph.end_node())
      |> Graph.compile!(step_timeout: 1_000, run_timeout: 10)

    assert {:error,
            %Error{
              type: :run_timeout,
              message: "graph run timed out",
              details: %{timeout: 10}
            }} = Compiled.invoke(graph, %{})

    assert_started_nodes_cancelled()
  end

  test "recursion limit caps executed supersteps" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:loop, fn state ->
        count = Map.get(state, :count, 0)
        send(parent, {:loop_step, count})
        %Command{update: %{count: count + 1}, goto: :loop}
      end)
      |> Graph.add_edge(Graph.start(), :loop)
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :recursion_limit,
              message: "graph recursion limit reached",
              details: %{limit: 2, step: 2}
            }} = Compiled.invoke(graph, %{}, recursion_limit: 2)

    assert_receive {:loop_step, 0}
    assert_receive {:loop_step, 1}
    refute_receive {:loop_step, 2}, 50
  end

  test "persists state by thread, exposes history, and supports manual state updates" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:increment, fn state -> %{count: Map.get(state, :count, 0) + 1} end)
      |> Graph.add_edge(Graph.start(), :increment)
      |> Graph.add_edge(:increment, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "counter"}}

    assert {:ok, %{count: 1}} = Compiled.invoke(graph, %{}, config: config)
    assert {:ok, %{count: 2}} = Compiled.invoke(graph, %{}, config: config)

    assert {:ok, snapshot} = Compiled.get_state(graph, config)
    assert snapshot.values.count == 2
    assert is_binary(snapshot.created_at)
    assert snapshot.next == []
    assert snapshot.interrupts == []
    assert snapshot.parent_config["configurable"]["checkpoint_id"]
    assert Enum.map(snapshot.tasks, & &1.kind) == [:start, :finish]
    assert Enum.map(snapshot.tasks, & &1.node) == ["increment", "increment"]
    assert Enum.map(snapshot.tasks, & &1.path) == ["increment", "increment"]
    assert snapshot.channel_versions == %{"count" => 2}
    assert snapshot.versions_seen["increment"] == %{"count" => 1}
    assert snapshot.updated_channels == ["count"]
    assert [start_task, finish_task] = snapshot.tasks
    assert is_binary(start_task.id)
    assert start_task.id == finish_task.id

    history = Compiled.get_state_history(graph, config)
    assert Enum.any?(history, &(&1.values.count == 1))
    assert Enum.any?(history, &(&1.values.count == 2))

    assert Enum.any?(
             history,
             &(&1.metadata["source"] == "input" and &1.next == ["increment"] and
                 &1.updated_channels == [])
           )

    assert {:ok, updated_config} = Compiled.update_state(graph, config, %{count: 10})
    assert updated_config["configurable"]["checkpoint_id"]

    assert {:ok, updated_snapshot} = Compiled.get_state(graph, updated_config)

    assert updated_snapshot.parent_config["configurable"]["checkpoint_id"] ==
             snapshot.config["configurable"]["checkpoint_id"]

    assert updated_snapshot.channel_versions == %{"count" => 3}
    assert updated_snapshot.updated_channels == ["count"]

    assert {:ok, %{count: 11}} = Compiled.invoke(graph, %{}, config: config)
  end

  test "manual state updates preserve explicit nil values" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:start, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :start)
      |> Graph.add_edge(:start, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "nil-state-update"}}

    assert {:ok, %{value: "kept"}} = Compiled.invoke(graph, %{value: "kept"}, config: config)
    assert {:ok, update_config} = Compiled.update_state(graph, config, %{value: nil})
    assert {:ok, snapshot} = Compiled.get_state(graph, update_config)
    assert Map.has_key?(snapshot.values, :value)
    assert snapshot.values.value == nil
  end

  test "bulk state updates use channel-backed superstep merge semantics" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_reducer(:items, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:noop, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :noop)
      |> Graph.add_edge(:noop, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "bulk"}}

    assert {:ok, final_config} =
             Compiled.bulk_update_state(graph, config, [
               [%{items: [:a]}, %{items: [:b]}],
               [%{answer: 42}]
             ])

    assert {:ok, snapshot} = Compiled.get_state(graph, final_config)
    assert snapshot.values.items == [:a, :b]
    assert snapshot.values.answer == 42
    assert snapshot.metadata["source"] == "update"
    assert snapshot.channel_versions == %{"answer" => 1, "items" => 1}
    assert snapshot.updated_channels == ["answer"]

    assert {:error, %Error{type: :invalid_update}} =
             Compiled.bulk_update_state(graph, final_config, [
               [%{answer: 1}, %{answer: 2}]
             ])
  end

  describe "bulk_update_state schedules what comes next" do
    test "an update as a node runs the nodes after it, as update_state does" do
      graph = assistant_graph(CheckpointETS.new())
      config = %{"configurable" => %{"thread_id" => "bulk-as-node"}}

      assert {:ok, _state} = Compiled.invoke(graph, %{log: ["hi"]}, config: config)
      assert {:ok, _config} = Compiled.bulk_update_state(graph, config, [[%{log: ["u"]}]], as_node: :model)
      assert {:ok, %{next: ["assistant"]}} = Compiled.get_state(graph, config)

      assert {:ok, %{log: ["hi", "model", "assistant", "u", "assistant"]}} =
               Compiled.invoke(graph, %{}, config: config)
    end

    test "the last superstep routes, and a task waiting at a breakpoint stays" do
      saver = CheckpointETS.new()
      graph = assistant_graph(saver, interrupt_before: [:assistant])
      config = %{"configurable" => %{"thread_id" => "bulk-breakpoint"}}

      assert {:interrupted, %{nodes: ["assistant"]}} = Compiled.invoke(graph, %{log: ["hi"]}, config: config)
      assert {:ok, _config} = Compiled.bulk_update_state(graph, config, [[%{log: ["u"]}]])
      assert {:ok, %{next: ["assistant"]}} = Compiled.get_state(graph, config)

      assert {:ok, _config} =
               Compiled.bulk_update_state(graph, config, [[%{log: ["v"]}], [%{log: ["w"]}]], as_node: :model)

      assert {:ok, %{next: ["assistant"]}} = Compiled.get_state(graph, config)
      assert {:ok, %{log: ["hi", "model", "u", "v", "w", "assistant"]}} = Compiled.resume(graph, nil, config: config)
    end
  end

  test "update_state infers continuation node while interrupted" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:prepare, fn _state -> %{prepared: true} end)
      |> Graph.add_node(:finish, fn state -> %{finished: state.prepared and state.reviewed} end)
      |> Graph.add_edge(:prepare, :finish)
      |> Graph.add_edge(Graph.start(), :prepare)
      |> Graph.add_edge(:finish, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer, interrupt_after: [:prepare])

    config = %{"configurable" => %{"thread_id" => "update-infer"}}

    assert {:interrupted, %{timing: :after, nodes: ["prepare"]}} =
             Compiled.invoke(graph, %{}, config: config)

    assert {:ok, update_config} = Compiled.update_state(graph, config, %{reviewed: true})
    assert {:ok, snapshot} = Compiled.get_state(graph, update_config)
    assert snapshot.next == ["finish"]

    assert {:ok, %{finished: true}} = Compiled.invoke(graph, %{}, config: update_config)
  end

  test "update_state routes guarded edges from the manual node update" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:route, fn state -> %{route: state.route} end)
      |> Graph.add_node(:left, fn _state -> %{path: :left} end)
      |> Graph.add_node(:right, fn _state -> %{path: :right} end)
      |> Graph.add_edge(Graph.start(), :route)
      |> Graph.add_edge(:route, :left, when: %{route: :left})
      |> Graph.add_edge(:route, :right, when: %{route: :right})
      |> Graph.add_edge(:left, Graph.end_node())
      |> Graph.add_edge(:right, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "manual-update-guarded-route"}}

    assert {:ok, %{path: :left}} = Compiled.invoke(graph, %{route: :left}, config: config)

    before_route =
      graph
      |> Compiled.get_state_history(config)
      |> Enum.find(&(&1.next == ["route"]))

    assert {:ok, update_config} =
             Compiled.update_state(graph, before_route.config, %{route: :right}, as_node: :route)

    assert {:ok, snapshot} = Compiled.get_state(graph, update_config)
    assert snapshot.next == ["right"]
    assert snapshot.next_tasks == [%{"node" => "right"}]

    assert {:ok, %{path: :right, route: :right}} =
             Compiled.invoke(graph, %{}, config: update_config)
  end

  test "update_state infers guarded-edge source nodes" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:route, fn state -> %{route: state.route} end)
      |> Graph.add_node(:left, fn _state -> %{path: :left} end)
      |> Graph.add_node(:right, fn _state -> %{path: :right} end)
      |> Graph.add_edge(Graph.start(), :route)
      |> Graph.add_edge(:route, :left, when: %{route: :left})
      |> Graph.add_edge(:route, :right, when: %{route: :right})
      |> Graph.add_edge(:left, Graph.end_node())
      |> Graph.add_edge(:right, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer, interrupt_after: [:route])

    config = %{"configurable" => %{"thread_id" => "manual-update-infer-guarded-route"}}

    assert {:interrupted, %{timing: :after, nodes: ["route"]}} =
             Compiled.invoke(graph, %{route: :left}, config: config)

    assert {:ok, update_config} = Compiled.update_state(graph, config, %{route: :right})
    assert {:ok, snapshot} = Compiled.get_state(graph, update_config)
    assert snapshot.next == ["right"]

    assert {:ok, %{path: :right, route: :right}} =
             Compiled.invoke(graph, %{}, config: update_config)
  end

  test "update_state routes conditional edges from the manual node update" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:route, fn state -> %{route: state.route} end)
      |> Graph.add_node(:left, fn _state -> %{path: :left} end)
      |> Graph.add_node(:right, fn _state -> %{path: :right} end)
      |> Graph.add_edge(Graph.start(), :route)
      |> BeamWeaver.Graph.StateGraph.put_branch_routes(
        :route,
        fn state -> state.route end,
        %{left: :left, right: :right}
      )
      |> Graph.add_edge(:left, Graph.end_node())
      |> Graph.add_edge(:right, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "manual-update-conditional-route"}}

    assert {:ok, %{path: :left}} = Compiled.invoke(graph, %{route: :left}, config: config)

    before_route =
      graph
      |> Compiled.get_state_history(config)
      |> Enum.find(&(&1.next == ["route"]))

    assert {:ok, update_config} =
             Compiled.update_state(graph, before_route.config, %{route: :right}, as_node: :route)

    assert {:ok, snapshot} = Compiled.get_state(graph, update_config)
    assert snapshot.next == ["right"]
    assert snapshot.next_tasks == [%{"node" => "right"}]

    assert {:ok, %{path: :right, route: :right}} =
             Compiled.invoke(graph, %{}, config: update_config)
  end

  test "update_state returns the error of a when: function that raises" do
    graph =
      Graph.new()
      |> Graph.add_node(:route, fn _state -> %{route: :left} end)
      |> Graph.add_node(:left, fn _state -> %{path: :left} end)
      |> Graph.add_edge(Graph.start(), :route)
      |> Graph.add_edge(:route, :left, when: fn update -> if update[:boom], do: raise("no route"), else: true end)
      |> Graph.add_edge(:left, Graph.end_node())
      |> Graph.compile!(checkpointer: CheckpointETS.new())

    config = %{"configurable" => %{"thread_id" => "update-raising-route"}}

    assert {:ok, %{path: :left}} = Compiled.invoke(graph, %{}, config: config)

    assert {:error, %Error{type: :edge_exception, message: "no route", details: %{node: "route"}}} =
             Compiled.update_state(graph, config, %{boom: true}, as_node: :route)
  end

  test "a route to a node the graph doesn't have fails the run" do
    for output <- [%Command{goto: :refunds}, %Send{node: :refunds, update: %{}}] do
      graph =
        Graph.new()
        |> Graph.add_node(:classify, fn _state -> output end)
        |> Graph.add_edge(Graph.start(), :classify)
        |> Graph.compile!()

      assert {:error,
              %Error{type: :invalid_graph, message: "graph references a missing node", details: %{node: "refunds"}}} =
               Compiled.invoke(graph, %{})
    end
  end

  test "update_state can preserve interrupt pending writes and resume" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:ask, fn state ->
        answer = Graph.interrupt(%{question: "continue?", note: Map.get(state, :note)})
        %{answer: answer, note: Map.get(state, :note)}
      end)
      |> Graph.add_edge(Graph.start(), :ask)
      |> Graph.add_edge(:ask, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "update-resume"}}

    assert {:interrupted, %{value: %{question: "continue?", note: nil}}} =
             Compiled.invoke(graph, %{}, config: config)

    assert {:ok, %{answer: "yes", note: "reviewed"}} =
             Compiled.update_state(graph, config, %{note: "reviewed"}, resume: "yes")
  end

  test "copied interrupted thread re-triggers interrupt on the sibling branch" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:ask, fn _state ->
        answer = Graph.interrupt(%{question: "approve?"})
        %{answer: answer}
      end)
      |> Graph.add_edge(Graph.start(), :ask)
      |> Graph.add_edge(:ask, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    source_config = %{"configurable" => %{"thread_id" => "copy-interrupt-source"}}
    target_config = %{"configurable" => %{"thread_id" => "copy-interrupt-target"}}

    assert {:interrupted, source_interrupt} = Compiled.invoke(graph, %{}, config: source_config)

    assert :ok =
             BeamWeaver.Checkpoint.copy_thread(
               checkpointer,
               "copy-interrupt-source",
               "copy-interrupt-target"
             )

    assert {:interrupted, target_interrupt} = Compiled.invoke(graph, %{}, config: target_config)

    assert target_interrupt.value == source_interrupt.value
    assert target_interrupt.id == source_interrupt.id

    assert {:ok, %{answer: "source yes"}} =
             Compiled.resume(graph, %{source_interrupt.id => "source yes"}, config: source_config)

    assert {:ok, %{answer: "target yes"}} =
             Compiled.resume(graph, %{target_interrupt.id => "target yes"}, config: target_config)
  end

  test "failed supersteps persist successful task writes as pending writes" do
    parent = self()
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :ok, update: %{value: "pending"}},
          %Send{node: :fail, update: %{attempt: 1}}
        ]
      end)
      |> Graph.add_node(:ok, fn state ->
        send(parent, :ok_ran)
        %{kept: state[:value]}
      end)
      |> Graph.add_node(:fail, fn state ->
        if state[:retry_ok],
          do: %{observed: "#{state[:kept]}:#{state[:attempt]}"},
          else: {:error, Error.new(:node_failed, "boom")}
      end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:ok, Graph.end_node())
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "pending-writes"}}

    assert {:error, %Error{type: :node_failed}} = Compiled.invoke(graph, %{}, config: config)
    assert_receive :ok_ran
    assert {:ok, snapshot} = Compiled.get_state(graph, config)

    assert snapshot.metadata["source"] == "loop"
    assert snapshot.values == %{kept: "pending"}
    assert snapshot.next == ["fail"]
    assert snapshot.next_tasks == [%{"node" => "fail", "update" => %{attempt: 1}}]

    assert {:ok, raw_snapshot} = Compiled.get_state(graph, snapshot.config)
    assert raw_snapshot.values == %{}

    assert raw_snapshot.next_tasks == [
             %{"node" => "ok", "update" => %{value: "pending"}},
             %{"node" => "fail", "update" => %{attempt: 1}}
           ]

    assert [{task_id, "kept", "pending"}] = data_writes(snapshot.pending_writes)
    assert is_binary(task_id)
    assert [{^task_id, "kept", task_path}] = data_write_paths(snapshot.pending_write_paths)

    assert BeamWeaver.JSON.decode!(task_path) == %{
             "node" => "ok",
             "update" => %{"value" => "pending"}
           }

    assert {:ok, %{observed: "pending:1"}} =
             Compiled.invoke(graph, %{retry_ok: true}, config: config)

    refute_receive :ok_ran, 50

    assert {:ok, restored} = Compiled.get_state(graph, config)
    assert restored.values.kept == "pending"
    assert restored.values.observed == "pending:1"
    assert restored.pending_writes == []
    assert restored.pending_write_paths == []
    assert restored.channel_versions["kept"] == 1
  end

  test "send timeout is checkpointed and replayed with pending writes" do
    parent = self()
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :ok, update: %{value: "pending"}, timeout: 250},
          %Send{node: :fail, update: %{attempt: 1}}
        ]
      end)
      |> Graph.add_node(:ok, fn state ->
        send(parent, :timeout_ok_ran)
        %{kept: state[:value]}
      end)
      |> Graph.add_node(:fail, fn state ->
        if state[:retry_ok],
          do: %{observed: "#{state[:kept]}:#{state[:attempt]}"},
          else: {:error, Error.new(:node_failed, "boom")}
      end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:ok, Graph.end_node())
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "pending-writes-send-timeout"}}

    assert {:error, %Error{type: :node_failed}} = Compiled.invoke(graph, %{}, config: config)
    assert_receive :timeout_ok_ran

    assert {:ok, snapshot} = Compiled.get_state(graph, config)

    assert snapshot.next_tasks == [%{"node" => "fail", "update" => %{attempt: 1}}]

    assert {:ok, raw_snapshot} = Compiled.get_state(graph, snapshot.config)

    assert raw_snapshot.next_tasks == [
             %{"node" => "ok", "timeout" => 250, "update" => %{value: "pending"}},
             %{"node" => "fail", "update" => %{attempt: 1}}
           ]

    assert [{task_id, "kept", "pending"}] = data_writes(snapshot.pending_writes)
    assert [{^task_id, "kept", task_path}] = data_write_paths(snapshot.pending_write_paths)

    assert BeamWeaver.JSON.decode!(task_path) == %{
             "node" => "ok",
             "timeout" => 250,
             "update" => %{"value" => "pending"}
           }

    assert {:ok, %{observed: "pending:1"}} =
             Compiled.invoke(graph, %{retry_ok: true}, config: config)

    refute_receive :timeout_ok_ran, 50
  end

  test "a failing node waits for its siblings and persists their writes" do
    parent = self()
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :fail},
          %Send{node: :slow_ok}
        ]
      end)
      |> Graph.add_node(:fail, fn state ->
        if state[:retry_ok],
          do: %{observed: state[:kept]},
          else: {:error, Error.new(:node_failed, "boom")}
      end)
      |> Graph.add_node(:slow_ok, fn _state ->
        Process.sleep(20)
        send(parent, :slow_ok_finished)
        %{kept: "from-proceed"}
      end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.add_edge(:slow_ok, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "proceed-pending-writes"}}

    assert {:error, %Error{type: :node_failed}} = Compiled.invoke(graph, %{}, config: config)
    assert_received :slow_ok_finished

    assert {:ok, snapshot} = Compiled.get_state(graph, config)
    assert [{task_id, "kept", "from-proceed"}] = data_writes(snapshot.pending_writes)
    assert [{^task_id, "kept", task_path}] = data_write_paths(snapshot.pending_write_paths)
    assert BeamWeaver.JSON.decode!(task_path) == %{"node" => "slow_ok", "update" => %{}}

    assert {:ok, %{observed: "from-proceed"}} =
             Compiled.invoke(graph, %{retry_ok: true}, config: config)

    refute_receive :slow_ok_finished, 50
  end

  # A node that reports its pid and then blocks until it is killed.
  defp hanging_node(parent) do
    fn _state ->
      send(parent, {:node_started, self()})
      Process.sleep(:infinity)
    end
  end

  # Every node that reported `{:node_started, pid}` must be torn down with the
  # failed step. The nodes never return, so a :DOWN can only mean cancellation.
  defp assert_started_nodes_cancelled do
    receive do
      {:node_started, pid} ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
        assert_started_nodes_cancelled()
    after
      0 -> :ok
    end
  end

  defp data_writes(writes), do: Enum.reject(writes, &control_write?/1)
  defp data_write_paths(paths), do: Enum.reject(paths, &control_write?/1)

  defp control_write?({_task_id, "__error__", _value}), do: true
  defp control_write?({_task_id, "__interrupt__", _value}), do: true
  defp control_write?({_task_id, "__route__", _value}), do: true
  defp control_write?(_write), do: false

  test "stream_events emits typed graph updates and task metadata" do
    refute function_exported?(Compiled, :stream, 3)
    refute function_exported?(Compiled, :async_stream, 3)

    graph =
      Graph.new()
      |> Graph.add_node(:answer, fn _state -> %{answer: 42} end)
      |> Graph.add_edge(Graph.start(), :answer)
      |> Graph.add_edge(:answer, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    assert Enum.any?(
             events,
             &match?(%Envelope{event: %Events.Task{kind: :start, node: "answer"}}, &1)
           )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{event: %Events.GraphUpdate{update: %{"answer" => %{answer: 42}}}},
               &1
             )
           )

    assert %Envelope{event: %Events.Debug{payload: %{type: :producer_stop}}} = List.last(events)
  end

  test "streams custom events written from node runtime" do
    graph =
      Graph.new()
      |> Graph.add_node(:work, fn _state, runtime ->
        runtime.stream_writer.("first")
        runtime.stream_writer.(%{step: 2})
        %{answer: 42}
      end)
      |> Graph.add_edge(Graph.start(), :work)
      |> Graph.add_edge(:work, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    assert Enum.any?(events, &match?(%Envelope{event: %Events.Custom{payload: "first"}}, &1))
    assert Enum.any?(events, &match?(%Envelope{event: %Events.Custom{payload: %{step: 2}}}, &1))

    assert Enum.any?(
             events,
             &match?(
               %Envelope{event: %Events.GraphUpdate{update: %{"work" => %{answer: 42}}}},
               &1
             )
           )
  end

  test "streams message updates from graph nodes" do
    graph =
      Graph.new()
      |> Graph.add_node(:model, fn _state ->
        [
          Message.assistant("first"),
          Message.assistant("second")
        ]
      end)
      |> Graph.add_edge(Graph.start(), :model)
      |> Graph.add_edge(:model, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    assert events
           |> Enum.flat_map(fn
             %Envelope{event: %Events.Message{message: message}} -> [message.content]
             _event -> []
           end)
           |> Enum.take(2) == ["first", "second"]

    assert Enum.any?(
             events,
             &match?(%Envelope{event: %Events.Message{message: %Message{content: "first"}}}, &1)
           )

    assert Enum.any?(
             events,
             &match?(%Envelope{event: %Events.Message{message: %Message{content: "second"}}}, &1)
           )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphUpdate{update: %{"model" => %{messages: [_first, _second]}}}
               },
               &1
             )
           )
  end

  test "stream_events returns typed envelopes with graph metadata" do
    graph =
      Graph.new(name: "TypedStreamGraph")
      |> Graph.add_node(:answer, fn _state -> %{answer: 42} end)
      |> Graph.add_edge(Graph.start(), :answer)
      |> Graph.add_edge(:answer, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphUpdate{update: %{"answer" => %{answer: 42}}},
                 graph: "TypedStreamGraph",
                 step: _,
                 namespace: []
               },
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphValue{value: %{answer: 42}},
                 graph: "TypedStreamGraph",
                 namespace: []
               },
               &1
             )
           )
  end

  test "stream_events wraps typed graph events with lifecycle metadata" do
    graph =
      Graph.new(name: "LifecycleGraph")
      |> Graph.add_node(:answer, fn _state -> %{answer: 42} end)
      |> Graph.add_edge(Graph.start(), :answer)
      |> Graph.add_edge(:answer, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} =
             Compiled.stream_events(graph, %{}, run_id: "run-1", metadata: %{source: :test})

    assert %Envelope{
             event: %Events.Debug{payload: %{type: :producer_start}},
             graph: "LifecycleGraph",
             run_id: "run-1",
             namespace: []
           } = hd(events)

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphUpdate{update: %{"answer" => %{answer: 42}}},
                 graph: "LifecycleGraph"
               },
               &1
             )
           )

    assert %Envelope{
             event: %Events.Debug{payload: %{type: :producer_stop}},
             graph: "LifecycleGraph",
             run_id: "run-1",
             namespace: []
           } = List.last(events)

    assert Enum.all?(events, &match?(%Envelope{run_id: "run-1", metadata: %{source: :test}}, &1))
  end

  test "graph execution generates UUIDv7 run IDs by default" do
    graph =
      Graph.new(name: "GeneratedRunIdGraph")
      |> Graph.add_node(:answer, fn _state -> %{answer: 42} end)
      |> Graph.add_edge(Graph.start(), :answer)
      |> Graph.add_edge(:answer, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    run_id =
      events
      |> Enum.map(& &1.run_id)
      |> Enum.find(&is_binary/1)

    assert run_id =~ @uuidv7_regex
  end

  test "subgraph stream events keep child namespace metadata" do
    child =
      Graph.new(name: "ChildGraph")
      |> Graph.add_node(:child_node, fn _state -> %{child: true} end)
      |> Graph.add_edge(Graph.start(), :child_node)
      |> Graph.add_edge(:child_node, Graph.end_node())
      |> Graph.compile!()

    parent =
      Graph.new(name: "ParentGraph")
      |> Graph.add_node(:child, child)
      |> Graph.add_edge(Graph.start(), :child)
      |> Graph.add_edge(:child, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(parent, %{})

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphUpdate{update: %{"child_node" => %{child: true}}},
                 graph: "ChildGraph",
                 namespace: ["child"]
               },
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphUpdate{update: %{"child" => %{child: true}}},
                 graph: "ParentGraph",
                 namespace: []
               },
               &1
             )
           )
  end

  test "runtime push_message emits typed message events in messages and events streams" do
    pushed = Message.assistant("streamed", id: "msg-1")

    graph =
      Graph.new()
      |> Graph.add_node(:model, fn _state, runtime ->
        assert {:ok, ^pushed} = BeamWeaver.Graph.Runtime.push_message(runtime, pushed)
        %{messages: [pushed]}
      end)
      |> Graph.add_edge(Graph.start(), :model)
      |> Graph.add_edge(:model, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, typed_events} = Compiled.stream_events(graph, %{})

    assert Enum.any?(
             typed_events,
             &match?(
               %Envelope{
                 event: %Events.Message{message: %Message{id: "msg-1", content: "streamed"}}
               },
               &1
             )
           )

    assert Enum.any?(
             typed_events,
             &match?(
               %Envelope{event: %Events.Message{message: %Message{id: "msg-1"}}},
               &1
             )
           )
  end

  test "live stream emits node events before the graph run completes" do
    parent = self()

    graph =
      Graph.new(name: "LiveGraph")
      |> Graph.add_node(:slow, fn _state, runtime ->
        runtime.stream_writer.(Stream.event(:custom, :before_release))
        send(parent, {:node_emitted, self()})

        receive do
          :release -> %{answer: 42}
        end
      end)
      |> Graph.add_edge(Graph.start(), :slow)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, stream} = Compiled.stream_events(graph, %{}, live: true)

    consumer =
      Task.async(fn ->
        Enum.each(stream, fn
          %Envelope{event: %Events.Custom{payload: :before_release}} ->
            send(parent, :consumer_saw_custom)

          _event ->
            :ok
        end)
      end)

    # The node cannot finish until it is released, so the consumer seeing its
    # event first proves the stream delivered it while the run was still live.
    assert_receive {:node_emitted, node}
    assert_receive :consumer_saw_custom
    send(node, :release)
    assert :ok = Task.await(consumer, 5_000)
  end

  test "halting a live graph stream cancels running node tasks" do
    graph =
      Graph.new(name: "CancelledLiveGraph")
      |> Graph.add_node(:slow, fn _state, runtime ->
        runtime.stream_writer.(Stream.event(:custom, {:node_pid, self()}))
        Process.sleep(:infinity)
        %{never: true}
      end)
      |> Graph.add_edge(Graph.start(), :slow)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, stream} = Compiled.stream_events(graph, %{}, live: true)

    %Envelope{event: %Events.Custom{payload: {:node_pid, node_pid}}} =
      Enum.find(stream, &match?(%Envelope{event: %Events.Custom{payload: {:node_pid, _}}}, &1))

    ref = Process.monitor(node_pid)
    assert_receive {:DOWN, ^ref, :process, ^node_pid, _reason}
  end

  test "live graph streams emit typed interrupt debug events" do
    graph =
      Graph.new(name: "LiveInterruptGraph")
      |> Graph.add_node(:approval, fn _state -> %{approved: true} end)
      |> Graph.add_edge(Graph.start(), :approval)
      |> Graph.add_edge(:approval, Graph.end_node())
      |> Graph.compile!(interrupt_before: [:approval])

    assert {:ok, stream} =
             Compiled.stream_events(graph, %{request: "delete"}, live: true)

    assert %Envelope{
             event: %Events.Debug{
               payload: %{type: :interrupt, interrupt: %{timing: :before, nodes: ["approval"]}}
             },
             graph: "LiveInterruptGraph",
             namespace: []
           } =
             Enum.find(stream, fn
               %Envelope{event: %Events.Debug{payload: %{type: :interrupt}}} -> true
               _event -> false
             end)
  end

  test "stream_events returns interrupted status and lifecycle envelopes" do
    graph =
      Graph.new(name: "InterruptedStreamGraph")
      |> Graph.add_node(:approval, fn _state -> %{approved: true} end)
      |> Graph.add_edge(Graph.start(), :approval)
      |> Graph.add_edge(:approval, Graph.end_node())
      |> Graph.compile!(interrupt_before: [:approval])

    assert {:interrupted, interrupt} =
             Compiled.stream_events(graph, %{request: "delete"},
               run_id: "run-interrupted",
               metadata: %{source: :test}
             )

    assert %{timing: :before, nodes: ["approval"], events: events} = interrupt

    assert [
             %Envelope{
               event: %Events.Debug{payload: %{type: :producer_start}},
               graph: "InterruptedStreamGraph",
               run_id: "run-interrupted",
               metadata: %{source: :test}
             },
             %Envelope{
               event: %Events.Debug{payload: %{type: :interrupt, interrupt: %{nodes: ["approval"]}}},
               run_id: "run-interrupted"
             },
             %Envelope{event: %Events.Debug{payload: %{type: :producer_stop}}}
           ] = events
  end

  test "interrupts before configured nodes and returns resumable state" do
    graph =
      Graph.new()
      |> Graph.add_node(:approval, fn _state -> %{approved: true} end)
      |> Graph.add_edge(Graph.start(), :approval)
      |> Graph.add_edge(:approval, Graph.end_node())
      |> Graph.compile!(interrupt_before: [:approval])

    assert {:interrupted, interrupt} = Compiled.invoke(graph, %{request: "delete"})
    assert interrupt.timing == :before
    assert interrupt.nodes == ["approval"]
    assert interrupt.state == %{request: "delete"}
  end

  defp assistant_graph(saver, opts \\ []) do
    Graph.new()
    |> Graph.add_reducer(:log, &(&1 ++ &2))
    |> Graph.add_node(:model, fn _state -> %{log: ["model"]} end)
    |> Graph.add_node(:assistant, fn _state -> %{log: ["assistant"]} end)
    |> Graph.add_edge(Graph.start(), :model)
    |> Graph.add_edge(:model, :assistant)
    |> Graph.add_edge(:assistant, Graph.end_node())
    |> Graph.compile!([checkpointer: saver] ++ opts)
  end
end
