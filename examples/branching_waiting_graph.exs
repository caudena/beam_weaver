alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled
alias BeamWeaver.Graph.Command
alias BeamWeaver.Graph.Send

graph =
  Graph.new()
  |> Graph.add_reducer(:items, fn existing, update -> existing ++ List.wrap(update) end)
  |> Graph.add_node(:route, fn _state -> %Command{goto: :fanout} end)
  |> Graph.add_node(:fanout, fn _state ->
    [%Send{node: :worker, update: %{item: "a"}}, %Send{node: :worker, update: %{item: "b"}}]
  end)
  |> Graph.add_node(:worker, fn state -> %{items: [state.item]} end)
  |> Graph.add_edge(Graph.start(), :route)
  |> Graph.add_edge(:worker, Graph.end_node())
  |> Graph.compile!()

{:ok, %{items: items}} = Compiled.invoke(graph, %{items: []})
IO.puts(items |> Enum.sort() |> Enum.join(","))
