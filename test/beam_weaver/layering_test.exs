defmodule BeamWeaver.LayeringTest do
  use ExUnit.Case, async: true

  # Each namespace's layer, lowest first. A module may use modules of its own
  # layer and of the layers below it, never of a layer above.
  @layers [
    base:
      ~w(Behaviour Config JSON YAML MapAccess MapShape Options Result Policy RetryPolicy RetryPredicates TimeoutPolicy
         ExecutionPolicy CachePolicy RateLimitPolicy),
    core: ~w(Core Schema Tool ToolKit Tokenizer),
    services: ~w(Tracing Telemetry Diagnostics Serialization Cache RateLimiter Adapter Migration Migrations Transport),
    models: ~w(Provider Models OpenAI Anthropic Google DeepSeek Moonshot XAI ZAI TypeSafe PromptCache ContextBudget
         VectorStore Retriever RetrievalPolicy TextSplitter),
    runtime: ~w(Graph Checkpoint Stream Filesystem Sandbox ShellPolicy Memory Skill Compaction),
    agent: ~w(Agent Tools Application)
  ]

  # Modules whose layer isn't their namespace's. The error and id every layer
  # uses are base. The stream events are core: models stream them. The
  # stream's facade, sink and mux are services: a model call streams through
  # them as a graph run does. In `Core`, the model-calling API, the tools it
  # traces and runs, and the message helpers that count tokens as a model
  # reads them or encode for OpenAI run the shared provider pipeline, so they
  # sit with the models; the tool schema builders stay core. A name ending in `.*` covers the modules below it too.
  @placed [
    {"BeamWeaver.Core.Error", :base},
    {"BeamWeaver.Core.ID", :base},
    {"BeamWeaver.Stream.Envelope", :core},
    {"BeamWeaver.Stream.Events.*", :core},
    {"BeamWeaver.Stream.Namespace", :core},
    {"BeamWeaver.Stream.IntoEvent.*", :core},
    {"BeamWeaver.Stream.Finalize.*", :core},
    {"BeamWeaver.Stream", :services},
    {"BeamWeaver.Stream.Sink", :services},
    {"BeamWeaver.Stream.Mux.*", :services},
    {"BeamWeaver.Stream.Policy", :services},
    {"BeamWeaver.Stream.HeartbeatPolicy", :services},
    {"BeamWeaver.Core.ChatModel", :models},
    {"BeamWeaver.Core.LanguageModel", :models},
    {"BeamWeaver.Core.DecisionModel", :models},
    {"BeamWeaver.Core.Tool.*", :models},
    {"BeamWeaver.Tool", :models},
    {"BeamWeaver.Tool.Definition", :models},
    {"BeamWeaver.Tool.Renderer", :models},
    {"BeamWeaver.ToolKit", :models},
    {"BeamWeaver.Core.Messages.Utils", :models},
    {"BeamWeaver.Core.Messages.Trim", :models},
    {"BeamWeaver.Core.Messages.TokenCounter", :models},
    {"BeamWeaver.Core.Messages.OpenAI", :models},
    {"BeamWeaver.Filesystem.Conformance", :agent}
  ]

  # The serialization allowlist names the structs it may decode, from every
  # layer: naming them in one place is what makes it an allowlist.
  @may_name_any ["BeamWeaver.Serialization.*"]

  @rank @layers |> Enum.with_index() |> Map.new(fn {{layer, _namespaces}, index} -> {layer, index} end)
  @layer_of for {layer, namespaces} <- @layers, namespace <- namespaces, into: %{}, do: {namespace, layer}

  test "every namespace has a layer" do
    unplaced = for module <- modules(), is_nil(layer(module)), uniq: true, do: namespace(module)
    assert unplaced == [], "give these namespaces a layer: #{inspect(unplaced)}"
  end

  test "no module uses a module of a higher layer" do
    violations =
      for module <- modules(),
          not covered?(module, @may_name_any),
          from = layer(module),
          referenced <- referenced_modules(module),
          to = layer(referenced),
          @rank[to] > @rank[from],
          do: "#{inspect(module)} (#{from}) uses #{inspect(referenced)} (#{to})"

    assert violations == [], "layering violations:\n" <> Enum.join(Enum.uniq(violations), "\n")
  end

  defp modules do
    {:ok, modules} = :application.get_key(:beam_weaver, :modules)
    Enum.filter(modules, &beam_weaver_module?/1)
  end

  defp beam_weaver_module?(module), do: match?(["BeamWeaver" | _rest], Module.split(module))

  # The modules a module's compiled code names: the atoms of its BEAM file.
  # Documentation is kept apart from the code, so prose never counts.
  defp referenced_modules(module) do
    {:ok, {^module, [atoms: atoms]}} = module |> :code.which() |> :beam_lib.chunks([:atoms])

    for {_index, atom} <- atoms,
        String.starts_with?(Atom.to_string(atom), "Elixir.BeamWeaver."),
        atom != module,
        do: atom
  end

  # A protocol implementation sits with the higher of its protocol and the
  # type it is for. `BeamWeaver` itself only documents where to start.
  defp layer(BeamWeaver), do: :agent

  defp layer(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__impl__, 1),
      do: [module.__impl__(:protocol), module.__impl__(:for)] |> Enum.map(&namespace_layer/1) |> highest(),
      else: namespace_layer(module)
  end

  defp namespace_layer(module) do
    cond do
      not beam_weaver_module?(module) -> :base
      placed = placed_layer(module) -> placed
      true -> Map.get(@layer_of, namespace(module))
    end
  end

  defp placed_layer(module),
    do: Enum.find_value(@placed, fn {name, layer} -> if covered?(module, [name]), do: layer end)

  # Whether `module` is one of `names`, or below a name that ends in `.*`.
  defp covered?(module, names) do
    name = inspect(module)

    Enum.any?(names, fn placed ->
      case String.split(placed, ".*") do
        [prefix, ""] -> name == prefix or String.starts_with?(name, prefix <> ".")
        [exact] -> name == exact
      end
    end)
  end

  defp highest(layers), do: Enum.max_by(layers, &@rank[&1])

  defp namespace(module) do
    case Module.split(module) do
      ["BeamWeaver", namespace | _rest] -> namespace
      _other -> nil
    end
  end
end
