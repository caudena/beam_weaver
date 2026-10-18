# An agent that keeps a wiki: Markdown pages under /wiki that it searches,
# updates with new notes, and answers from.
#
#   mix run examples/deepagents/llm_wiki.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.LlmWiki.WikiQuery do
  use BeamWeaver.Tool

  name "wiki_query"
  description "Search the wiki and return the pages that mention a word, with their paths and text."

  schema do
    field :query, :string, description: "A word or short phrase to look for"
  end

  @impl true
  def invoke(_tool, %{"query" => query}, _opts) do
    root = BeamWeaver.Examples.DeepAgents.LlmWiki.root()
    words = query |> String.downcase() |> String.split()

    pages =
      for path <- Path.wildcard(Path.join(root, "wiki/*.md")),
          text = File.read!(path),
          Enum.any?(words, &String.contains?(String.downcase(text), &1)),
          do: "/#{Path.relative_to(path, root)}:\n#{text}"

    {:ok, if(pages == [], do: "No wiki page mentions #{inspect(query)}.", else: Enum.join(pages, "\n"))}
  end
end

defmodule BeamWeaver.Examples.DeepAgents.LlmWiki do
  alias BeamWeaver.Agent
  alias BeamWeaver.Examples.DeepAgents.LlmWiki.WikiQuery
  alias BeamWeaver.Examples.DeepAgents.Support
  alias BeamWeaver.Filesystem.Local

  def root, do: Support.root("llm_wiki")

  def run do
    root = Support.fresh_root!("llm_wiki")
    File.mkdir_p!(Path.join(root, "wiki"))
    File.write!(Path.join(root, "wiki/beamweaver.md"), "# BeamWeaver\n\nAn Elixir library for LLM agents.\n")
    File.write!(Path.join(root, "wiki/otp.md"), "# OTP\n\nSupervisors restart processes that crash.\n")

    {:ok, agent} =
      Support.create(
        name: "llm-wiki",
        model: Support.model(),
        filesystem: Local.new(root: root),
        tools: [WikiQuery],
        system_prompt: """
        You maintain a wiki of Markdown pages under /wiki, one page per topic. People read the \
        pages, not your replies, so a note is in the wiki only once you have saved it to its \
        page; saying that you added it changes nothing.

        To add a note: find the topic's page with wiki_query, then append the note to that page \
        with edit_file (write_file only creates new pages). To answer a question, look the topic \
        up with wiki_query and answer from the pages it returns.
        """
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{
        messages: [
          "Add this note to the BeamWeaver page: \"BeamWeaver runs each agent as supervised OTP processes.\" " <>
            "Then look BeamWeaver up again and tell me what the wiki says about it now."
        ]
      })

    IO.puts(Support.assert_text!(List.last(messages)))
    IO.puts("\n/wiki/beamweaver.md:\n#{File.read!(Path.join(root, "wiki/beamweaver.md"))}")
    Support.assert_tools_called!(messages, ["wiki_query", ["edit_file", "write_file"]])
    true = String.contains?(File.read!(Path.join(root, "wiki/beamweaver.md")), "supervised OTP processes")
  end
end

BeamWeaver.Examples.DeepAgents.LlmWiki.run()
