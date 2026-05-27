defmodule BeamWeaver.Runnable.Branch do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable

  defstruct branches: []

  @impl true
  def invoke(%__MODULE__{branches: branches}, input, opts) do
    case Enum.find_value(branches, &matching_runnable(&1, input, opts)) do
      nil -> {:error, Error.new(:no_matching_branch, "no runnable branch matched input")}
      runnable -> Runnable.invoke(runnable, input, opts)
    end
  end

  @impl true
  def stream(%__MODULE__{branches: branches}, input, opts) do
    case Enum.find_value(branches, &matching_runnable(&1, input, opts)) do
      nil -> {:error, Error.new(:no_matching_branch, "no runnable branch matched input")}
      runnable -> Runnable.stream(runnable, input, opts)
    end
  end

  defp matching_runnable({predicate, runnable}, input, opts) do
    if predicate_matches?(predicate, input, opts), do: runnable
  end

  defp matching_runnable(runnable, _input, _opts), do: runnable

  defp predicate_matches?(true, _input, _opts), do: true
  defp predicate_matches?(:default, _input, _opts), do: true
  defp predicate_matches?(fun, input, _opts) when is_function(fun, 1), do: fun.(input) == true

  defp predicate_matches?(fun, input, opts) when is_function(fun, 2),
    do: fun.(input, opts) == true

  defp predicate_matches?(_predicate, _input, _opts), do: false
end

defimpl BeamWeaver.Runnable.Introspect, for: BeamWeaver.Runnable.Branch do
  alias BeamWeaver.Runnable.Graph

  def graph(%{branches: branches}, _opts) do
    runnables = branch_runnables(branches)

    nodes =
      runnables
      |> Enum.with_index()
      |> Map.new(fn {runnable, index} ->
        {"branch_#{index}", %{label: Graph.label(runnable), runnable: runnable}}
      end)
      |> Map.put("input", %{label: "Input"})
      |> Map.put("output", %{label: "Output"})

    edges =
      runnables
      |> Enum.with_index()
      |> Enum.flat_map(fn {_runnable, index} ->
        [{"input", "branch_#{index}", "branch #{index + 1}"}, {"branch_#{index}", "output"}]
      end)

    %Graph{
      nodes: nodes,
      edges: edges,
      input_schema: branch_input_schema(branches),
      output_schema: branch_output_schema(branches)
    }
  end

  def input_schema(%{branches: branches}), do: branch_input_schema(branches)

  def output_schema(%{branches: branches}), do: branch_output_schema(branches)

  def config_specs(%{branches: branches}) do
    branches
    |> branch_parts()
    |> Enum.flat_map(&BeamWeaver.Runnable.config_specs/1)
    |> Map.new(&{&1.id, &1})
    |> Map.values()
  end

  defp branch_input_schema(branches) do
    branches
    |> branch_runnables()
    |> Enum.find_value(fn runnable ->
      case BeamWeaver.Runnable.input_schema(runnable) do
        %{"type" => "any"} -> nil
        schema -> schema
      end
    end) || %{"type" => "any"}
  end

  defp branch_output_schema(branches) do
    branches
    |> branch_runnables()
    |> Enum.find_value(fn runnable ->
      case BeamWeaver.Runnable.output_schema(runnable) do
        %{"type" => "any"} -> nil
        schema -> schema
      end
    end) || %{"type" => "any"}
  end

  defp branch_runnables(branches) do
    branches
    |> Enum.flat_map(fn
      {_predicate, runnable} -> [runnable]
      runnable -> [runnable]
    end)
  end

  defp branch_parts(branches) do
    branches
    |> Enum.flat_map(fn
      {predicate, runnable} -> [predicate, runnable]
      runnable -> [runnable]
    end)
  end
end
