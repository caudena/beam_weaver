defmodule BeamWeaver.Runnable.Router do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result
  alias BeamWeaver.Runnable

  defstruct routes: %{}

  @impl true
  def invoke(%__MODULE__{} = router, input, opts) do
    with {:ok, key, actual_input} <- router_input(input),
         {:ok, runnable} <- fetch_route(router.routes, key) do
      Runnable.invoke(runnable, actual_input, opts)
    end
  end

  @impl true
  def batch(%__MODULE__{} = router, inputs, opts) when is_list(inputs) do
    Result.traverse(inputs, &invoke(router, &1, opts))
  end

  def batch(_router, _inputs, _opts),
    do: {:error, Error.new(:invalid_router_input, "router batch input must be a list")}

  @impl true
  def stream(%__MODULE__{} = router, input, opts) do
    with {:ok, key, actual_input} <- router_input(input),
         {:ok, runnable} <- fetch_route(router.routes, key) do
      Runnable.stream(runnable, actual_input, opts)
    end
  end

  defp router_input(input) when is_map(input) do
    with {:ok, key} <- fetch_key(input, :key),
         {:ok, actual_input} <- fetch_key(input, :input) do
      {:ok, key, actual_input}
    else
      :error ->
        {:error,
         Error.new(:invalid_router_input, "router input must contain :key and :input", %{
           input: inspect(input)
         })}
    end
  end

  defp router_input(input) do
    {:error, Error.new(:invalid_router_input, "router input must be a map", %{input: inspect(input)})}
  end

  defp fetch_key(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.fetch!(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp fetch_route(routes, key) do
    cond do
      Map.has_key?(routes, key) ->
        {:ok, Map.fetch!(routes, key)}

      Map.has_key?(routes, to_string(key)) ->
        {:ok, Map.fetch!(routes, to_string(key))}

      (is_binary(key) and existing_atom(key)) && Map.has_key?(routes, existing_atom(key)) ->
        {:ok, Map.fetch!(routes, existing_atom(key))}

      true ->
        {:error, Error.new(:missing_router_route, "no runnable route matched input key", %{key: key})}
    end
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end

defimpl BeamWeaver.Runnable.Spec, for: BeamWeaver.Runnable.Router do
  def to_spec(%{routes: routes}) do
    routes
    |> BeamWeaver.Result.traverse(fn {key, runnable} ->
      with {:ok, spec} <- BeamWeaver.Runnable.to_spec(runnable) do
        {:ok, {to_string(key), spec}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, %{"type" => "router", "routes" => Map.new(specs)}}
      error -> error
    end
  end
end

defimpl BeamWeaver.Runnable.Introspect, for: BeamWeaver.Runnable.Router do
  alias BeamWeaver.Runnable.Graph

  def graph(%{routes: routes}, _opts) do
    nodes =
      routes
      |> Map.new(fn {key, runnable} ->
        {"route_#{key}", %{label: Graph.label(runnable), runnable: runnable}}
      end)
      |> Map.put("input", %{label: "RouterInput"})
      |> Map.put("output", %{label: "Output"})

    edges =
      routes
      |> Enum.flat_map(fn {key, _runnable} ->
        [{"input", "route_#{key}", to_string(key)}, {"route_#{key}", "output"}]
      end)

    %Graph{
      nodes: nodes,
      edges: edges,
      input_schema: router_input_schema(),
      output_schema: router_output_schema(routes)
    }
  end

  def input_schema(_router), do: router_input_schema()

  def output_schema(%{routes: routes}), do: router_output_schema(routes)

  def config_specs(%{routes: routes}) do
    routes
    |> Map.values()
    |> Enum.flat_map(&BeamWeaver.Runnable.config_specs/1)
    |> Map.new(&{&1.id, &1})
    |> Map.values()
  end

  defp router_input_schema do
    %{
      "type" => "object",
      "required" => ["key", "input"],
      "properties" => %{"key" => %{"type" => "string"}, "input" => %{"type" => "any"}}
    }
  end

  defp router_output_schema(routes) do
    routes
    |> Map.values()
    |> List.first()
    |> case do
      nil -> %{"type" => "any"}
      runnable -> BeamWeaver.Runnable.output_schema(runnable)
    end
  end
end
