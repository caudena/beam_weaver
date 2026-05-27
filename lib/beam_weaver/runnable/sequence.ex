defmodule BeamWeaver.Runnable.Sequence do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Runnable

  defstruct steps: [], name: nil

  @impl true
  def invoke(%__MODULE__{steps: steps}, input, opts) do
    Enum.reduce_while(steps, {:ok, input}, fn step, {:ok, acc} ->
      case Runnable.invoke(step, acc, opts) do
        {:ok, output} -> {:cont, {:ok, output}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @impl true
  def stream(%__MODULE__{} = sequence, input, opts) do
    case split_last(sequence.steps) do
      {[], nil} ->
        {:ok, [input]}

      {prefix, last} ->
        prefix = %__MODULE__{steps: prefix, name: sequence.name}

        with {:ok, intermediate} <- invoke(prefix, input, opts) do
          Runnable.stream(last, intermediate, opts)
        end
    end
  end

  @impl true
  def transform(%__MODULE__{steps: []}, input, _opts), do: {:ok, input}

  def transform(%__MODULE__{steps: [first | rest]}, input, opts) do
    with {:ok, stream} <- Runnable.transform(first, input, opts) do
      Enum.reduce_while(rest, {:ok, stream}, fn step, {:ok, acc} ->
        case Runnable.transform(step, acc, opts) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp split_last([]), do: {[], nil}

  defp split_last(steps) do
    {Enum.drop(steps, -1), List.last(steps)}
  end
end

defimpl BeamWeaver.Runnable.Spec, for: BeamWeaver.Runnable.Sequence do
  def to_spec(%{steps: steps, name: name}) do
    BeamWeaver.Result.traverse(steps, &BeamWeaver.Runnable.to_spec/1)
    |> case do
      {:ok, specs} ->
        spec = %{"type" => "sequence", "steps" => specs}
        {:ok, maybe_put_name(spec, name)}

      error ->
        error
    end
  end

  defp maybe_put_name(spec, nil), do: spec
  defp maybe_put_name(spec, name), do: Map.put(spec, "name", to_string(name))
end

defimpl BeamWeaver.Runnable.Introspect, for: BeamWeaver.Runnable.Sequence do
  alias BeamWeaver.Runnable.Graph

  def graph(%{steps: steps}, _opts) do
    nodes =
      steps
      |> Enum.with_index()
      |> Map.new(fn {step, index} ->
        {"step_#{index}", %{label: Graph.label(step), runnable: step}}
      end)

    edges =
      if length(steps) < 2 do
        []
      else
        Enum.map(0..(length(steps) - 2), fn index -> {"step_#{index}", "step_#{index + 1}"} end)
      end

    %Graph{nodes: nodes, edges: edges}
  end

  def input_schema(%{steps: [first | _]}), do: BeamWeaver.Runnable.input_schema(first)
  def input_schema(_sequence), do: %{"type" => "any"}

  def output_schema(%{steps: steps}) when steps != [],
    do: BeamWeaver.Runnable.output_schema(List.last(steps))

  def output_schema(_sequence), do: %{"type" => "any"}

  def config_specs(%{steps: steps}) do
    steps
    |> Enum.flat_map(&BeamWeaver.Runnable.config_specs/1)
    |> Map.new(&{&1.id, &1})
    |> Map.values()
  end
end
