defmodule BeamWeaver.Examples.BasicGraph do
  use BeamWeaver.Agent

  graph do
    node(:greet, fn state -> %{answer: "hello #{state.name}"} end)

    edge(start(), :greet)
    edge(:greet, finish())
  end
end

{:ok, %{answer: answer}} = BeamWeaver.Examples.BasicGraph.invoke(%{name: "BeamWeaver"})
IO.puts(answer)
