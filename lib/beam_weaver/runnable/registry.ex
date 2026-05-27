defmodule BeamWeaver.Runnable.Registry do
  @moduledoc """
  Explicit registry for rebuilding runnables from safe specs.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result
  alias BeamWeaver.Runnable

  def default do
    %{
      "sequence" => fn spec, registry -> from_children(spec, registry, &Runnable.sequence/1) end,
      "parallel" => fn spec, registry -> parallel_from_spec(spec, registry) end,
      "router" => fn spec, registry -> router_from_spec(spec, registry) end,
      "passthrough" => fn _spec, _registry -> {:ok, Runnable.passthrough()} end,
      "pick" => fn spec, _registry -> {:ok, Runnable.pick(Map.fetch!(spec, "keys"))} end,
      "binding" => fn spec, registry ->
        with {:ok, runnable} <-
               Runnable.from_spec(Map.fetch!(spec, "runnable"), registry: registry) do
          {:ok, Runnable.bind(runnable, keyword_opts(Map.get(spec, "opts", %{})))}
        end
      end,
      "with_config" => fn spec, registry ->
        with {:ok, runnable} <-
               Runnable.from_spec(Map.fetch!(spec, "runnable"), registry: registry) do
          {:ok, Runnable.with_config(runnable, keyword_opts(Map.get(spec, "opts", %{})))}
        end
      end,
      "prompt_string" => fn spec, _registry -> BeamWeaver.Prompt.Spec.from_spec(spec) end,
      "prompt_chat" => fn spec, _registry -> BeamWeaver.Prompt.Spec.from_spec(spec) end,
      "prompt_structured" => fn spec, _registry -> BeamWeaver.Prompt.Spec.from_spec(spec) end,
      "prompt_structured_chat" => fn spec, _registry ->
        BeamWeaver.Prompt.Spec.from_spec(spec)
      end,
      "output_parser_string" => fn spec, _registry ->
        BeamWeaver.OutputParser.Spec.from_spec(spec)
      end,
      "output_parser_json" => fn spec, _registry ->
        BeamWeaver.OutputParser.Spec.from_spec(spec)
      end,
      "output_parser_list" => fn spec, _registry ->
        BeamWeaver.OutputParser.Spec.from_spec(spec)
      end,
      "output_parser_csv" => fn spec, _registry ->
        BeamWeaver.OutputParser.Spec.from_spec(spec)
      end,
      "output_parser_xml" => fn spec, _registry ->
        BeamWeaver.OutputParser.Spec.from_spec(spec)
      end,
      "output_parser_openai_tools" => fn spec, _registry ->
        BeamWeaver.OutputParser.Spec.from_spec(spec)
      end,
      "output_parser_openai_functions" => fn spec, _registry ->
        BeamWeaver.OutputParser.Spec.from_spec(spec)
      end,
      "output_parser_schema" => fn spec, _registry ->
        BeamWeaver.OutputParser.Spec.from_spec(spec)
      end
    }
  end

  def build(registry, %{"type" => type} = spec) do
    registry = registry || default()

    case Map.fetch(registry, type) do
      {:ok, builder} ->
        builder.(spec, registry)

      :error ->
        {:error, Error.new(:unknown_runnable_spec, "unknown runnable spec type", %{type: type})}
    end
  end

  def build(_registry, _spec),
    do: {:error, Error.new(:invalid_runnable_spec, "runnable spec must be a map with a type")}

  defp from_children(spec, registry, builder) do
    spec
    |> Map.fetch!("steps")
    |> Result.traverse(&Runnable.from_spec(&1, registry: registry))
    |> case do
      {:ok, runnables} -> {:ok, builder.(runnables)}
      error -> error
    end
  end

  defp parallel_from_spec(%{"steps" => steps}, registry) when is_map(steps) do
    Result.traverse(steps, fn {key, child} ->
      with {:ok, runnable} <- Runnable.from_spec(child, registry: registry) do
        {:ok, {key, runnable}}
      end
    end)
    |> case do
      {:ok, runnables} -> {:ok, Runnable.parallel(Map.new(runnables))}
      error -> error
    end
  end

  defp parallel_from_spec(%{"steps" => steps}, registry) when is_list(steps),
    do: from_children(%{"steps" => steps}, registry, &Runnable.parallel/1)

  defp router_from_spec(%{"routes" => routes}, registry) when is_map(routes) do
    Result.traverse(routes, fn {key, child} ->
      with {:ok, runnable} <- Runnable.from_spec(child, registry: registry) do
        {:ok, {key, runnable}}
      end
    end)
    |> case do
      {:ok, routes} -> {:ok, Runnable.router(Map.new(routes))}
      error -> error
    end
  end

  defp keyword_opts(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      case existing_atom(key) do
        {:ok, atom} -> [{atom, value}]
        :error -> []
      end
    end)
  end

  defp keyword_opts(opts) when is_list(opts), do: opts

  defp existing_atom(key) when is_atom(key), do: {:ok, key}

  defp existing_atom(key) do
    {:ok, String.to_existing_atom(to_string(key))}
  rescue
    ArgumentError -> :error
  end
end
