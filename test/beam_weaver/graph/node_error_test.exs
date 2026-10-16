defmodule BeamWeaver.Graph.NodeErrorTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled

  defp single_node_graph(fun, opts \\ []) do
    Graph.new()
    |> Graph.add_node(:lookup, fun, opts)
    |> Graph.add_edge(Graph.start(), :lookup)
    |> Graph.add_edge(:lookup, Graph.end_node())
    |> Graph.compile!()
  end

  test "a node that returns {:error, reason} fails with the reason as the message" do
    graph = single_node_graph(fn _state -> {:error, "order service unavailable"} end)

    assert {:error, %Error{type: :node_error, message: "order service unavailable", details: %{node: "lookup"}}} =
             Compiled.invoke(graph, %{})
  end

  test "a reason that is not a string is kept in the details" do
    graph = single_node_graph(fn _state -> {:error, :timeout} end)

    assert {:error, %Error{type: :node_error, message: "node returned an error", details: %{reason: ":timeout"}}} =
             Compiled.invoke(graph, %{})
  end

  test "the node is retried and its error handler runs" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    flaky = fn _state ->
      if Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) < 3,
        do: {:error, "order service unavailable"},
        else: %{status: "shipped"}
    end

    graph = single_node_graph(flaky, retry: [max_attempts: 3, initial_delay: 1])
    assert {:ok, %{status: "shipped"}} = Compiled.invoke(graph, %{})

    failing = fn _state -> {:error, "order service unavailable"} end
    handler = fn %Error{message: message}, _state, _runtime -> %{status: "unknown (#{message})"} end
    graph = single_node_graph(failing, error_handler: handler)

    assert {:ok, %{status: "unknown (order service unavailable)"}} = Compiled.invoke(graph, %{})
  end

  test "an error handler that returns {:error, reason} fails the node" do
    handler = fn _error, _state, _runtime -> {:error, "still down"} end
    graph = single_node_graph(fn _state -> {:error, "down"} end, error_handler: handler)

    assert {:error, %Error{type: :node_error, message: "still down"}} = Compiled.invoke(graph, %{})
  end
end
