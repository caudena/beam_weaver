Code.require_file("../scripts/docs/credentials.exs", __DIR__)
Code.require_file("../scripts/docs/scenarios.exs", __DIR__)

defmodule BeamWeaver.TestSupport.DocSnippets do
  @moduledoc false

  # Markdown is the source of executable examples, including public API docs.
  # Earmark distinguishes indented code from list continuation paragraphs.
  #
  # `mix docs.verify` executes each scenario in a fresh VM, preserving the
  # printed MyApp module names and enabling combined prerequisites together.
  # Only that runner reports per-block execution status.
  #
  # Consecutive blocks share bindings within a scenario. Scenario boundaries
  # and execution overrides live in scripts/docs/scenarios.exs.
  # Modes: run, live, postgres, docker, config, mix and fragment.
  # The strict verifier rejects incomplete fragments; dependency
  # snippets require the separate fresh-consumer package check.
  # A trailing `#=> pattern` asserts the last expression's result.
  #
  # The runner uses source names in separate OS processes and never supplies
  # an implicit application repository.

  @root Path.expand("..", __DIR__)
  @services ~w(live postgres docker)
  @live ~r/"(openai|anthropic|google|gemini|deepseek|moonshot|kimi|xai|zai|typesafe):|System\.(?:get_env|fetch_env!)\("(?:OPENAI|ANTHROPIC|GOOGLE|GEMINI|XAI|MOONSHOT|KIMI|ZAI|DEEPSEEK|TYPESAFE)_/
  @postgres ~r/Checkpoint\.Ecto|Memory\.Ecto|Cache\.Ecto|VectorStore\.EctoPostgres|MyApp\.Repo\b/
  @docker ~r/Sandbox\.Docker/
  # The API key each provider's live examples read, from the environment or .env.

  @ignored_warnings [
    ~r/is unused/,
    ~r/^unused (alias|import|require)/,
    ~r/^redefining module/,
    ~r/no behaviour was declared/
  ]

  defmodule Block do
    @moduledoc false
    defstruct [
      :file,
      :line,
      :code,
      :mode,
      :arg,
      :expect,
      origin: :fenced,
      source: nil,
      scenario: "default",
      requirements: [],
      providers: []
    ]
  end

  ## Pages

  @doc "Checked pages: paths relative to the repo root, then `{:moduledoc, module}` entries."
  def pages do
    summary = File.read!(Path.join(@root, "docs/SUMMARY.md"))

    linked =
      for [_, link] <- Regex.scan(~r/\]\(([^)#\s]+\.md)\)/, summary),
          path = Path.join("docs", link),
          File.exists?(Path.join(@root, path)),
          uniq: true,
          do: path

    ["README.md" | linked] ++ api_pages()
  end

  # Discover public API documentation rather than keeping a hand-picked list.
  def api_pages do
    Application.load(:beam_weaver)

    for module <- Application.spec(:beam_weaver, :modules) |> Enum.sort(),
        {:docs_v1, _, _, _, moduledoc, _, entries} <- [Code.fetch_docs(module)],
        moduledoc != :hidden,
        page <- [{:moduledoc, module} | for({key, _, _, %{"en" => _}, _} <- entries, do: {:doc, module, key})],
        blocks(page) != [],
        do: page
  end

  def all_pages,
    do:
      (pages() ++ Path.wildcard(Path.join(@root, "examples/**/README.md")))
      |> Enum.map(fn p -> if is_binary(p), do: Path.relative_to(p, @root), else: p end)

  def slug({:doc, module, {kind, name, arity}}),
    do: (slug({:moduledoc, module}) <> "_#{kind}_#{name}_#{arity}") |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

  def slug("README.md"), do: "root_readme"
  def slug("docs/" <> path), do: path |> Path.rootname() |> String.replace(["/", "-"], "_")

  def slug({:moduledoc, module}),
    do: "moduledoc_" <> (module |> Module.split() |> Enum.map_join("_", &Macro.underscore/1))

  def slug(path) when is_binary(path), do: path |> Path.rootname() |> String.replace(["/", "-", "."], "_")

  @doc """
  Configures each provider's API key for the live run, from the environment or
  the repository's `.env` (which never overrides a variable already set).
  """
  defdelegate configure_live_providers!(), to: BeamWeaver.Docs.Credentials

  ## Parsing

  def blocks({:moduledoc, module}) do
    case Code.fetch_docs(module) do
      {:docs_v1, anno, _, _, %{"en" => doc}, _, _} -> parse_api(doc, module, anno)
      _ -> []
    end
  end

  def blocks({:doc, module, key}) do
    {:docs_v1, _, _, _, _, _, entries} = Code.fetch_docs(module)
    {^key, anno, _, %{"en" => doc}, _} = List.keyfind(entries, key, 0)
    parse_api(doc, module, anno)
  end

  def blocks(path) do
    absolute = Path.expand(path, @root)
    file = Path.relative_to(absolute, @root)
    markdown = File.read!(absolute)
    BeamWeaver.Docs.Scenarios.annotate(markdown, file, parse_markdown(markdown, file))
  end

  defp parse_api(doc, module, anno) do
    source = module.module_info(:compile)[:source] |> to_string() |> Path.relative_to(@root)
    parse_markdown(doc, source, :erl_anno.line(anno) + 1)
  end

  @doc "The checked blocks of a markdown text; `first_line` is the file line of its first line."
  def parse_markdown(markdown, file, first_line \\ 1) do
    lines = markdown |> String.split("\n") |> Enum.with_index(first_line)

    rendered = rendered_code_blocks(markdown)

    lines
    |> collect(file, [], rendered)
    |> Enum.filter(fn block -> block.origin != :indented or String.trim(block.source) in rendered end)
  end

  defp rendered_code_blocks(markdown) do
    {_status, ast, _messages} = EarmarkParser.as_ast(markdown)
    collect_rendered_code(ast)
  end

  defp collect_rendered_code(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &collect_rendered_code/1)

  defp collect_rendered_code({"pre", _, [{"code", _, text, _}], _}),
    do: [text |> IO.iodata_to_binary() |> String.trim()]

  defp collect_rendered_code({_tag, _, children, _}), do: collect_rendered_code(children)
  defp collect_rendered_code(_text), do: []

  defp collect([], _file, acc, _rendered), do: Enum.reverse(acc)

  defp collect([{line, n} | rest], file, acc, rendered) do
    cond do
      match = Regex.run(~r/^(\s*)```(?:elixir|iex)\s*$/, line) ->
        [_, indent] = match
        {code, rest} = take_fence(rest, indent, [])
        collect(rest, file, [block(file, n + 1, iex_code(code)) | acc], rendered)

      String.starts_with?(line, "    ") and String.trim(line) != "" ->
        {code, rest} = take_indented([{line, n} | rest], [])

        if String.trim(Enum.join(code, "\n")) in rendered do
          entry = %{block(file, n, iex_code(code)) | origin: :indented, source: Enum.join(code, "\n")}
          collect(rest, file, [entry | acc], rendered)
        else
          collect(rest, file, acc, rendered)
        end

      match = Regex.run(~r/^(\s*)```/, line) ->
        [_, indent] = match
        {_code, rest} = take_fence(rest, indent, [])
        collect(rest, file, acc, rendered)

      true ->
        collect(rest, file, acc, rendered)
    end
  end

  defp take_indented([{line, n} | rest], acc) do
    if String.starts_with?(line, "    ") or String.trim(line) == "" do
      take_indented(rest, [String.replace_prefix(line, "    ", "") | acc])
    else
      {Enum.reverse(acc), [{line, n} | rest]}
    end
  end

  defp take_indented([], acc), do: {Enum.reverse(acc), []}

  defp iex_code(lines) do
    if Enum.any?(lines, &String.starts_with?(&1, "iex>")) do
      lines
      |> Enum.reduce({[], [], []}, fn line, {acc, code, output} ->
        cond do
          String.starts_with?(line, "iex>") ->
            acc = acc ++ iex_assertion(code, output)
            {acc, [String.replace_prefix(line, "iex> ", "")], []}

          String.starts_with?(line, "...>") ->
            {acc, code ++ [String.replace_prefix(line, "...> ", "")], output}

          true ->
            {acc, code, output ++ [line]}
        end
      end)
      |> then(fn {acc, code, output} -> acc ++ iex_assertion(code, output) end)
    else
      lines
    end
  end

  defp iex_assertion([], _output), do: []

  defp iex_assertion(code, output) do
    output = Enum.join(output, "\n") |> String.trim()
    if output == "", do: code, else: ["true = (" <> Enum.join(code, "\n") <> ") == (" <> output <> ")"]
  end

  defp take_fence([], _indent, acc), do: {Enum.reverse(acc), []}

  defp take_fence([{line, _n} | rest], indent, acc) do
    if Regex.match?(~r/^\s*```\s*$/, line),
      do: {Enum.reverse(acc), rest},
      else: take_fence(rest, indent, [String.replace_prefix(line, indent, "") | acc])
  end

  defp block(file, line, code_lines) do
    code = Enum.join(code_lines, "\n")

    {mode, arg} = detect(code)

    requirements =
      if(Regex.match?(@live, code), do: ["live"], else: []) ++
        if(Regex.match?(@postgres, code), do: ["postgres"], else: []) ++
        if(Regex.match?(@docker, code), do: ["docker"], else: []) ++
        if mode in @services, do: [mode], else: []

    providers =
      for [_, provider] <- Regex.scan(~r/"(openai|anthropic|google|deepseek|moonshot|xai|zai|typesafe):/, code),
          uniq: true,
          do: provider

    %Block{
      file: file,
      line: line,
      code: code,
      mode: mode,
      arg: arg,
      expect: expectation(code_lines),
      requirements: Enum.uniq(requirements),
      providers: providers
    }
  end

  defp detect(code) do
    forms =
      case Code.string_to_quoted(code) do
        {:ok, quoted} -> top_level(quoted)
        {:error, _reason} -> []
      end

    cond do
      Regex.match?(~r/^\s*(import Config\b|config\s+:)/m, code) -> {"config", ""}
      mix_snippet?(forms) -> {"mix", ""}
      Enum.any?(forms, &agent_dsl_call?/1) -> {"fragment", "agent"}
      Enum.any?(forms, &match?({form, _, _} when form in [:def, :defp, :defmacro, :@, :use], &1)) -> {"fragment", ""}
      Regex.match?(@docker, code) -> {"docker", ""}
      Regex.match?(@postgres, code) -> {"postgres", ""}
      Regex.match?(@live, code) -> {"live", ""}
      true -> {"run", ""}
    end
  end

  defp mix_snippet?(forms) do
    Enum.any?(
      forms,
      &match?({def, _, [{name, _, _} | _]} when def in [:def, :defp] and name in [:deps, :project, :application], &1)
    ) and
      not Enum.any?(forms, &match?({:defmodule, _, _}, &1))
  end

  defp agent_dsl_call?({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)} in BeamWeaver.Agent.DSL.imports()

  defp agent_dsl_call?(_form), do: false

  # `#=> pattern` after the last expression, optionally continued on more
  # comment lines.
  defp expectation(lines) do
    lines = lines |> Enum.reverse() |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()

    case Enum.find_index(Enum.reverse(lines), &String.starts_with?(String.trim_leading(&1), "#=>")) do
      nil ->
        nil

      from_end ->
        [first | more] = tail = Enum.take(lines, -(from_end + 1))

        if Enum.all?(tail, &String.starts_with?(String.trim_leading(&1), "#")) do
          [String.replace(first, ~r/^\s*#=>\s?/, "") | Enum.map(more, &String.replace(&1, ~r/^\s*#\s?/, ""))]
          |> Enum.join("\n")
        end
    end
  end

  ## Running

  @doc "Executes a single scenario and accounts for every block, including dependency failures."
  def verify_blocks(blocks, page, services, opts \\ []) do
    # The verifier runs this in a fresh VM: keep the printed module names.
    namespace = MyApp

    state = %{
      binding: [],
      env: Code.env_for_eval(file: Path.expand(page_file(page), @root), line: 1),
      namespace: namespace,
      compiled: %{},
      services: Enum.map(services, &to_string/1)
    }

    {results, _state, _failed} =
      Enum.reduce(blocks, {[], state, false}, fn block, {results, state, failed} ->
        base = %{
          file: block.file,
          line: block.line,
          code: block.code,
          models:
            Regex.scan(~r/"((?:openai|google|anthropic|xai|deepseek|moonshot|zai|typesafe):[\w.-]+)"/, block.code)
            |> Enum.map(&Enum.at(&1, 1))
            |> Enum.uniq(),
          scenario: block.scenario,
          mode: block.mode,
          requirements: block.requirements,
          providers: block.providers
        }

        cond do
          failed ->
            {results ++ [Map.merge(base, %{status: "blocked", reason: "An earlier block in this scenario failed"})],
             state, true}

          missing = Enum.find(block.requirements, &(&1 not in state.services)) ->
            {results ++ [Map.merge(base, %{status: "blocked", reason: "Missing requirement: #{missing}"})], state, true}

          block.mode in ["compile", "fragment"] or (block.mode == "mix" and opts[:package_verified] != true) ->
            {results ++
               [
                 Map.merge(base, %{
                   status: "blocked",
                   reason: "#{block.mode} is not an executable example; supply a complete scenario"
                 })
               ], state, true}

          true ->
            try do
              next =
                case block.mode do
                  "config" ->
                    apply_config!(block, state)

                  "mix" ->
                    evaluate_dependencies!(block)
                    state

                  _ ->
                    run_block!(block, state)
                end

              {results ++ [Map.merge(base, %{status: "pass", method: "executed"})], next, false}
            rescue
              error -> {results ++ [Map.merge(base, %{status: "fail", reason: Exception.message(error)})], state, true}
            catch
              kind, reason ->
                {results ++ [Map.merge(base, %{status: "fail", reason: Exception.format_banner(kind, reason)})], state,
                 true}
            end
        end
      end)

    results
  end

  def evaluate_dependencies!(block) do
    module = Module.concat(__MODULE__, "Dependencies#{System.unique_integer([:positive])}")
    Code.compile_quoted(quote(do: defmodule(unquote(module), do: unquote(quote!(block)))))
    deps = apply(module, :deps, [])

    unless Enum.any?(deps, &match?({:beam_weaver, _}, &1)),
      do: fail!(block, "dependency example does not install BeamWeaver")

    deps
  end

  defp apply_config!(block, state) do
    check_config!(block)
    quoted = block |> quote!() |> rename(state.namespace, %{})

    config =
      Config.Reader.eval!(Path.expand(block.file, @root), "import Config\n" <> Macro.to_string(quoted), env: :prod)

    Application.put_all_env(config)
    state
  end

  def provider_keys, do: BeamWeaver.Docs.Credentials.keys()

  defdelegate missing_credentials(providers), to: BeamWeaver.Docs.Credentials

  defp page_file({:doc, module, _key}), do: page_file({:moduledoc, module})

  defp page_file({:moduledoc, module}),
    do: module.module_info(:compile)[:source] |> to_string() |> Path.relative_to(@root)

  defp page_file(path), do: path

  defp run_block!(block, state) do
    quoted = block |> quote!() |> rename(state.namespace, state.compiled)
    defined = defined_modules(quoted)
    purge_modules(defined)

    {result, output} =
      ExUnit.CaptureIO.with_io(fn ->
        checked(fn -> Code.eval_quoted_with_env(quoted, state.binding, state.env) end)
      end)

    case result do
      {:ok, {value, binding, env}} ->
        state = %{state | binding: binding, env: env, compiled: Map.drop(state.compiled, local_names(defined, state))}
        if block.expect, do: check_expect!(block, value, state)

        if match?({:error, _}, value) and is_nil(block.expect) and not expected_error_match?(quoted),
          do: fail!(block, "unasserted error result: #{inspect(value)}")

        state

      {:error, message} ->
        fail!(block, if(output == "", do: message, else: message <> "\n  output:\n" <> output))
    end
  end

  defp expected_error_match?(quoted) do
    case List.last(top_level(quoted)) do
      {:=, _, [{:error, _}, _]} -> true
      {:=, _, [{:{}, _, [:error | _]}, _]} -> true
      _ -> false
    end
  end

  defp check_config!(block) do
    quoted =
      Macro.prewalk(quote!(block), fn
        {{:., _, [{:__aliases__, _, [:System]}, fun]}, _, [_ | _]} when fun in [:get_env, :fetch_env!] -> "doc-value"
        form -> form
      end)

    contents = "import Config\n" <> Macro.to_string(quoted)

    config =
      case checked(fn -> Config.Reader.eval!(Path.expand(block.file, @root), contents, env: :prod) end) do
        {:ok, config} -> config
        {:error, message} -> fail!(block, message)
      end

    paths = config_paths()

    unknown =
      for {key, value} <- Keyword.get(config, :beam_weaver, []), path <- unknown_paths(key, value, paths), do: path

    if unknown != [],
      do: fail!(block, "config sets keys BeamWeaver doesn't read: #{Enum.map_join(unknown, ", ", &inspect/1)}")
  end

  defp unknown_paths(key, value, paths) do
    case Map.fetch(paths, key) do
      :error -> [[key]]
      {:ok, :any} -> []
      {:ok, keys} -> if Keyword.keyword?(value), do: for({sub, _} <- value, sub not in keys, do: [key, sub]), else: []
    end
  end

  # The config paths under `:beam_weaver` that lib/ reads: literal paths given
  # to `Config.get/option/flag?` and `configured_url`, whole groups read with
  # `Config.group/1`, and `:base_url` for each provider (its endpoints are
  # built from it).
  defp config_paths do
    with nil <- :persistent_term.get({__MODULE__, :config_paths}, nil) do
      sources = for file <- Path.wildcard(Path.join(@root, "lib/**/*.ex")), do: File.read!(file)
      literal = ~r/(?:Config\.(?:get|option|flag\?)\((?:\w+, :\w+, )?|configured_url\(\w+, :\w+, )\[(:\w+(?:, :\w+)*)\]/

      found =
        for(source <- sources, [_, list] <- Regex.scan(literal, source), do: atoms(list)) ++
          for(source <- sources, [_, key] <- Regex.scan(~r/Config\.group\(:(\w+)/, source), do: [String.to_atom(key)])

      found =
        found ++
          for source <- sources,
              [_, key] <- Regex.scan(~r/setting!\(opts, :\w+, :(\w+),/, source),
              do: [:transport, String.to_atom(key)]

      paths =
        Enum.reduce(found, %{}, fn
          [key], acc ->
            Map.put(acc, key, :any)

          [key, sub | _], acc ->
            Map.update(acc, key, [sub], fn
              :any -> :any
              keys -> [sub | keys]
            end)
        end)
        |> Map.new(fn
          {key, keys} when is_list(keys) -> {key, if(:api_key in keys, do: [:base_url | keys], else: keys)}
          entry -> entry
        end)

      :persistent_term.put({__MODULE__, :config_paths}, paths)
      paths
    end
  end

  defp atoms(list), do: for(name <- String.split(list, ", "), do: name |> String.trim_leading(":") |> String.to_atom())

  defp quote!(%Block{} = block) do
    case Code.string_to_quoted(block.code, file: block.file, line: block.line, columns: true) do
      {:ok, quoted} ->
        quoted

      {:error, {meta, message, token}} ->
        fail!(block, "syntax error on line #{meta[:line]}: #{message_text(message)}#{token}")
    end
  end

  defp message_text({prefix, suffix}), do: prefix <> suffix
  defp message_text(message), do: message

  # Runs `fun`, turning raised errors and compiler errors or warnings into
  # `{:error, message}`.
  defp checked(fun) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, fun.()}
        rescue
          error -> {:error, format_error(:error, error, __STACKTRACE__)}
        catch
          kind, reason -> {:error, format_error(kind, reason, __STACKTRACE__)}
        end
      end)

    problems =
      for diagnostic <- diagnostics,
          diagnostic.severity == :error or not Enum.any?(@ignored_warnings, &Regex.match?(&1, diagnostic.message)),
          do: "#{diagnostic.severity} on line #{line(diagnostic.position)}: #{diagnostic.message}"

    case {result, problems} do
      {{:ok, value}, []} -> {:ok, value}
      {{:ok, _value}, problems} -> {:error, Enum.join(problems, "\n")}
      {{:error, message}, problems} -> {:error, Enum.join(problems ++ [message], "\n")}
    end
  end

  defp format_error(kind, reason, stacktrace) do
    frames = Enum.reject(stacktrace, fn {module, _fun, _arity, _location} -> module == __MODULE__ end)
    Exception.format_banner(kind, reason, stacktrace) <> "\n" <> Exception.format_stacktrace(Enum.take(frames, 6))
  end

  defp line({line, _column}), do: line
  defp line(line), do: line

  defp check_expect!(block, value, state) do
    pattern =
      block.expect
      |> Code.string_to_quoted!(file: block.file, line: block.line)
      |> rename(state.namespace, state.compiled)

    value = unrename(value, state.namespace)
    match = quote(do: match?(unquote(pattern), var!(snippet_result__)))

    {matched?, _binding, _env} =
      Code.eval_quoted_with_env(match, [{:snippet_result__, value} | state.binding], state.env)

    unless matched?,
      do: fail!(block, "result does not match `#=> #{block.expect}`\n  got: #{inspect(value, pretty: true, limit: 50)}")
  end

  defp fail!(%Block{file: file, line: line, mode: mode}, message) do
    raise ExUnit.AssertionError, message: "#{file}:#{line} (#{mode} snippet) #{message}"
  end

  ## Namespacing

  # `compiled` maps `MyApp`-relative name parts to the compile namespace that
  # defines them.
  defp rename(quoted, namespace, compiled) do
    page_parts = alias_parts(namespace)

    Macro.prewalk(quoted, fn
      {:__aliases__, meta, [:MyApp | rest]} ->
        case Enum.find(compiled, fn {parts, _ns} -> List.starts_with?(rest, parts) end) do
          {_parts, compile_ns} -> {:__aliases__, meta, alias_parts(compile_ns) ++ rest}
          nil -> {:__aliases__, meta, page_parts ++ rest}
        end

      other ->
        other
    end)
  end

  defp alias_parts(module), do: module |> Module.split() |> Enum.map(&String.to_atom/1)

  # `MyApp`-relative parts of modules a run block defined in the page namespace.
  defp local_names(modules, state) do
    prefix = alias_parts(state.namespace)

    for module <- modules,
        parts = alias_parts(module),
        List.starts_with?(parts, prefix),
        do: Enum.drop(parts, length(prefix))
  end

  defp unrename(value, namespace) do
    prefix = inspect(namespace) <> "."

    walk(value, fn
      string when is_binary(string) -> String.replace(string, prefix, "MyApp.")
      other -> other
    end)
  end

  defp walk(%_{} = struct, fun), do: struct |> Map.from_struct() |> walk(fun) |> then(&struct(struct.__struct__, &1))
  defp walk(map, fun) when is_map(map), do: Map.new(map, fn {key, value} -> {walk(key, fun), walk(value, fun)} end)
  defp walk(list, fun) when is_list(list), do: Enum.map(list, &walk(&1, fun))
  defp walk(tuple, fun) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> walk(fun) |> List.to_tuple()
  defp walk(other, fun), do: fun.(other)

  defp top_level({:__block__, _meta, forms}), do: forms
  defp top_level(form), do: [form]

  # Modules a block defines, nested ones included.
  defp defined_modules(quoted, parent \\ nil) do
    quoted
    |> top_level()
    |> Enum.flat_map(fn
      {:defmodule, _meta, [{:__aliases__, _alias_meta, parts}, [do: body]]} ->
        name = if parent, do: Module.concat([parent | parts]), else: Module.concat(parts)
        [name | defined_modules(body, name)]

      _other ->
        []
    end)
  end

  defp purge_modules(modules) do
    for module <- modules, :code.is_loaded(module) != false do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end
  end
end
