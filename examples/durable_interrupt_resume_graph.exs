alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "example-interrupt"}}

graph =
  Graph.new()
  |> Graph.add_node(:review, fn _state ->
    decision = Graph.interrupt(%{question: "approve?"})
    %{decision: decision}
  end)
  |> Graph.add_edge(Graph.start(), :review)
  |> Graph.add_edge(:review, Graph.end_node())
  |> Graph.compile!(checkpointer: checkpointer)

{:interrupted, interrupt} = Compiled.invoke(graph, %{}, config: config)
IO.puts(interrupt.value.question)

{:ok, %{decision: "approved"}} = Compiled.resume(graph, "approved", config: config)
IO.puts("approved")
