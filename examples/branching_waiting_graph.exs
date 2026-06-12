alias BeamWeaver.Graph.Command
alias BeamWeaver.Graph.Send

defmodule BeamWeaver.Examples.BranchingWaitingGraph do
  use BeamWeaver.Agent

  graph do
    state do
      channel(:items, merge: fn existing, update -> existing ++ List.wrap(update) end)
    end

    node(:route, fn _state -> %Command{goto: :fanout} end)

    node(:fanout, fn _state ->
      [%Send{node: :worker, update: %{item: "a"}}, %Send{node: :worker, update: %{item: "b"}}]
    end)

    node(:worker, fn state -> %{items: [state.item]} end)

    edge(start(), :route)
    edge(:worker, finish())
  end
end

{:ok, %{items: items}} = BeamWeaver.Examples.BranchingWaitingGraph.invoke(%{items: []})
IO.puts(items |> Enum.sort() |> Enum.join(","))
