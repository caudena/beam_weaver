defmodule BeamWeaver.Docs.Consumer do
  @moduledoc false
  alias BeamWeaver.TestSupport.DocSnippets, as: Snippets
  @root Path.expand("../..", __DIR__)

  def run(directory, source \\ :local) do
    root = Path.join(directory, if(source == :local, do: "consumer", else: "hex-consumer"))
    File.mkdir_p!(root)
    package = Path.join(root, "package")

    build =
      if source == :local,
        do: command(["hex.build", "--unpack", "--output", package], @root, directory, "package"),
        else: :ok

    with :ok <- build,
         :ok <- command(["new", "my_app", "--sup"], root, directory, "new") do
      app = Path.join(root, "my_app")
      mix = Path.join(app, "mix.exs")
      contents = File.read!(mix)

      dependency_blocks =
        for page <- ["docs/installation.md", "docs/storage.md"],
            block <- Snippets.blocks(page),
            block.mode == "mix",
            do: block

      Enum.each(dependency_blocks, &Snippets.evaluate_dependencies!/1)
      # Only the dependency source changes for the unreleased-package check.
      # The literal Hex requirement is verified separately after publication.
      replacement =
        if source == :local do
          "[{:beam_weaver, path: #{inspect(package)}}, {:ecto_sqlite3, \"~> 0.25\"}]"
        else
          dependency_blocks
          |> hd()
          |> Snippets.evaluate_dependencies!()
          |> Kernel.++([{:ecto_sqlite3, "~> 0.25"}])
          |> inspect()
        end

      contents = Regex.replace(~r/defp deps do\s*\[.*?\]\s*end/s, contents, "defp deps do\n#{replacement}\nend")
      File.write!(mix, contents)
      File.mkdir_p!(Path.join(app, "config"))
      config = Snippets.blocks("docs/installation.md") |> Enum.find(&(&1.mode == "config" and &1.scenario == "openai"))
      File.write!(Path.join(app, "config/runtime.exs"), config.code)
      tutorial = Snippets.blocks("docs/tutorial.md") |> Enum.map_join("\n\n", & &1.code)
      File.write!(Path.join(app, "tutorial.exs"), tutorial)

      with :ok <- command(["deps.get"], app, directory, "consumer-dependencies"),
           :ok <- command(["run", "tutorial.exs"], app, directory, "consumer-tutorial"),
           :ok <- verify_storage(app, directory) do
        %{
          file: "docs/installation.md",
          line: 1,
          status: "pass",
          method:
            if(source == :local,
              do: "fresh consumer of built Hex package: onboarding, configuration and migrations",
              else: "public Hex installation, onboarding, configuration and migrations"
            ),
          artifact: package
        }
      else
        {:error, reason} -> failure(reason)
      end
    else
      {:error, reason} -> failure(reason)
    end
  end

  defp verify_storage(app, directory) do
    # Run the documented repository, migrations and SQLite checkpoint example
    # in the consumer app, using only the package's production dependencies.
    # Do not load repository test helpers or replace the documented Repo.
    blocks =
      Snippets.blocks("docs/storage.md")
      |> Enum.take_while(&(not String.contains?(&1.code, "alias BeamWeaver.Serialization")))

    config = Enum.filter(blocks, &(&1.mode == "config")) |> Enum.map_join("\n", & &1.code)
    File.write!(Path.join(app, "config/runtime.exs"), "\n" <> config, [:append])

    examples =
      for block <- blocks, block.mode not in ["config", "mix"], do: {block.code, block.expect, block.line}

    script = """
    Enum.reduce(#{inspect(examples, limit: :infinity)}, {[], __ENV__}, fn {code, expected, line}, {bindings, env} ->
      {value, bindings, env} = Code.eval_quoted_with_env(Code.string_to_quoted!(code, line: line), bindings, env)
      if expected do
        {true, _, _} = Code.eval_quoted_with_env(
          Code.string_to_quoted!("match?(" <> expected <> ", actual)"),
          Keyword.put(bindings, :actual, value), env)
      end
      {bindings, env}
    end)
    :ok = BeamWeaver.Migrations.verify_migrated!(repo: MyApp.Repo, adapters: [:checkpoint, :memory, :cache, :vector_store])
    """

    File.write!(Path.join(app, "storage.exs"), script)

    case BeamWeaver.Docs.Services.with_services(["postgres"], fn env ->
           command(["run", "storage.exs"], app, directory, "consumer-storage", env)
         end) do
      {:blocked, reason} -> {:error, reason}
      result -> result
    end
  end

  def verify_public(directory) do
    version = Mix.Project.config()[:version]
    url = "https://hex.pm/api/packages/beam_weaver/releases/" <> version

    case Req.get(url, retry: false, receive_timeout: 15_000) do
      {:ok, %{status: 200}} ->
        run(directory, :hex)

      {:ok, %{status: 404}} ->
        %{status: "pending", reason: "Hex release #{version} is not published", checked_url: url}

      {:ok, %{status: status}} ->
        %{status: "blocked", reason: "Hex availability check returned HTTP #{status}", checked_url: url}

      {:error, error} ->
        %{status: "blocked", reason: "Hex availability check failed: #{Exception.message(error)}", checked_url: url}
    end
  end

  defp command(args, cwd, directory, name, env \\ []) do
    {output, exit} = System.cmd("mix", args, cd: cwd, env: env, stderr_to_stdout: true)
    path = Path.join(directory, name <> ".log")
    File.write!(path, output)
    if exit == 0, do: :ok, else: {:error, "#{name} exited #{exit}; see #{path}"}
  end

  defp failure(reason), do: %{file: "docs/installation.md", line: 1, status: "fail", reason: reason}
end
