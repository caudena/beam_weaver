defmodule BeamWeaver.Graph.DSL do
  @moduledoc false

  # The declarations of a module with `use BeamWeaver.Graph`, and the parts of
  # them that agent modules share: storage declarations and their checks.

  @graph_fields [:nodes, :edges, :reducers, :channels, :joins]

  @declarations ~w(name checkpointer store cache interrupt_before interrupt_after recursion_limit step_timeout
                   run_timeout)a

  # In-memory adapters whose `new` creates ETS tables, with the declaration
  # that takes each, its database-backed counterpart, and what every call
  # loses when that declaration builds a new one.
  @in_memory_adapters %{
    BeamWeaver.Checkpoint.ETS =>
      {:checkpointer, "saver", "BeamWeaver.Checkpoint.Ecto",
       "every call starts its thread over and get_state/1 finds nothing"},
    BeamWeaver.Memory.ETS => {:store, "store", "BeamWeaver.Memory.Ecto", "what one call saves is gone in the next"},
    BeamWeaver.Cache.ETS => {:cache, "cache", "BeamWeaver.Cache.Ecto", "nothing one call caches is found by the next"}
  }

  def imports do
    [node: 2, node: 3, edge: 2, edge: 3, reducer: 2, graph: 1, interrupts: 1] ++ Enum.map(@declarations, &{&1, 1})
  end

  def using do
    attribute_quotes =
      for name <- @declarations ++ @graph_fields do
        quote do
          Module.register_attribute(__MODULE__, unquote(attr(name)), accumulate: unquote(name in @graph_fields))
        end
      end

    quote do
      @behaviour BeamWeaver.Graph

      import BeamWeaver.Graph.DSL, only: unquote(imports())

      unquote_splicing(attribute_quotes)

      @before_compile BeamWeaver.Graph.DSL

      def invoke(input, opts \\ []), do: BeamWeaver.Graph.ModuleRunner.invoke(__MODULE__, input, opts)

      def stream_events(input, opts \\ []), do: BeamWeaver.Graph.ModuleRunner.stream_events(__MODULE__, input, opts)

      def resume(resume, opts \\ []), do: BeamWeaver.Graph.ModuleRunner.resume(__MODULE__, resume, opts)

      def get_state(opts \\ []), do: BeamWeaver.Graph.ModuleRunner.get_state(__MODULE__, opts)
    end
  end

  defmacro node(name, fun_ast, opts \\ []) do
    quote bind_quoted: [name: name, fun_ast: Macro.escape(fun_ast), opts: opts] do
      @beam_weaver_nodes {name, fun_ast, opts}
    end
  end

  defmacro edge(start_node, end_node, opts \\ []) do
    quote bind_quoted: [start_node: start_node, end_node: end_node, opts: opts] do
      @beam_weaver_edges {start_node, end_node, opts}
    end
  end

  defmacro reducer(key, reducer_ast) do
    quote bind_quoted: [key: key, reducer_ast: Macro.escape(reducer_ast)] do
      @beam_weaver_reducers {key, reducer_ast}
    end
  end

  defmacro graph(do: block) do
    attribute_quotes =
      for {attr, entry} <- graph_block_entries!(__CALLER__, block),
          do: quote(do: Module.put_attribute(__MODULE__, unquote(attr), unquote(entry)))

    quote do
      (unquote_splicing(attribute_quotes))
    end
  end

  defmacro interrupts(opts_ast) do
    before_ast = quote(do: Keyword.get(unquote(opts_ast), :before, []))
    after_ast = quote(do: Keyword.get(unquote(opts_ast), :after, []))

    quote bind_quoted: [before_ast: Macro.escape(before_ast), after_ast: Macro.escape(after_ast)] do
      @beam_weaver_interrupt_before before_ast
      @beam_weaver_interrupt_after after_ast
    end
  end

  for name <- @declarations, attr = :"beam_weaver_#{name}" do
    defmacro unquote(name)(expr_ast) do
      attr = unquote(attr)

      quote bind_quoted: [attr: attr, expr_ast: Macro.escape(expr_ast)] do
        Module.put_attribute(__MODULE__, attr, expr_ast)
      end
    end
  end

  defmacro __before_compile__(env) do
    graph = Map.new(@graph_fields, &{&1, env.module |> Module.get_attribute(attr(&1)) |> Enum.reverse()})
    attrs = Map.new(@declarations, &{&1, Module.get_attribute(env.module, attr(&1))})
    graph_defined? = Module.defines?(env.module, {:graph, 0})

    validate_graph!(env, graph, graph_defined?)
    reject_in_memory_adapters!(env, attrs, graph.nodes)

    {storage_quotes, _attrs} = storage_callbacks(env, attrs)

    # What the module's declarations evaluate to, as the options of its runs.
    options =
      [checkpointer: quote(do: checkpointer()), store: quote(do: store())] ++
        for {name, ast} <- attrs, name not in [:checkpointer, :store], not is_nil(ast), do: {name, ast}

    quote do
      unquote_splicing(if graph_defined?, do: [], else: [graph_builder_quote(env.module, graph)])

      @impl BeamWeaver.Graph
      def compiled_graph(opts \\ []), do: BeamWeaver.Graph.ModuleRunner.compiled_graph(__MODULE__, opts)

      @doc false
      def __beam_weaver_graph_options__, do: unquote(options)

      unquote_splicing(storage_quotes)
    end
  end

  defp attr(name), do: :"beam_weaver_#{name}"

  defp validate_graph!(env, graph, graph_defined?) do
    duplicate_names =
      for {name, count} <- Enum.frequencies_by(graph.nodes, &to_string(elem(&1, 0))), count > 1, do: name

    cond do
      duplicate_names != [] ->
        compile_error!(env, "#{inspect(env.module)} declares duplicate node names: #{Enum.join(duplicate_names, ", ")}")

      graph.nodes != [] and graph_defined? ->
        compile_error!(env, "#{inspect(env.module)} declares nodes and defines graph/0; keep one of them")

      graph.nodes != [] and not Enum.any?(graph.edges, &match?({:__start__, _end_node, _opts}, &1)) ->
        compile_error!(env, "#{inspect(env.module)} must declare an edge from start(), where its runs begin")

      graph.nodes == [] and not graph_defined? ->
        compile_error!(
          env,
          "#{inspect(env.module)} declares no graph: define graph/0, or declare its nodes and edges in `graph do ... end`"
        )

      true ->
        :ok
    end
  end

  defp graph_builder_quote(module, graph) do
    calls =
      Enum.map(graph.channels, fn {key, merge, opts} ->
        {BeamWeaver.Graph.DSL, :__add_channel__, [key, merge, Macro.escape(opts)]}
      end) ++
        Enum.map(graph.reducers, fn {key, reducer_ast} -> {BeamWeaver.Graph, :add_reducer, [key, reducer_ast]} end) ++
        Enum.map(graph.nodes, fn {name, fun_ast, opts} ->
          {BeamWeaver.Graph, :add_node, [name, fun_ast, Macro.escape(opts)]}
        end) ++
        Enum.map(graph.edges, fn {from, to, opts} -> {BeamWeaver.Graph, :add_edge, [from, to, Macro.escape(opts)]} end) ++
        Enum.map(graph.joins, fn {from_nodes, to_node, opts} ->
          {BeamWeaver.Graph, :add_join, [from_nodes, to_node, Macro.escape(opts)]}
        end)

    steps =
      for {builder, fun, args} <- calls,
          do: quote(do: graph = unquote(builder).unquote(fun)(graph, unquote_splicing(args)))

    quote do
      @impl BeamWeaver.Graph
      def graph do
        graph = BeamWeaver.Graph.new(name: inspect(unquote(module)))
        unquote_splicing(steps)
        graph
      end
    end
  end

  @doc false
  def __add_channel__(graph, key, merge, opts) do
    alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
    alias BeamWeaver.Graph.Channels.LastValue

    case merge do
      :last ->
        BeamWeaver.Graph.add_channel(graph, key, LastValue, opts)

      :map ->
        BeamWeaver.Graph.add_channel(
          graph,
          key,
          {BinaryOperatorAggregate, &Map.merge/2},
          Keyword.put_new(opts, :initial, %{})
        )

      :list ->
        BeamWeaver.Graph.add_channel(
          graph,
          key,
          {BinaryOperatorAggregate, fn left, right -> List.wrap(left) ++ List.wrap(right) end},
          Keyword.put_new(opts, :initial, [])
        )

      reducer when is_function(reducer, 2) ->
        BeamWeaver.Graph.add_channel(graph, key, {BinaryOperatorAggregate, reducer}, opts)

      other ->
        raise ArgumentError, "unknown graph state channel merge #{inspect(other)}"
    end
  end

  def compile_error!(env, description),
    do: raise(CompileError, file: env.file, line: env.line, description: description)

  # `checkpointer/0` and `store/0` return what the declarations of the same
  # name evaluate to, `nil` when there is none. A module may define either
  # function instead of declaring it, and then runs with what it returns.
  # (A definition here can't override one from `use`, so `use` defines none.)
  # Returns the callbacks and `attrs`, in which a defined function stands in
  # for its missing declaration.
  def storage_callbacks(env, attrs) do
    Enum.flat_map_reduce([:checkpointer, :store], attrs, fn name, attrs ->
      declared = Map.fetch!(attrs, name)

      cond do
        not Module.defines?(env.module, {name, 0}) ->
          callback =
            quote do
              @impl BeamWeaver.Graph
              def unquote(name)(), do: unquote(declared)
            end

          {[callback], attrs}

        is_nil(declared) ->
          {[], Map.put(attrs, name, quote(do: unquote(name)()))}

        true ->
          compile_error!(env, "#{inspect(env.module)} declares `#{name}` and defines #{name}/0; keep one of them")
      end
    end)
  end

  # Declarations are evaluated on every call, so one that builds an in-memory
  # saver, store or cache gives every call a new, empty one, and leaves its
  # ETS tables behind. Raises a `CompileError` for the first such call in a
  # declaration, outside anonymous functions, which run only when called.
  # `declarations` maps each declaration's name to its AST.
  def reject_in_memory_adapters!(env, declarations, nodes) do
    declarations =
      Enum.to_list(declarations) ++ Enum.map(nodes, fn {_name, fun_ast, _opts} -> {:node, fun_ast} end)

    offenders =
      for {declaration, ast} <- declarations,
          call = in_memory_adapter_call(ast, env),
          do: {declaration, call}

    case Enum.sort_by(offenders, fn {_declaration, {_module, call}} -> call_line(call, env) end) do
      [] ->
        :ok

      [{declaration, {module, call}} | _later] ->
        raise CompileError,
          file: env.file,
          line: call_line(call, env),
          description: in_memory_adapter_message(env.module, declaration, module, call)
    end
  end

  defp in_memory_adapter_call({:fn, _meta, _clauses}, _env), do: nil
  defp in_memory_adapter_call({:&, _meta, _args}, _env), do: nil

  defp in_memory_adapter_call({{:., _dot_meta, [module_ast, :new]}, _meta, args} = call, env) when is_list(args) do
    module = expand_module(module_ast, env)

    if Map.has_key?(@in_memory_adapters, module),
      do: {module, call},
      else: in_memory_adapter_call(args, env)
  end

  defp in_memory_adapter_call({form, _meta, args}, env) when is_list(args),
    do: in_memory_adapter_call(form, env) || in_memory_adapter_call(args, env)

  defp in_memory_adapter_call({left, right}, env),
    do: in_memory_adapter_call(left, env) || in_memory_adapter_call(right, env)

  defp in_memory_adapter_call(list, env) when is_list(list),
    do: Enum.find_value(list, &in_memory_adapter_call(&1, env))

  defp in_memory_adapter_call(_ast, _env), do: nil

  defp expand_module({:__aliases__, _meta, _parts} = alias_ast, env), do: Macro.expand(alias_ast, env)
  defp expand_module(module, _env) when is_atom(module), do: module
  defp expand_module(_ast, _env), do: nil

  defp call_line({_call, meta, _args}, env), do: Keyword.get(meta, :line, env.line)

  defp in_memory_adapter_message(module, declaration, adapter, call) do
    {option, noun, durable, loss} = Map.fetch!(@in_memory_adapters, adapter)

    {loss, keep} =
      if declaration == option do
        {loss,
         "pass it to each call with `#{option}: #{noun}`; or declare a function that returns it, " <>
           "such as `#{option} MyApp.Storage.#{option}()`"}
      else
        {"what it holds is lost after every call",
         "declare a function that returns it, such as `MyApp.Storage.#{option}()`"}
      end

    "the `#{declaration}` declaration creates a new, empty in-memory #{noun} with " <>
      "`#{Macro.to_string(call)}` each time #{inspect(module)} runs. Declarations are evaluated on " <>
      "every call, so #{loss}, and every call leaves new ETS tables behind. Create the #{noun} once, " <>
      "in your application's supervision tree or a test's setup, and #{keep}; or use #{durable}, " <>
      "which keeps its data in your database."
  end

  defp graph_block_entries!(caller, block),
    do: block |> block_expressions() |> Enum.flat_map(&graph_block_entry!(caller, &1))

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  defp graph_block_entry!(caller, {:state, _meta, [[do: state_block]]}) do
    for expression <- block_expressions(state_block) do
      {key, merge, opts} = state_channel_entry!(caller, expression)
      {:beam_weaver_channels, quote(do: {unquote(key), unquote(Macro.escape(merge)), unquote(opts)})}
    end
  end

  defp graph_block_entry!(caller, {kind, meta, [first, second]}) when kind in [:node, :edge, :join],
    do: graph_block_entry!(caller, {kind, meta, [first, second, []]})

  defp graph_block_entry!(_caller, {:node, _meta, [name, fun_ast, opts]}),
    do: [{:beam_weaver_nodes, quote(do: {unquote(name), unquote(Macro.escape(fun_ast)), unquote(opts)})}]

  defp graph_block_entry!(_caller, {:edge, _meta, [start_node, end_node, opts]}) do
    [
      {:beam_weaver_edges,
       quote(do: {unquote(graph_node_ast(start_node)), unquote(graph_node_ast(end_node)), unquote(opts)})}
    ]
  end

  defp graph_block_entry!(_caller, {:join, _meta, [upstream_nodes, downstream_node, opts]}) do
    [
      {:beam_weaver_joins,
       quote(do: {unquote(upstream_nodes), unquote(graph_node_ast(downstream_node)), unquote(opts)})}
    ]
  end

  defp graph_block_entry!(_caller, {:reducer, _meta, [key, reducer_ast]}),
    do: [{:beam_weaver_reducers, quote(do: {unquote(key), unquote(Macro.escape(reducer_ast))})}]

  defp graph_block_entry!(caller, other),
    do: compile_error!(caller, "unsupported graph declaration: #{Macro.to_string(other)}")

  defp state_channel_entry!(_caller, {:channel, _meta, [key]}), do: {key, :last, []}

  defp state_channel_entry!(_caller, {:channel, _meta, [key, opts]}) do
    {key, Keyword.get(opts, :merge, :last), Keyword.delete(opts, :merge)}
  end

  defp state_channel_entry!(caller, other),
    do: compile_error!(caller, "unsupported graph state declaration: #{Macro.to_string(other)}")

  defp graph_node_ast({:start, _meta, []}), do: quote(do: BeamWeaver.Graph.start())
  defp graph_node_ast({:finish, _meta, []}), do: quote(do: BeamWeaver.Graph.end_node())
  defp graph_node_ast(other), do: other
end
