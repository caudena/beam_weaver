Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.LlmWiki do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    root = fresh_root!("llm_wiki")
    File.mkdir_p!(Path.join(root, "wiki"))

    File.write!(
      Path.join([root, "wiki", "deepagents.md"]),
      "DeepAgents include tools, files, memory, and subagents.\n"
    )

    File.write!(
      Path.join([root, "wiki", "beamweaver.md"]),
      "BeamWeaver ports the stack to Elixir and OTP.\n"
    )

    {:ok, agent} =
      Support.create(
        name: "llm-wiki",
        model: Support.model("llm_wiki: indexed local wiki pages and answered from them"),
        filesystem: Local.new(root: root),
        tools: [wiki_query_tool(root)]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("What does the wiki say about BeamWeaver?")]})

    IO.puts(Message.text(List.last(messages)))
  end

  defp wiki_query_tool(root) do
    Tool.from_function!(
      name: "wiki_query",
      description: "Search local markdown wiki pages.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      },
      handler: fn %{"query" => query}, _opts ->
        root
        |> Path.join("wiki/*.md")
        |> Path.wildcard()
        |> Enum.map(&File.read!/1)
        |> Enum.filter(
          &(String.contains?(String.downcase(&1), String.downcase(query)) or query == "")
        )
        |> Enum.join("\n")
      end
    )
  end

  defp fresh_root!(name) do
    root = Path.join(System.tmp_dir!(), "beam_weaver_deepagents_#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end

BeamWeaver.Examples.DeepAgents.LlmWiki.run()
