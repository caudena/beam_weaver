defmodule BeamWeaver.MixProject do
  use Mix.Project

  def project do
    [
      app: :beam_weaver,
      version: "1.0.0",
      description:
        "Elixir-native LangChain, LangGraph, and DeepAgents for traceable LLM apps: OTP workflows, tools, memory, human-in-the-loop, streaming, custom clients/adapters, minimal deps, and WeaveScope tracing.",
      source_url: "https://github.com/caudena/beam_weaver",
      homepage_url: "https://github.com/caudena/beam_weaver",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      package: package(),
      aliases: aliases(),
      docs: &docs/0
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :logger, :ssl],
      mod: {BeamWeaver.Application, []}
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.20"},
      {:ecto_sqlite3, "~> 0.25.0", optional: true},
      {:req, "~> 0.7.2"},
      {:finch, "~> 0.24.0"},
      {:idna, "~> 7.1"},
      {:fastest_tiktoken, "~> 0.1.1"},
      {:telemetry, "~> 1.2"},
      {:yamerl, "~> 0.10.0"}
    ]
  end

  # Old guide names, renamed or merged into other pages.
  @doc_redirects %{
    "adapters" => "storage",
    "agent_harness" => "deep_agents",
    "async_subagents" => "subagents",
    "compaction" => "compaction_engine",
    "context_engineering" => "context_management",
    "core" => "models",
    "custom_middleware" => "middleware",
    "customization" => "deep_agents",
    "deep_agents_quickstart" => "deep_agents",
    "event_streaming" => "streaming",
    "fault_tolerance" => "durable_execution",
    "getting_started" => "quickstart",
    "graph" => "graphs",
    "memory" => "long_term_memory",
    "partners" => "providers",
    "permissions" => "filesystem",
    "persistence" => "checkpoints",
    "prebuilt_middleware" => "builtin_middleware",
    "prompt_caching" => "caching",
    "prompts_parsers" => "prompts_and_parsers",
    "replay" => "testing",
    "runtime" => "runtime_context",
    "semantic_dsl" => "agents",
    "thinking_in_beamweaver" => "graphs",
    "time_travel" => "checkpoints",
    "workflows_and_agents" => "workflow_patterns"
  }

  # Guides come from docs/SUMMARY.md, the GitBook table of contents, so both
  # sites share one navigation.
  defp docs do
    {extras, groups} = summary_extras()

    [
      main: "readme",
      source_ref: "master",
      source_url: "https://github.com/caudena/beam_weaver",
      extras: ["README.md" | extras] ++ ["CHANGELOG.md"],
      groups_for_extras: [{"Overview", ["README.md"]} | groups] ++ [{"Project", ["CHANGELOG.md"]}],
      groups_for_modules: eval_docs_file("scripts/docs/module_groups.exs", []),
      assets: %{"docs/assets" => "assets"},
      redirects: @doc_redirects
    ]
  end

  # `{extras, groups_for_extras}` in SUMMARY.md order, one group per section.
  defp summary_extras do
    path = Path.join(__DIR__, "docs/SUMMARY.md")
    lines = if File.exists?(path), do: path |> File.read!() |> String.split("\n"), else: []

    {sections, _current} =
      Enum.reduce(lines, {[], "Guides"}, fn line, {sections, current} ->
        cond do
          match = Regex.run(~r/^##\s+(.+?)\s*$/, line) ->
            {sections, Enum.at(match, 1)}

          match = Regex.run(~r/^\s*[*-]\s+\[[^\]]*\]\(([^)#\s]+\.md)\)/, line) ->
            page = Path.join("docs", Enum.at(match, 1))
            if page == "docs/README.md", do: {sections, current}, else: {[{current, page} | sections], current}

          true ->
            {sections, current}
        end
      end)

    sections = Enum.reverse(sections)

    groups =
      sections
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.map(&{elem(hd(&1), 0), Enum.map(&1, fn {_section, page} -> page end)})

    {Enum.map(sections, &elem(&1, 1)), groups}
  end

  defp eval_docs_file(file, default) do
    path = Path.join(__DIR__, file)
    if File.exists?(path), do: path |> Code.eval_file() |> elem(0), else: default
  end

  defp aliases do
    [
      "docs.providers": ["run --no-start scripts/docs/provider_tables.exs --write"],
      "examples.live": ["run --no-start scripts/examples/run.exs"]
    ]
  end

  defp package do
    [
      name: "beam_weaver",
      files: [
        ".formatter.exs",
        "CHANGELOG.md",
        "LICENSE",
        "README.md",
        "docs",
        "examples",
        "lib",
        "mix.exs",
        "priv/openai"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://github.com/caudena/beam_weaver/blob/master/CHANGELOG.md",
        "GitHub" => "https://github.com/caudena/beam_weaver"
      }
    ]
  end
end
