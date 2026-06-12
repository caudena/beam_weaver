defmodule BeamWeaver.Examples.ResearchPipelineGraph do
  use BeamWeaver.Agent

  name("ResearchPipeline")

  graph do
    state do
      channel(:reviews, merge: &__MODULE__.deep_merge/2)
    end

    node(:plan, &__MODULE__.plan/1)
    node(:facts, &__MODULE__.facts/1, deps: :plan, output: :facts_data)
    node(:market, &__MODULE__.market/1, deps: :plan, output: :market_data)
    node(:facts_check, &__MODULE__.facts_check/1, deps: :facts, output: [:reviews, :facts])
    node(:market_check, &__MODULE__.market_check/1, deps: :market, output: [:reviews, :market])
    node(:final, &__MODULE__.final/1, deps: [:facts_check, :market_check], when: %{status: :accepted})

    edge(start(), :plan)
    edge(:facts_check, :facts, when: %{status: :needs_revision}, max_runs: 2)
    edge(:market_check, :market, when: %{status: :needs_revision}, max_runs: 2)
    edge(:final, finish())
  end

  def deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value),
        do: Map.merge(left_value, right_value),
        else: right_value
    end)
  end

  def plan(state), do: %{plan: "Research #{state.topic} with facts and market context."}

  def facts(state) do
    revised? = get_in(state, [:reviews, :facts, :status]) == :needs_revision
    suffix = if revised?, do: " with verifier feedback applied", else: ""
    %{data: "facts for #{state.topic}#{suffix}"}
  end

  def market(state), do: %{data: "market context for #{state.topic}"}

  def facts_check(state) do
    if String.contains?(state.facts_data.data, "feedback applied") do
      %{status: :accepted, data: state.facts_data.data}
    else
      %{status: :needs_revision, feedback: "cite stronger sources"}
    end
  end

  def market_check(state), do: %{status: :accepted, data: state.market_data.data}

  def final(state) do
    %{
      summary: """
      #{state.reviews.facts.data}
      #{state.reviews.market.data}
      """
    }
  end
end

{:ok, state} =
  BeamWeaver.Examples.ResearchPipelineGraph.invoke(%{topic: "agent workflow APIs"},
    recursion_limit: 10
  )

IO.puts(state.summary)
