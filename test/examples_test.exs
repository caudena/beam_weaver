defmodule BeamWeaver.ExamplesTest do
  # Every script in examples/ compiles without warnings, and the offline ones
  # run. Live scripts run against real providers with `mix examples.live`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @root Path.expand("..", __DIR__)
  @manifest @root |> Path.join("scripts/examples/manifest.exs") |> Code.eval_file() |> elem(0)
  @scripts Keyword.fetch!(@manifest, :scripts)
  @support Keyword.fetch!(@manifest, :support)
  @ignored_warnings [~r/is unused/, ~r/^unused (alias|import|require)/]

  test "the manifest lists every script in examples/" do
    on_disk = for path <- Path.wildcard(Path.join(@root, "examples/**/*.exs")), do: Path.relative_to(path, @root)
    listed = Enum.map(@scripts, &elem(&1, 0)) ++ @support

    assert on_disk -- listed == [], "add these scripts to scripts/examples/manifest.exs"
    assert listed -- on_disk == [], "these manifest entries have no script"
  end

  for {script, opts} <- @scripts do
    @script script

    if opts[:run] == :offline or Keyword.has_key?(opts, :offline_args) do
      @args Keyword.get(opts, :offline_args, [])

      test "#{script} runs offline" do
        run_script!(@script, @args)
      end
    else
      test "#{script} compiles" do
        compile_script!(@script)
      end
    end
  end

  # Top-level `Code.require_file/2` calls run first; `alias`, `import`,
  # `require` and `defmodule` forms compile in order, and the remaining
  # top-level code compiles as the body of a function.
  defp compile_script!(script) do
    path = Path.join(@root, script)
    forms = path |> File.read!() |> Code.string_to_quoted!(file: path) |> top_level()

    {requires, forms} =
      Enum.split_with(forms, &match?({{:., _, [{:__aliases__, _, [:Code]}, :require_file]}, _, _}, &1))

    Enum.each(requires, &Code.eval_quoted(&1, [], file: path))

    {kept, body} =
      Enum.split_with(forms, &match?({form, _, _} when form in [:alias, :import, :require, :defmodule], &1))

    wrapper = Module.concat(__MODULE__, "Script#{:erlang.phash2(script)}")

    quoted =
      quote do
        unquote_splicing(kept)

        defmodule unquote(wrapper) do
          def run, do: unquote({:__block__, [], body ++ [:ok]})
        end
      end

    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {:ok, Code.compile_quoted(quoted, path)}
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    problems = diagnostic_problems(script, diagnostics)

    case result do
      {:ok, modules} -> purge(Enum.map(modules, &elem(&1, 0)))
      {:error, message} -> flunk(Enum.join(problems ++ [message], "\n"))
    end

    assert problems == [], Enum.join(problems, "\n")
  end

  defp run_script!(script, args) do
    path = Path.join(@root, script)
    argv = System.argv()

    capture_io(fn ->
      try do
        System.argv(args)
        {_result, diagnostics} = Code.with_diagnostics(fn -> Code.eval_file(path) end)
        assert diagnostic_problems(script, diagnostics) == []
      after
        System.argv(argv)
        purge(for {module, _file} <- :code.all_loaded(), source(module) == path, do: module)
      end
    end)
  end

  defp diagnostic_problems(script, diagnostics) do
    for diagnostic <- diagnostics,
        diagnostic.severity == :error or not Enum.any?(@ignored_warnings, &Regex.match?(&1, diagnostic.message)),
        do: "#{script}:#{line(diagnostic.position)}: #{diagnostic.severity}: #{diagnostic.message}"
  end

  defp source(module) do
    module.module_info(:compile)[:source] |> to_string()
  rescue
    _error -> nil
  end

  defp top_level({:__block__, _meta, forms}), do: forms
  defp top_level(form), do: [form]

  defp line({line, _column}), do: line
  defp line(line), do: line

  defp purge(modules) do
    for module <- modules do
      :code.purge(module)
      :code.delete(module)
    end
  end
end
