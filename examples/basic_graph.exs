alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

graph =
  Graph.new()
  |> Graph.add_node(:greet, fn state -> %{answer: "hello #{state.name}"} end)
  |> Graph.add_edge(Graph.start(), :greet)
  |> Graph.add_edge(:greet, Graph.end_node())
  |> Graph.compile!()

{:ok, %{answer: answer}} = Compiled.invoke(graph, %{name: "BeamWeaver"})
IO.puts(answer)
