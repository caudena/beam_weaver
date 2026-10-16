# Renders the model tables in docs/providers.md and docs/providers/*.md from
# the checked-in model profiles. `mix docs.providers` rewrites them; the docs
# lint fails when they are stale.
#
# A generated table sits between markers:
#
#   <!-- generated: provider-overview -->
#   <!-- generated: provider-models openai -->
#   ...
#   <!-- /generated -->
defmodule BeamWeaver.Docs.ProviderTables do
  alias BeamWeaver.Provider.Compatibility

  @root Path.expand("../..", __DIR__)
  @block ~r/(<!-- generated: (provider-overview|provider-models \w+) -->\n)(.*?)(<!-- \/generated -->)/s
  @providers [
    openai: "OpenAI",
    anthropic: "Anthropic",
    google: "Google Gemini",
    xai: "xAI",
    moonshot: "Moonshot (Kimi)",
    zai: "Z.ai",
    deepseek: "DeepSeek",
    typesafe: "TypeSafe"
  ]

  def pages, do: [Path.join(@root, "docs/providers.md") | Path.wildcard(Path.join(@root, "docs/providers/*.md"))]

  @doc "Pages whose generated tables differ from the profiles."
  def stale do
    for path <- pages(),
        File.exists?(path),
        text = File.read!(path),
        render_page(text) != text,
        do: Path.relative_to(path, @root)
  end

  def write! do
    for path <- pages(), File.exists?(path) do
      text = File.read!(path)
      updated = render_page(text)
      if updated != text, do: File.write!(path, updated)
      IO.puts("#{if updated == text, do: "unchanged", else: "updated  "} #{Path.relative_to(path, @root)}")
    end
  end

  def render_page(text) do
    Regex.replace(@block, text, fn _all, open, name, _old, close -> open <> render(name) <> close end)
  end

  def render("provider-overview") do
    rows =
      for {provider, label} <- @providers do
        models = rows(provider)
        chat = Enum.filter(models, &(kind(&1) == "chat"))

        [
          "[#{label}](providers/#{provider}.md)",
          "`#{provider}:`",
          models
          |> Enum.frequencies_by(&kind/1)
          |> Enum.sort()
          |> Enum.map_join(", ", fn {kind, n} -> "#{n} #{kind}" end),
          coverage(chat, :tool_calling),
          coverage(chat, :structured_output, :structured_output_with_tools),
          coverage(chat, :reasoning),
          coverage(chat, :image_input)
        ]
      end

    table(["Provider", "Prefix", "Models", "Tools", "Structured output", "Reasoning", "Image input"], rows)
  end

  def render("provider-models " <> provider) do
    provider = String.to_existing_atom(provider)

    rows =
      for row <- rows(provider) do
        [
          "`#{provider}:#{row.model}`",
          kind(row),
          tokens(row.max_input_tokens),
          tokens(row.max_output_tokens),
          yes(row.features[:tool_calling]),
          yes(row.features[:structured_output] or row.features[:structured_output_with_tools]),
          yes(row.features[:reasoning]),
          inputs(row)
        ]
      end

    table(["Model", "Kind", "Input tokens", "Output tokens", "Tools", "Structured output", "Reasoning", "Inputs"], rows)
  end

  defp rows(provider), do: Enum.filter(Compatibility.matrix(), &(&1.provider == provider))

  defp kind(row) do
    cond do
      row.features[:decision_output] -> "decision"
      row.features[:tool_calling] or row.features[:streaming] -> "chat"
      true -> "embedding"
    end
  end

  defp coverage(rows, feature, alternative \\ nil)
  defp coverage([], _feature, _alternative), do: "—"

  defp coverage(rows, feature, alternative) do
    supported = Enum.count(rows, &(&1.features[feature] or (alternative && &1.features[alternative])))

    cond do
      supported == length(rows) -> "all"
      supported == 0 -> "—"
      true -> "#{supported} of #{length(rows)}"
    end
  end

  defp inputs(row) do
    [text_input: "text", image_input: "image", pdf_input: "PDF", audio_input: "audio", video_input: "video"]
    |> Enum.filter(fn {feature, _label} -> row.features[feature] end)
    |> Enum.map_join(", ", &elem(&1, 1))
  end

  defp tokens(nil), do: "—"

  defp tokens(count),
    do:
      count |> Integer.to_string() |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()

  defp yes(true), do: "yes"
  defp yes(_other), do: "—"

  defp table(header, rows) do
    [header, Enum.map(header, fn _column -> "---" end) | rows]
    |> Enum.map_join("", &("| " <> Enum.join(&1, " | ") <> " |\n"))
  end
end

if "--write" in System.argv(), do: BeamWeaver.Docs.ProviderTables.write!()
