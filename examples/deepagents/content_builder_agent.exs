# A content agent: brand memory in /AGENTS.md, writing skills in /skills, a
# researcher subagent with web search, and a cover-image tool. Posts are saved
# as files under /posts.
#
#   mix run examples/deepagents/content_builder_agent.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.ContentBuilderAgent.WebSearch do
  use BeamWeaver.Tool

  name "web_search"
  description "Search the web and return the top results with their URLs."

  schema do
    field :query, :string, description: "What to search for"
  end

  # Canned results so the example is repeatable; swap in a real search API.
  @impl true
  def invoke(_tool, %{"query" => query}, _opts) do
    {:ok,
     """
     Results for "#{query}":
     1. Support Operations Report 2026: teams that give models step-by-step instructions resolve
        tickets 30% faster.
     2. "Prompts That Work", chapter 3: two or three worked examples in a prompt cut wrong answers by half.
     """}
  end
end

defmodule BeamWeaver.Examples.DeepAgents.ContentBuilderAgent.GenerateCover do
  use BeamWeaver.Tool

  name "generate_cover"
  description "Generate a cover image for a post and return the image path."

  schema do
    field :prompt, :string, description: "What the image should show"
  end

  @impl true
  def invoke(_tool, %{"prompt" => prompt}, _opts) do
    slug = prompt |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.slice(0, 40)
    {:ok, "Saved the cover image to /images/#{String.trim(slug, "-")}.png"}
  end
end

defmodule BeamWeaver.Examples.DeepAgents.ContentBuilderAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Examples.DeepAgents.ContentBuilderAgent.GenerateCover
  alias BeamWeaver.Examples.DeepAgents.ContentBuilderAgent.WebSearch
  alias BeamWeaver.Examples.DeepAgents.Support
  alias BeamWeaver.Filesystem.Local

  def run do
    root = Support.fresh_root!("content_builder")
    seed_memory_and_skills!(root)

    researcher =
      Spec.new(
        name: "researcher",
        description: "Researches a topic on the web and returns short notes with their sources.",
        system_prompt: "Search the web, then return short notes, each with its source.",
        tools: [WebSearch],
        model: Support.model(),
        middleware: Support.limits()
      )

    {:ok, agent} =
      Support.create(
        name: "content-builder",
        model: Support.model(),
        filesystem: Local.new(root: root),
        memory: ["/AGENTS.md"],
        skills: ["/skills"],
        tools: [GenerateCover],
        subagents: [researcher],
        system_prompt:
          "You write marketing content. Before you write, read the skill that matches the request and " <>
            "do every step of it. The social team publishes only what is saved under /posts, never your reply."
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{
        messages: [
          "Write a LinkedIn post announcing \"Prompts That Work\", our new free guide that teaches " <>
            "support teams to write clear instructions and worked examples for AI assistants."
        ]
      })

    IO.puts(Message.text(List.last(messages)))

    for post <- Path.wildcard(Path.join(root, "posts/*.md")),
        do: IO.puts("\n#{Path.relative_to(post, root)}:\n#{File.read!(post)}")

    Support.assert_tools_called!(messages, ["generate_cover", "write_file"])
  end

  defp seed_memory_and_skills!(root) do
    File.write!(Path.join(root, "AGENTS.md"), "Brand voice: practical, direct, evidence-led. No hashtags.\n")

    for {name, description, body} <- [
          {"blog-post", "Use when writing long-form blog posts.",
           "Research first, then write an outline, then the post with a hook, body, and call to action."},
          {"social-media", "Use when writing LinkedIn posts, tweets, and other short posts.",
           """
           1. Ask the researcher subagent for two facts with their sources.
           2. Write the post in at most 80 words, naming one source.
           3. Call generate_cover yourself, not through a subagent, for an image that matches the post.
           4. Save the post and the image path to /posts/<short-slug>.md with write_file: the team
              publishes from that file, so a post that isn't saved there is never seen.
           """}
        ] do
      dir = Path.join([root, "skills", name])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "---\nname: #{name}\ndescription: #{description}\n---\n#{body}\n")
    end
  end
end

BeamWeaver.Examples.DeepAgents.ContentBuilderAgent.run()
