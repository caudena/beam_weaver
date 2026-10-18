defmodule BeamWeaver.TestSupport.DocSnippets do
  @moduledoc false

  # Runs or compile-checks every ```elixir block in the guides (README.md and
  # the pages listed in docs/SUMMARY.md) and in selected moduledocs.
  #
  # Blocks on a page run in order like a notebook: bindings, aliases, imports
  # and requires carry from one block to the next. A block's mode is detected
  # from its content and can be set with an HTML comment on the line before the
  # fence:
  #
  #   <!-- snippet: run | compile | fragment [agent|tool|middleware] | config | mix | skip <reason> -->
  #
  #   * run      — evaluated (default)
  #   * compile  — compiled, not run: real providers, API keys, Docker, Postgres
  #   * fragment — `def`/`@attr`/DSL lines, compiled inside a throwaway module
  #   * config   — `config/*.exs` content, parsed
  #   * mix      — `mix.exs` deps/project snippets, parsed
  #   * skip     — not checked; needs a reason, at most max(1, 5%) of a page
  #
  # `MyApp.*` modules are renamed into a per-page namespace so pages can reuse
  # names, and `MyApp.Repo` maps to the test Postgres repo. Modules from a
  # compile block are visible to later compile blocks on the page. A run block
  # ending in a `#=> pattern` comment has its value matched against the pattern.

  @root Path.expand("..", __DIR__)
  @modes ~w(run compile fragment config mix skip)
  @provider_model ~r/"(openai|anthropic|google|gemini|deepseek|moonshot|kimi|xai|zai|typesafe):/
  @external_services ~r/System\.fetch_env!|Sandbox\.Docker|Checkpoint\.Ecto|Memory\.Ecto|MyApp\.Repo\b/
  @global_state ~r/Application\.put_env|System\.put_env|:persistent_term\.put|Logger\.configure/
  @fragment_uses %{
    "agent" => quote(do: use(BeamWeaver.Agent)),
    "tool" => quote(do: use(BeamWeaver.Tool)),
    "middleware" => quote(do: use(BeamWeaver.Agent.Middleware))
  }
  @ignored_warnings [
    ~r/is unused/,
    ~r/^unused (alias|import|require)/,
    ~r/^redefining module/,
    ~r/no behaviour was declared/
  ]

  # Modules whose moduledoc examples are checked like guide pages. Moduledoc
  # examples use ```elixir fences.
  @moduledoc_modules [
    BeamWeaver.Agent,
    BeamWeaver.Graph,
    BeamWeaver.Models,
    BeamWeaver.Core.Message,
    BeamWeaver.Core.ChatModel,
    BeamWeaver,
    BeamWeaver.Tool,
    BeamWeaver.Stream,
    BeamWeaver.Models.FakeChatModel,
    BeamWeaver.Models.FakeEmbeddingModel
  ]

  defmodule Block do
    @moduledoc false
    defstruct [:file, :line, :code, :mode, :arg, :expect]
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

    ["README.md" | linked] ++ Enum.map(@moduledoc_modules, &{:moduledoc, &1})
  end

  def slug("README.md"), do: "root_readme"
  def slug("docs/" <> path), do: path |> Path.rootname() |> String.replace(["/", "-"], "_")

  def slug({:moduledoc, module}),
    do: "moduledoc_" <> (module |> Module.split() |> Enum.map_join("_", &Macro.underscore/1))

  def module_suffix(page), do: page |> slug() |> Macro.camelize()

  def async?(page), do: not Enum.any?(blocks(page), &Regex.match?(@global_state, &1.code))

  ## Parsing

  def blocks({:moduledoc, module}) do
    {:docs_v1, anno, _lang, _format, %{"en" => doc}, _meta, _docs} = Code.fetch_docs(module)
    source = module.module_info(:compile)[:source] |> to_string() |> Path.relative_to(@root)
    parse_markdown(doc, source, :erl_anno.line(anno) + 1)
  end

  def blocks(path), do: path |> Path.expand(@root) |> File.read!() |> parse_markdown(path)

  @doc "The checked blocks of a markdown text; `first_line` is the file line of its first line."
  def parse_markdown(markdown, file, first_line \\ 1) do
    markdown
    |> String.split("\n")
    |> Enum.with_index(first_line)
    |> collect(file, nil, [])
  end

  defp collect([], _file, _marker, acc), do: Enum.reverse(acc)

  defp collect([{line, n} | rest], file, marker, acc) do
    cond do
      match = Regex.run(~r/^\s*<!--\s*snippet:\s*(\w+)\s*(.*?)\s*-->\s*$/, line) ->
        [_, mode, arg] = match
        collect(rest, file, {mode, arg, n}, acc)

      match = Regex.run(~r/^(\s*)```elixir\s*$/, line) ->
        [_, indent] = match
        {code, rest} = take_fence(rest, indent, [])
        marker = if match?({_, _, marker_line} when marker_line == n - 1, marker), do: marker
        collect(rest, file, nil, [block(file, n + 1, code, marker) | acc])

      match = Regex.run(~r/^(\s*)```/, line) ->
        [_, indent] = match
        {_code, rest} = take_fence(rest, indent, [])
        collect(rest, file, nil, acc)

      true ->
        collect(rest, file, marker, acc)
    end
  end

  defp take_fence([], _indent, acc), do: {Enum.reverse(acc), []}

  defp take_fence([{line, _n} | rest], indent, acc) do
    if Regex.match?(~r/^\s*```\s*$/, line),
      do: {Enum.reverse(acc), rest},
      else: take_fence(rest, indent, [String.replace_prefix(line, indent, "") | acc])
  end

  defp block(file, line, code_lines, marker) do
    code = Enum.join(code_lines, "\n")

    {mode, arg} =
      case marker do
        {mode, arg, _line} when mode in @modes -> {mode, arg}
        {mode, _arg, _marker_line} -> {"invalid", "unknown snippet mode #{inspect(mode)}"}
        nil -> detect(code)
      end

    %Block{file: file, line: line, code: code, mode: mode, arg: arg, expect: expectation(code_lines)}
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
      Regex.match?(@provider_model, code) or Regex.match?(@external_services, code) -> {"compile", ""}
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

  def run_page!(page), do: run_blocks!(blocks(page), page)

  @doc "Checks a markdown text as if it were the page `file`."
  def run_markdown!(markdown, file), do: markdown |> parse_markdown(file) |> run_blocks!(file)

  @doc """
  Whether a block on `page` defines an ExUnit test module. ExUnit runs only the
  test modules defined while the test files load (one defined later fails with
  "cannot add module ... after the suite starts running"), so
  test/docs_test.exs checks such a page as it loads, with `check_page/1`.
  """
  def defines_test_modules?(page), do: Enum.any?(blocks(page), &defines_test_module?/1)

  @doc "Runs `page` in a process of its own; returns `:ok` or `{:error, message}` instead of raising."
  def check_page(page) do
    fn ->
      try do
        run_page!(page)
      rescue
        error in ExUnit.AssertionError -> {:error, error.message}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
      end
    end
    |> Task.async()
    |> Task.await(:infinity)
  end

  defp defines_test_module?(%Block{code: code}), do: String.contains?(code, "use ExUnit.Case")

  defp run_blocks!(blocks, page) do
    check_skips!(page, blocks)
    namespace = Module.concat(DocSnippets, module_suffix(page))

    file =
      case blocks do
        [%Block{file: file} | _rest] -> file
        [] -> page_file(page)
      end

    state = %{
      binding: [],
      env: Code.env_for_eval(file: Path.expand(file, @root), line: 1),
      namespace: namespace,
      compiled: %{}
    }

    try do
      Enum.reduce(blocks, state, &check_block!/2)
    after
      # ExUnit runs a test module that a page defines on its own schedule, and
      # purging code kills the processes running it, so such a page keeps its
      # modules loaded.
      unless Enum.any?(blocks, &defines_test_module?/1), do: purge_namespace(namespace)
    end

    :ok
  end

  defp page_file({:moduledoc, module}),
    do: module.module_info(:compile)[:source] |> to_string() |> Path.relative_to(@root)

  defp page_file(path), do: path

  defp check_skips!(page, blocks) do
    skips = Enum.filter(blocks, &(&1.mode == "skip"))
    cap = max(1, div(length(blocks) * 5, 100))

    for %Block{arg: "", file: file, line: line} <- skips, do: raise("#{file}:#{line}: snippet skip needs a reason")
    if length(skips) > cap, do: raise("#{inspect(page)}: #{length(skips)} skipped blocks exceed the cap of #{cap}")
  end

  defp check_block!(%Block{mode: "skip"}, state), do: state
  defp check_block!(%Block{mode: "invalid", arg: message} = block, _state), do: fail!(block, message)

  defp check_block!(%Block{mode: mode} = block, state) when mode in ["config", "mix"] do
    _quoted = quote!(block)
    state
  end

  defp check_block!(%Block{mode: "run"} = block, state) do
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
        state

      {:error, message} ->
        fail!(block, if(output == "", do: message, else: message <> "\n  output:\n" <> output))
    end
  end

  defp check_block!(%Block{mode: "compile"} = block, state) do
    compile_ns = Module.concat(state.namespace, "Compile#{block.line}")
    quoted = quote!(block)

    own =
      for {:defmodule, _, [{:__aliases__, _, [:MyApp | rest]} | _]} <- top_level(quoted),
          into: %{},
          do: {rest, compile_ns}

    compiled = Map.merge(state.compiled, own)
    forms = quoted |> rename(state.namespace, compiled) |> top_level()

    {kept, rest} =
      Enum.split_with(forms, &match?({form, _, _} when form in [:defmodule, :alias, :import, :require], &1))

    params = for {name, _value} <- state.binding, do: Macro.var(name, nil)

    wrapper =
      quote do
        defmodule unquote(Module.concat(compile_ns, Snippet)) do
          def run(unquote_splicing(params)), do: unquote({:__block__, [], rest ++ [:ok]})
        end
      end

    compile!(block, {:__block__, [], env_forms(state.env) ++ kept ++ [wrapper]})
    %{state | compiled: compiled}
  end

  defp check_block!(%Block{mode: "fragment"} = block, state) do
    body = block |> quote!() |> rename(state.namespace, state.compiled)

    module =
      quote do
        defmodule unquote(Module.concat(state.namespace, "Fragment#{block.line}")) do
          unquote(Map.get(@fragment_uses, block.arg))
          unquote(fragment_model(block.arg, body))
          unquote(body)
        end
      end

    compile!(block, {:__block__, [], env_forms(state.env) ++ [module]})
    state
  end

  # Every agent module declares a model; an agent fragment without one gets
  # the scripted one.
  defp fragment_model("agent", body) do
    unless Enum.any?(top_level(body), &match?({:model, _meta, [_ | _]}, &1)), do: quote(do: model("fake:chat"))
  end

  defp fragment_model(_arg, _body), do: nil

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

  defp compile!(block, quoted) do
    case checked(fn -> Code.compile_quoted(quoted, Path.expand(block.file, @root)) end) do
      {:ok, _modules} -> :ok
      {:error, message} -> fail!(block, message)
    end
  end

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
      {:__aliases__, meta, [:MyApp, :Repo]} ->
        {:__aliases__, meta, [:BeamWeaver, :Test, :PostgresRepo]}

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

  @default_requires Code.env_for_eval([]).requires

  defp env_forms(env) do
    aliases = for {as, module} <- env.aliases, do: quote(do: alias(unquote(module), as: unquote(as)))
    requires = for module <- env.requires -- @default_requires, do: quote(do: require(unquote(module)))

    imports =
      for {module, names} <- Enum.group_by(env.functions ++ env.macros, &elem(&1, 0), &elem(&1, 1)),
          module not in [Kernel, Kernel.SpecialForms],
          do: quote(do: import(unquote(module), only: unquote(List.flatten(names))))

    requires ++ aliases ++ imports
  end

  defp purge_modules(modules) do
    for module <- modules, :code.is_loaded(module) != false do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end
  end

  defp purge_namespace(namespace) do
    prefix = Atom.to_string(namespace) <> "."

    for {module, _file} <- :code.all_loaded(), String.starts_with?(Atom.to_string(module), prefix) do
      module
    end
    |> purge_modules()
  end
end
