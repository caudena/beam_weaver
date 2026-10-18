defmodule BeamWeaver.Graph.ModuleRunner do
  @moduledoc false

  # Runs a module with `use BeamWeaver.Graph`: compiles its graph with what
  # its declarations evaluate to, which a call's options replace, and runs it.

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.StateGraph

  require Logger

  # Declarations that compile into the graph; the rest are run options.
  @compile_options [:checkpointer, :store, :cache, :interrupt_before, :interrupt_after, :step_timeout, :run_timeout]

  @spec compiled_graph(module(), keyword()) :: {:ok, Compiled.t()} | {:error, Error.t()}
  def compiled_graph(module, opts), do: compile(module, declared(module), opts)

  @spec invoke(module(), map(), keyword()) :: {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  def invoke(module, input, opts) do
    with {:ok, compiled, opts} <- prepare(module, opts), do: Compiled.invoke(compiled, input, opts)
  end

  @spec stream_events(module(), map(), keyword()) ::
          {:ok, Enumerable.t()} | {:interrupted, map()} | {:error, Error.t()}
  def stream_events(module, input, opts) do
    with {:ok, compiled, opts} <- prepare(module, opts), do: Compiled.stream_events(compiled, input, opts)
  end

  @spec resume(module(), term(), keyword()) :: {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  def resume(module, resume, opts) do
    with {:ok, compiled, opts} <- prepare(module, opts), do: Compiled.resume(compiled, resume, opts)
  end

  @spec get_state(module(), keyword()) :: {:ok, map()} | :error | {:error, Error.t()}
  def get_state(module, opts) do
    with {:ok, compiled} <- compiled_graph(module, opts),
         do: Compiled.get_state(compiled, Keyword.get(opts, :config, %{}))
  end

  @doc "The recursion limit `module` declares, `nil` when it declares none."
  @spec recursion_limit(module()) :: non_neg_integer() | nil
  def recursion_limit(module), do: Keyword.get(module.__beam_weaver_graph_options__(), :recursion_limit)

  # A call's own recursion limit replaces the declared one.
  defp prepare(module, opts) do
    declared = declared(module)

    with {:ok, compiled} <- compile(module, declared, opts) do
      {:ok, compiled, Keyword.merge(Keyword.take(declared, [:recursion_limit]), opts)}
    end
  end

  defp declared(module) do
    declared = module.__beam_weaver_graph_options__()
    warn_on_new_storage(module, declared)
    declared
  end

  defp compile(module, declared, opts) do
    compile_opts =
      @compile_options
      |> Enum.map(&{&1, Keyword.get(opts, &1, declared[&1])})
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Keyword.put(:name, Keyword.get(opts, :name, declared[:name] || inspect(module)))

    case module.graph() do
      %Compiled{} = compiled ->
        {:ok, compiled}

      %StateGraph{} = graph ->
        Graph.compile(graph, compile_opts)

      other ->
        {:error,
         Error.new(:invalid_graph, "#{inspect(module)}.graph/0 must return a graph or a compiled graph", %{
           returned: inspect(other)
         })}
    end
  end

  @new_storage [
    checkpointer: {BeamWeaver.Checkpoint.ETS, :checkpoints, "saver", "BeamWeaver.Checkpoint.Ecto"},
    store: {BeamWeaver.Memory.ETS, :items, "store", "BeamWeaver.Memory.Ecto"}
  ]

  @doc """
  Warns once per version of `module` when its declared `checkpointer` or
  `store`, in `declared`, calls a function that returns a new ETS saver or
  store each time: that loses every thread, like an inline
  `Checkpoint.ETS.new()`, which doesn't compile. A second evaluation of the
  declaration shows it: a long-lived saver comes back with the same tables.
  """
  @spec warn_on_new_storage(module(), keyword() | map()) :: :ok
  def warn_on_new_storage(module, declared) do
    for {declaration, {adapter, table, noun, durable}} <- @new_storage,
        stored = declared[declaration],
        match?(%{__struct__: ^adapter}, stored),
        first_check?(module, declaration),
        new_tables?(stored, apply(module, declaration, []), table) do
      Logger.warning(
        "#{inspect(module)}'s `#{declaration}` declaration returned a new #{inspect(adapter)} #{noun} " <>
          "when it was evaluated again. Declarations are evaluated on every call, so every call gets an " <>
          "empty #{noun} and what earlier calls saved is lost. Create the #{noun} once, in your " <>
          "application's supervision tree or a test's setup, and pass it per call with `#{declaration}:`, " <>
          "or return that same #{noun} from the declaration; or use #{durable}."
      )
    end

    :ok
  end

  defp first_check?(module, declaration) do
    key = {__MODULE__, :new_storage, module, declaration, module.module_info(:md5)}
    not :persistent_term.get(key, false) and :persistent_term.put(key, true) == :ok
  end

  defp new_tables?(%adapter{} = first, %adapter{} = second, table),
    do: Map.fetch!(first, table) != Map.fetch!(second, table)

  defp new_tables?(_first, _second, _table), do: false
end
