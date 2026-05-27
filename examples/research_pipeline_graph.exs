alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

deep_merge = fn left, right ->
  Map.merge(left, right, fn _key, left_value, right_value ->
    if is_map(left_value) and is_map(right_value),
      do: Map.merge(left_value, right_value),
      else: right_value
  end)
end

plan = fn state ->
  %{plan: "Research #{state.topic} with facts and market context."}
end

facts = fn state ->
  revised? = get_in(state, [:reviews, :facts, :status]) == :needs_revision
  suffix = if revised?, do: " with verifier feedback applied", else: ""
  %{data: "facts for #{state.topic}#{suffix}"}
end

market = fn state ->
  %{data: "market context for #{state.topic}"}
end

facts_check = fn state ->
  if String.contains?(state.facts_data.data, "feedback applied") do
    %{status: :accepted, data: state.facts_data.data}
  else
    %{status: :needs_revision, feedback: "cite stronger sources"}
  end
end

market_check = fn state ->
  %{status: :accepted, data: state.market_data.data}
end

final = fn state ->
  %{
    summary: """
    #{state.reviews.facts.data}
    #{state.reviews.market.data}
    """
  }
end

graph =
  Graph.new(name: "ResearchPipeline")
  |> Graph.add_reducer(:reviews, deep_merge)
  |> Graph.add_node(:plan, plan)
  |> Graph.add_node(:facts, facts, deps: :plan, output: :facts_data)
  |> Graph.add_node(:market, market, deps: :plan, output: :market_data)
  |> Graph.add_node(:facts_check, facts_check, deps: :facts, output: [:reviews, :facts])
  |> Graph.add_node(:market_check, market_check, deps: :market, output: [:reviews, :market])
  |> Graph.add_node(:final, final,
    deps: [:facts_check, :market_check],
    when: %{status: :accepted}
  )
  |> Graph.add_edge(Graph.start(), :plan)
  |> Graph.add_edge(:facts_check, :facts, when: %{status: :needs_revision}, max_runs: 2)
  |> Graph.add_edge(:market_check, :market, when: %{status: :needs_revision}, max_runs: 2)
  |> Graph.add_edge(:final, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(graph, %{topic: "agent workflow APIs"}, recursion_limit: 10)
IO.puts(state.summary)
