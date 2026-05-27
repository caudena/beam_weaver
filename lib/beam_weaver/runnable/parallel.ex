defmodule BeamWeaver.Runnable.Parallel do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result
  alias BeamWeaver.Runnable
  alias BeamWeaver.Runnable.Config

  defstruct steps: %{}

  @impl true
  def invoke(%__MODULE__{steps: steps}, input, opts) when is_map(steps) do
    config = Config.normalize(opts)

    steps
    |> Enum.to_list()
    |> Task.async_stream(
      fn {key, runnable} ->
        {key, Runnable.invoke(runnable, input, opts)}
      end,
      ordered: true,
      max_concurrency: config.max_concurrency,
      timeout: Keyword.get(opts, :timeout, 5_000),
      on_timeout: :kill_task
    )
    |> Stream.map(fn
      {:ok, {key, {:ok, output}}} ->
        {:ok, {key, output}}

      {:ok, {_key, {:error, %Error{} = error}}} ->
        {:error, error}

      {:exit, reason} ->
        {:error,
         Error.new(:runnable_parallel_exit, "parallel runnable exited", %{
           reason: inspect(reason)
         })}
    end)
    |> Result.collect()
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  def invoke(%__MODULE__{steps: steps}, input, opts) when is_list(steps) do
    steps
    |> Enum.with_index()
    |> Map.new(fn {step, index} -> {index, step} end)
    |> then(&invoke(%__MODULE__{steps: &1}, input, opts))
    |> case do
      {:ok, map} -> {:ok, map |> Enum.sort() |> Enum.map(fn {_index, value} -> value end)}
      error -> error
    end
  end
end

defimpl BeamWeaver.Runnable.Spec, for: BeamWeaver.Runnable.Parallel do
  def to_spec(%{steps: steps}) when is_map(steps) do
    BeamWeaver.Result.traverse(steps, fn {key, step} ->
      with {:ok, spec} <- BeamWeaver.Runnable.to_spec(step) do
        {:ok, {to_string(key), spec}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, %{"type" => "parallel", "steps" => Map.new(specs)}}
      error -> error
    end
  end

  def to_spec(%{steps: steps}) when is_list(steps) do
    BeamWeaver.Result.traverse(steps, &BeamWeaver.Runnable.to_spec/1)
    |> case do
      {:ok, specs} -> {:ok, %{"type" => "parallel", "steps" => specs}}
      error -> error
    end
  end
end

defimpl BeamWeaver.Runnable.Introspect, for: BeamWeaver.Runnable.Parallel do
  alias BeamWeaver.Runnable.Graph

  def graph(%{steps: steps}, _opts) do
    steps = if is_map(steps), do: Map.to_list(steps), else: Enum.with_index(steps, &{&2, &1})

    nodes =
      steps
      |> Map.new(fn {key, runnable} ->
        {"branch_#{key}", %{label: Graph.label(runnable), runnable: runnable}}
      end)
      |> Map.put("input", %{label: "Input"})
      |> Map.put("output", %{label: "Output"})

    edges =
      Enum.flat_map(steps, fn {key, _runnable} ->
        [{"input", "branch_#{key}", to_string(key)}, {"branch_#{key}", "output"}]
      end)

    %Graph{nodes: nodes, edges: edges}
  end

  def input_schema(_parallel), do: %{"type" => "any"}

  def output_schema(%{steps: steps}) when is_map(steps) do
    %{
      "type" => "object",
      "properties" =>
        Map.new(steps, fn {key, runnable} ->
          {to_string(key), BeamWeaver.Runnable.output_schema(runnable)}
        end)
    }
  end

  def output_schema(_parallel), do: %{"type" => "array"}

  def config_specs(%{steps: steps}) do
    steps
    |> then(fn steps -> if is_map(steps), do: Map.values(steps), else: steps end)
    |> Enum.flat_map(&BeamWeaver.Runnable.config_specs/1)
    |> Map.new(&{&1.id, &1})
    |> Map.values()
  end
end
