defmodule BeamWeaver.Docs.Scenarios do
  @moduledoc false

  # Reader-facing Markdown contains only prose and examples. Execution settings
  # live here; selectors must match exactly once so documentation edits cannot
  # silently discard a scenario or change how its examples are checked.
  @scenarios %{
    "README.md" => [{"## Your first agent", "first-agent", ["live"]}],
    "docs/installation.md" => [
      {"## Configure OpenAI", "openai", ["live"]},
      {"## Use Google instead", "google", ["live"]},
      {"## Check installation", "initialize", ["live"]}
    ],
    "docs/quickstart.md" => [
      {"## Define an agent", "openai", ["live"]},
      {"## Use Google", "google", ["live"]}
    ],
    "docs/tutorial.md" => [{"## Define the action", "support-agent", ["live"]}],
    "docs/configuration.md" => [
      {"## Configuration and call options", "openai", ["live"]},
      {"## Tracing", "local-tracing", []}
    ]
  }

  @overrides %{
    "docs/retrieval.md" => [
      {"TextSplitter.split_url(TextSplitter.html_headers(), \"https://www.w3.org/\"", "live"}
    ],
    "docs/storage.md" => [{"defmodule MyApp.SQLiteRepo do", "run"}],
    "docs/profiles.md" => [
      {"profile = CapabilityProfile.get_capability_profile(", "run"},
      {"CapabilityProfile.builtin_keys()", "run"}
    ],
    "docs/testing.md" => [{"cassette = \"\"\"", "run"}],
    "docs/providers/deepseek.md" => [{"client = BeamWeaver.DeepSeek.Client.new()", "live"}],
    "docs/providers/openai.md" => [{"BeamWeaver.OpenAI.generate_image(", "live"}]
  }

  def annotate(markdown, file, blocks) do
    apply_rules(markdown, blocks, Map.get(@scenarios, file, []), Map.get(@overrides, file, []))
  end

  def apply_rules(markdown, blocks, scenarios, overrides) do
    lines = markdown |> String.split("\n") |> Enum.with_index(1)

    boundaries =
      for {heading, name, requirements} <- scenarios do
        case Enum.filter(lines, fn {line, _} -> line == heading end) do
          [{_, line}] -> {line, name, requirements}
          matches -> raise ArgumentError, "Scenario heading #{inspect(heading)} matched #{length(matches)} times"
        end
      end
      |> Enum.sort(:desc)

    blocks =
      Enum.map(blocks, fn block ->
        {_, scenario, requirements} =
          Enum.find(boundaries, {0, "default", []}, fn {line, _, _} -> line < block.line end)

        %{block | scenario: scenario, requirements: Enum.uniq(block.requirements ++ requirements)}
      end)

    Enum.reduce(overrides, blocks, fn {selector, mode}, blocks ->
      case Enum.filter(blocks, &String.contains?(&1.code, selector)) do
        [selected] ->
          Enum.map(blocks, fn block ->
            if block.line == selected.line do
              requirements = if mode in ~w(live postgres docker), do: [mode], else: []
              %{block | mode: mode, requirements: Enum.uniq(block.requirements ++ requirements)}
            else
              block
            end
          end)

        matches ->
          raise ArgumentError, "Example selector #{inspect(selector)} matched #{length(matches)} times"
      end
    end)
  end
end
