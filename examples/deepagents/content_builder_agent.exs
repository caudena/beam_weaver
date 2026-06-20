Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.ContentBuilderAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    root = fresh_root!("content_builder")
    seed_memory_and_skills!(root)

    backend = Local.new(root: root)

    researcher =
      Spec.new(
        name: "researcher",
        description: "Researches topics before content is drafted.",
        system_prompt: "Return concise research notes with links and facts.",
        tools: [web_search_stub()],
        model: Support.model()
      )

    {:ok, agent} =
      Support.create(
        model: Support.model(),
        filesystem: backend,
        memory: ["/AGENTS.md"],
        skills: ["/skills"],
        tools: [generate_cover_tool(), web_search_stub()],
        subagents: [researcher]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{
        messages: [Message.user("Write a blog post about prompt engineering.")]
      })

    IO.puts(Message.text(List.last(messages)))
  end

  defp seed_memory_and_skills!(root) do
    File.write!(Path.join(root, "AGENTS.md"), "Brand voice: practical, direct, evidence-led.\n")

    blog_dir = Path.join([root, "skills", "blog-post"])
    social_dir = Path.join([root, "skills", "social-media"])
    File.mkdir_p!(blog_dir)
    File.mkdir_p!(social_dir)

    File.write!(Path.join(blog_dir, "SKILL.md"), """
    ---
    name: blog-post
    description: Use when writing long-form blog posts with a hook, body, and CTA.
    ---
    Draft with research first, then write a clear outline and final post.
    """)

    File.write!(Path.join(social_dir, "SKILL.md"), """
    ---
    name: social-media
    description: Use when writing LinkedIn posts, tweets, and short-form launch copy.
    ---
    Match the platform constraints and include a concise visual prompt.
    """)
  end

  defp generate_cover_tool do
    Tool.from_function!(
      name: "generate_cover",
      description: "Generate a cover image prompt and return an artifact path.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"topic" => %{"type" => "string"}},
        "required" => ["topic"]
      },
      handler: fn %{"topic" => topic}, _opts -> "/blogs/#{slug(topic)}/hero.png" end
    )
  end

  defp web_search_stub do
    Tool.from_function!(
      name: "web_search",
      description: "Return local research snippets for a topic.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      },
      handler: fn %{"query" => query}, _opts -> "research snippet for #{query}" end
    )
  end

  defp fresh_root!(name) do
    root = Path.join(System.tmp_dir!(), "beam_weaver_deepagents_#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end

  defp slug(value), do: value |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
end

BeamWeaver.Examples.DeepAgents.ContentBuilderAgent.run()
