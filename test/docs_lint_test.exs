Code.require_file("../scripts/docs/provider_tables.exs", __DIR__)

defmodule BeamWeaver.DocsLintTest do
  # Structural checks for the guides: navigation, links, references, terms and
  # GitBook markup. Code blocks are run by test/docs_test.exs.
  use ExUnit.Case, async: true

  alias BeamWeaver.Models.ProfileRegistry
  alias BeamWeaver.TestSupport.DocSnippets

  @root Path.expand("..", __DIR__)
  @docs Path.join(@root, "docs")

  @reserved_names ~w(readme changelog api-reference search 404 license)
  @gitbook_blocks %{"hint" => "endhint", "tabs" => "endtabs", "tab" => "endtab"}
  @hint_styles ~w(info success warning danger)
  @max_hints 2
  @porting_terms ~r/\b(LangChain|LangGraph|LangSmith|langchain|langgraph|Pydantic|TypedDict|create_deep_agent|create_react_agent|create_agent)\b/
  @porting_page "docs/coming_from_langchain.md"
  @python_pages ["docs/coming_from_langchain.md", "docs/sandboxes.md"]
  @dsl_footgun ~r/^\s*(checkpointer|store|cache)\b[\s(]+[A-Z][\w.]*\.ETS\.new\b/m
  # A trailing `*` marks a model family, such as `google:gemini-*`.
  @model_id ~r/(?<![\w\/.:-])(openai|anthropic|google|xai|moonshot|zai|deepseek|typesafe):([A-Za-z0-9][\w.-]*+)(?!\*)/
  @deliberate_model_ids ["openai:future-model"]
  @profile_modules %{
    "openai" => ProfileRegistry.OpenAI,
    "anthropic" => ProfileRegistry.Anthropic,
    "google" => ProfileRegistry.Google,
    "xai" => ProfileRegistry.XAI,
    "moonshot" => ProfileRegistry.Moonshot,
    "zai" => ProfileRegistry.ZAI,
    "deepseek" => ProfileRegistry.DeepSeek,
    "typesafe" => ProfileRegistry.TypeSafe
  }

  setup_all do
    pages = for page <- DocSnippets.pages(), is_binary(page), do: {page, parse(page)}
    %{pages: Map.new(pages), order: Enum.map(pages, &elem(&1, 0))}
  end

  test "SUMMARY.md lists exactly the pages on disk", %{order: order} do
    on_disk =
      for path <- Path.wildcard(Path.join(@docs, "**/*.md")),
          page = Path.relative_to(path, @root),
          page != "docs/SUMMARY.md",
          do: page

    summary_links =
      for [_, link] <- Regex.scan(~r/\]\(([^)\s]+)\)/, File.read!(Path.join(@docs, "SUMMARY.md"))),
          do: Path.join("docs", link)

    assert_none(
      for link <- summary_links, not File.exists?(Path.join(@root, link)), do: "SUMMARY.md links missing #{link}"
    )

    assert_none(for page <- on_disk -- order, do: "#{page} is not in SUMMARY.md")
    assert hd(summary_links) == "docs/README.md", "SUMMARY.md must start with README.md"
  end

  test "page names are unique and safe for HexDocs", %{order: order} do
    names = for page <- order, page not in ["README.md", "docs/README.md"], do: {page, page |> Path.basename(".md")}

    assert_none(
      for {name, pages} <- Enum.group_by(names, &elem(&1, 1), &elem(&1, 0)),
          length(pages) > 1 or name in @reserved_names,
          do: "page name #{name} is reserved or shared by #{Enum.join(pages, ", ")}"
    )
  end

  test "each page has one H1 as its first line", %{pages: pages} do
    assert_none(
      for {page, doc} <- pages,
          h1s = Enum.filter(doc.headings, &(&1.level == 1)),
          problem <- [
            if(not String.starts_with?(doc.text, "# "), do: "#{page}:1: the page must start with an H1"),
            if(length(h1s) > 1, do: "#{page}:#{Enum.at(h1s, 1).line}: a page has one H1")
          ],
          problem,
          do: problem
    )
  end

  test "relative links and anchors resolve inside the docs", %{pages: pages} do
    assert_none(
      for {page, doc} <- pages,
          %{target: target, line: line} <- doc.links,
          problem = link_problem(page, target, pages),
          do: "#{page}:#{line}: #{target} #{problem}"
    )
  end

  test "module and function references name public API", %{pages: pages} do
    assert_none(
      for {page, doc} <- pages,
          %{ref: ref, line: line, code?: code?} <- doc.references,
          problem = reference_problem(ref, code?),
          do: "#{page}:#{line}: #{ref} #{problem}"
    )
  end

  test "provider model ids are known models", %{pages: pages} do
    assert_none(
      for {page, doc} <- pages,
          {line, n} <- doc.lines,
          [id, provider, model] <- Regex.scan(@model_id, line),
          id not in @deliberate_model_ids,
          not known_model?(provider, model),
          do: "#{page}:#{n}: unknown model id #{id}"
    )
  end

  test "install snippets pin the current version", %{pages: pages} do
    pin = "~> #{Mix.Project.config()[:version]}"

    assert_none(
      for {page, doc} <- pages,
          {line, n} <- doc.lines,
          [_, version] <- Regex.scan(~r/\{:beam_weaver,\s*"([^"]+)"/, line),
          version != pin,
          do: "#{page}:#{n}: pin {:beam_weaver, #{inspect(pin)}}, not #{inspect(version)}"
    )
  end

  test "GitBook blocks are balanced, hints are few, and tabs hold only checked-not-run code", %{pages: pages} do
    assert_none(Enum.flat_map(pages, fn {page, doc} -> gitbook_problems(page, doc) end))
  end

  test "porting notes stay on the LangChain page", %{pages: pages} do
    assert_none(
      for {page, doc} <- pages,
          page != @porting_page,
          {line, n} <- doc.lines,
          line = String.replace(line, ~r/\[[^\]]*\]\([^)]*coming_from_langchain\.md[^)]*\)/, ""),
          match = Regex.run(@porting_terms, line) || python_mention(page, doc, n, line),
          do: "#{page}:#{n}: #{hd(match)} belongs on #{@porting_page}"
    )
  end

  # An agent or graph module that creates an in-memory saver, store or cache in
  # a declaration doesn't compile, so test/docs_test.exs rejects it in every
  # block it compiles; this covers the blocks it never compiles.
  test "blocks that aren't compiled don't build in-memory savers in the DSL", %{pages: pages} do
    assert_none(
      for {page, _doc} <- pages,
          block <- DocSnippets.blocks(page),
          block.mode in ~w(skip config mix),
          Regex.match?(@dsl_footgun, block.code),
          do:
            "#{page}:#{block.line}: the DSL re-evaluates `checkpointer`/`store`/`cache` on every call; " <>
              "create the ETS saver once and pass it with `checkpointer:`/`store:`"
    )
  end

  test "GitBook and HexDocs redirects agree and land on current pages", %{order: order} do
    gitbook =
      for line <-
            @root
            |> Path.join(".gitbook.yaml")
            |> File.read!()
            |> String.split("\nredirects:\n")
            |> List.last()
            |> String.split("\n"),
          [_, from, to] <- [Regex.run(~r/^  ([\w\/-]+): ([\w\/.-]+\.md)$/, line)],
          into: %{},
          do: {from, to}

    exdoc = Mix.Project.config()[:docs].()[:redirects]
    pages = for page <- order, String.starts_with?(page, "docs/"), into: %{}, do: {Path.rootname(page, ".md"), page}

    assert_none(
      for {from, to} <- gitbook,
          problem <- [
            if(not Map.has_key?(pages, "docs/" <> Path.rootname(to)),
              do: "#{from} redirects to #{to}, which is not a page"
            ),
            if(Map.has_key?(pages, "docs/" <> from), do: "#{from} redirects but is still a page"),
            if(not String.contains?(from, "/") and exdoc[from] != Path.basename(to, ".md"),
              do: "#{from}: mix.exs redirects to #{inspect(exdoc[from])}, .gitbook.yaml to #{to}"
            )
          ],
          problem,
          do: problem
    )

    assert_none(for {from, _to} <- exdoc, not Map.has_key?(gitbook, from), do: "#{from} is redirected in mix.exs only")
  end

  test "every public module has a HexDocs group, and groups name only public modules" do
    {:ok, modules} = :application.get_key(:beam_weaver, :modules)
    public = for module <- modules, not hidden_doc?(module), do: module
    groups = @root |> Path.join("scripts/docs/module_groups.exs") |> Code.eval_file() |> elem(0)
    entries = Enum.flat_map(groups, &elem(&1, 1))

    grouped? = fn module ->
      Enum.any?(entries, fn
        %Regex{} = pattern -> Regex.match?(pattern, inspect(module))
        entry -> entry == module
      end)
    end

    assert_none(for module <- Enum.sort(public), not grouped?.(module), do: "#{inspect(module)} has no group")

    assert_none(
      for entry <- entries,
          is_atom(entry),
          problem = module_problem(entry, false),
          do: "scripts/docs/module_groups.exs: #{inspect(entry)} #{problem}"
    )
  end

  test "provider tables match the model profiles" do
    assert BeamWeaver.Docs.ProviderTables.stale() == [], "regenerate the tables with `mix docs.providers`"
  end

  ## Parsing

  defp parse(page) do
    text = File.read!(Path.join(@root, page))
    numbered = text |> String.split("\n") |> Enum.with_index(1)
    {prose, code} = split_fences(numbered)

    %{
      text: text,
      lines: numbered,
      prose: prose,
      prose_lines: MapSet.new(prose, &elem(&1, 1)),
      headings: headings(prose),
      links: links(prose),
      references: references(prose, code)
    }
  end

  # `{prose_lines, code_lines}`; fence lines themselves count as code.
  defp split_fences(numbered) do
    {prose, code, _fence} =
      Enum.reduce(numbered, {[], [], nil}, fn {line, n}, {prose, code, fence} ->
        case {fence, Regex.run(~r/^\s*(```+|~~~+)/, line)} do
          {nil, [_, marker]} ->
            {prose, [{line, n} | code], marker}

          {nil, nil} ->
            {[{line, n} | prose], code, nil}

          {fence, _match} ->
            if closes?(line, fence), do: {prose, [{line, n} | code], nil}, else: {prose, [{line, n} | code], fence}
        end
      end)

    {Enum.reverse(prose), Enum.reverse(code)}
  end

  defp closes?(line, fence), do: String.trim(line) == fence or Regex.match?(~r/^\s*#{Regex.escape(fence)}\s*$/, line)

  defp headings(prose) do
    for {line, n} <- prose, [_, hashes, title] <- [Regex.run(~r/^([#]{1,6})\s+(.+?)\s*#*\s*$/, line)] do
      %{level: String.length(hashes), title: title, line: n}
    end
  end

  defp links(prose) do
    for {line, n} <- prose,
        line = strip_inline_code(line),
        [_, target] <-
          Regex.scan(~r/!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/, line) ++
            Regex.scan(~r/^\s*\[[^\]]+\]:\s+(\S+)/, line),
        do: %{target: target, line: n}
  end

  defp strip_inline_code(line), do: String.replace(line, ~r/`[^`]*`/, "")

  # Inline-code and HexDocs references in prose, and module names in code.
  defp references(prose, code) do
    inline =
      for {line, n} <- prose,
          [_, ref] <- Regex.scan(~r/`((?:[ct]:)?BeamWeaver(?:\.[A-Z]\w*)*(?:\.[a-z_]\w*[?!]?\/\d+)?)`/, line),
          do: %{ref: ref, line: n, code?: false}

    hexdocs =
      for {line, n} <- prose,
          [_, module | anchor] <-
            Regex.scan(~r{hexdocs\.pm/beam_weaver/(BeamWeaver[\w.]*)\.html(?:#([\w?!]+/\d+))?}, line),
          do: %{ref: Enum.join([module | anchor], "."), line: n, code?: false}

    in_code =
      for {line, n} <- code,
          [_, base | group] <- Regex.scan(~r/\b(BeamWeaver(?:\.[A-Z]\w*)*)\b(?:\.\{([^}]*)\})?/, line),
          module <- expand_alias(base, List.first(group, "")),
          do: %{ref: module, line: n, code?: true}

    inline ++ hexdocs ++ in_code
  end

  defp expand_alias(base, ""), do: [base]

  defp expand_alias(base, group),
    do: for(name <- String.split(group, ","), name = String.trim(name), name != "", do: "#{base}.#{name}")

  ## Checks

  defp link_problem(_page, "http" <> _url, _pages), do: nil
  defp link_problem(_page, "mailto:" <> _address, _pages), do: nil

  defp link_problem(page, "#" <> anchor, pages), do: anchor_problem(page, anchor, pages)

  defp link_problem(page, target, pages) do
    [path | anchor] = String.split(target, "#", parts: 2)
    resolved = path |> Path.expand(Path.dirname(Path.join(@root, page))) |> Path.relative_to(@root)

    cond do
      not File.exists?(Path.join(@root, resolved)) ->
        "does not exist"

      page != "README.md" and not String.starts_with?(resolved, "docs/") ->
        "leaves docs/; link repository files by GitHub URL"

      page == "README.md" and resolved == "CHANGELOG.md" ->
        nil

      resolved == "docs/README.md" ->
        "is the GitBook home page, which HexDocs leaves out"

      Path.extname(resolved) == ".md" and not Map.has_key?(pages, resolved) ->
        "is not a page in SUMMARY.md"

      page == "README.md" and not String.starts_with?(resolved, "docs/") ->
        "is not a docs page"

      anchor != [] ->
        anchor_problem(resolved, hd(anchor), pages)

      true ->
        nil
    end
  end

  # GitBook, GitHub and ExDoc derive anchors differently; only headings whose
  # anchors agree everywhere can be linked.
  defp anchor_problem(page, anchor, pages) do
    headings = pages |> Map.fetch!(page) |> Map.fetch!(:headings)

    if Enum.any?(headings, &(github_anchor(&1.title) == anchor and exdoc_anchor(&1.title) == anchor)),
      do: nil,
      else: "has no heading with anchor ##{anchor} (in both GitHub and HexDocs form)"
  end

  defp github_anchor(title) do
    title
    |> plain_heading()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s_-]/u, "")
    |> String.replace(" ", "-")
  end

  defp exdoc_anchor(title) do
    title |> plain_heading() |> String.replace(~r/\W+/u, "-") |> String.trim("-") |> String.downcase()
  end

  defp plain_heading(title),
    do: title |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1") |> String.replace(["`", "*"], "")

  defp reference_problem(ref, code?) do
    {kind, ref} =
      case ref do
        "c:" <> ref -> {:callback, ref}
        "t:" <> ref -> {:type, ref}
        ref -> {:function, ref}
      end

    case Regex.run(~r/^(.*?)(?:\.([a-z_]\w*[?!]?)\/(\d+))?$/, ref) do
      [_, module] ->
        module_problem(Module.concat([module]), code?)

      [_, module, name, arity] ->
        member_problem(Module.concat([module]), kind, String.to_atom(name), String.to_integer(arity))
    end
  end

  defp module_problem(module, code?) do
    cond do
      not Code.ensure_loaded?(module) -> if(code?, do: nil, else: "does not exist")
      hidden_doc?(module) -> "is internal (@moduledoc false)"
      true -> nil
    end
  end

  defp member_problem(module, kind, name, arity) do
    with nil <- module_problem(module, false) do
      {:docs_v1, _anno, _lang, _format, _moduledoc, _meta, docs} = Code.fetch_docs(module)
      kinds = %{function: [:function, :macro], callback: [:callback, :macrocallback], type: [:type]}

      entry =
        Enum.find(docs, fn {{entry_kind, entry_name, entry_arity}, _anno, _signature, _doc, meta} ->
          entry_kind in kinds[kind] and entry_name == name and
            arity in (entry_arity - Map.get(meta, :defaults, 0))..entry_arity//1
        end)

      case entry do
        nil -> "is not defined"
        {_key, _anno, _signature, :hidden, _meta} -> "is internal (@doc false)"
        _entry -> nil
      end
    end
  end

  defp hidden_doc?(module) do
    match?({:docs_v1, _, _, _, :hidden, _, _}, Code.fetch_docs(module))
  end

  defp known_model?(provider, model), do: match?({:ok, _profile}, Map.fetch!(@profile_modules, provider).resolve(model))

  defp gitbook_problems(page, doc) do
    tags =
      for {line, n} <- doc.prose,
          [_, tag, args] <- Regex.scan(~r/\{%\s*(\w[\w-]*)\s*(.*?)\s*%\}/, line),
          do: {tag, args, n}

    {stack, problems, regions} =
      Enum.reduce(tags, {[], [], []}, fn {tag, args, n}, {stack, problems, regions} ->
        closing = for {open, close} <- @gitbook_blocks, close == tag, do: open

        cond do
          Map.has_key?(@gitbook_blocks, tag) ->
            style_problem =
              if tag == "hint" and not Regex.match?(~r/^style="(#{Enum.join(@hint_styles, "|")})"$/, args),
                do: ["#{page}:#{n}: hint needs style=\"info|success|warning|danger\""],
                else: []

            {[{tag, n} | stack], style_problem ++ problems, regions}

          closing != [] ->
            case stack do
              [{open, start} | rest] when [open] == closing -> {rest, problems, [{open, start, n} | regions]}
              _other -> {stack, ["#{page}:#{n}: #{tag} without a matching #{hd(closing)}" | problems], regions}
            end

          true ->
            {stack, ["#{page}:#{n}: unsupported GitBook tag #{tag}" | problems], regions}
        end
      end)

    unclosed = for {tag, n} <- stack, do: "#{page}:#{n}: #{tag} is never closed"
    hints = Enum.count(regions, &match?({"hint", _, _}, &1))
    too_many = if hints > @max_hints, do: ["#{page}: #{hints} hints; keep at most #{@max_hints} per page"], else: []

    in_tabs =
      for {"tabs", from, to} <- regions,
          block <- DocSnippets.blocks(page),
          block.line in from..to,
          block.mode not in ["compile", "config", "mix", "fragment"],
          do:
            "#{page}:#{block.line}: code in tabs must not run (it is #{block.mode}); tabs are for provider alternatives"

    Enum.reverse(problems) ++ unclosed ++ too_many ++ in_tabs
  end

  defp python_mention(page, doc, n, line) do
    if page not in @python_pages and MapSet.member?(doc.prose_lines, n),
      do: Regex.run(~r/\bPython\b/, strip_inline_code(line))
  end

  defp assert_none([]), do: :ok
  defp assert_none(problems), do: flunk(Enum.join(problems, "\n"))
end
