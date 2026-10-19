defmodule BeamWeaver.Graph.NodeCacheTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled

  defmodule RecordingCache do
    # An ETS cache that tells the test process about every write.
    defstruct [:inner, :test]

    def new, do: %__MODULE__{inner: BeamWeaver.Cache.ETS.new(), test: self()}

    def lookup(cache, namespace, key, opts), do: BeamWeaver.Cache.ETS.lookup(cache.inner, namespace, key, opts)

    def put(cache, namespace, key, value, opts) do
      send(cache.test, {:cache_put, opts})
      BeamWeaver.Cache.ETS.put(cache.inner, namespace, key, value, opts)
    end

    def delete(cache, namespace, key, opts), do: BeamWeaver.Cache.ETS.delete(cache.inner, namespace, key, opts)
    def clear(cache, namespace, opts), do: BeamWeaver.Cache.ETS.clear(cache.inner, namespace, opts)
  end

  defp single_node_graph(fun, opts, compile_opts) do
    Graph.new(name: "orders")
    |> Graph.add_node(:lookup, fun, opts)
    |> Graph.add_edge(Graph.start(), :lookup)
    |> Graph.add_edge(:lookup, Graph.end_node())
    |> Graph.compile!(compile_opts)
  end

  defp thread, do: %{"configurable" => %{"thread_id" => "t#{System.unique_integer([:positive])}"}}

  test "a cache hit leaves the entry as it is, so its ttl counts from the run that saved it" do
    test = self()

    lookup = fn %{order: order} ->
      send(test, :lookup_ran)
      %{status: "shipped #{order}"}
    end

    graph = single_node_graph(lookup, [cache: [ttl: :timer.hours(1)]], cache: RecordingCache.new())

    assert {:ok, %{status: "shipped A-1"}} = Compiled.invoke(graph, %{order: "A-1"})
    assert_received :lookup_ran
    assert_received {:cache_put, opts}
    assert opts[:ttl] == :timer.hours(1)

    assert {:ok, %{status: "shipped A-1"}} = Compiled.invoke(graph, %{order: "A-1"})
    refute_received :lookup_ran
    refute_received {:cache_put, _opts}
  end

  test "an error handler's fallback isn't cached, so the next run calls the node again" do
    test = self()

    failing = fn _state ->
      send(test, :lookup_ran)
      {:error, "order service unavailable"}
    end

    handler = fn %Error{}, _state, _runtime -> %{status: "unknown"} end
    graph = single_node_graph(failing, [cache: true, error_handler: handler], cache: RecordingCache.new())

    for _run <- 1..2 do
      assert {:ok, %{status: "unknown"}} = Compiled.invoke(graph, %{order: "A-1"})
      assert_received :lookup_ran
    end

    refute_received {:cache_put, _opts}
  end

  test "an error handler that runs when a failed step is resumed doesn't cache its fallback" do
    test = self()
    checkpointer = CheckpointETS.new()
    cache = RecordingCache.new()

    lookup = fn _state ->
      send(test, :lookup_ran)
      {:error, "order service unavailable"}
    end

    config = thread()
    without_handler = single_node_graph(lookup, [cache: true], cache: cache, checkpointer: checkpointer)
    assert {:error, %Error{}} = Compiled.invoke(without_handler, %{order: "A-1"}, config: config)
    assert_received :lookup_ran

    handler = fn %Error{}, _state, _runtime -> %{status: "unknown"} end

    with_handler =
      single_node_graph(lookup, [cache: true, error_handler: handler], cache: cache, checkpointer: checkpointer)

    assert {:ok, %{status: "unknown"}} = Compiled.invoke(with_handler, %{}, config: config)
    refute_received :lookup_ran
    refute_received {:cache_put, _opts}

    assert {:ok, %{status: "unknown"}} = Compiled.invoke(with_handler, %{order: "A-1"}, config: thread())
    assert_received :lookup_ran
  end
end
