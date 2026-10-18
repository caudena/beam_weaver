# A documentation agent: it answers from a docs search tool and cites the
# pages it used. Its instructions live in /AGENTS.md.
#
# `search_docs` stands in for the search tool of a documentation server; it
# returns canned pages so the example runs offline from the docs.
#
#   mix run examples/deepagents/deploy_mcp_docs_agent.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DeployMcpDocsAgent.SearchDocs do
  use BeamWeaver.Tool

  name "search_docs"
  description "Search the BeamWeaver documentation and return matching passages with their page paths."

  schema do
    field :query, :string, description: "What to search for"
  end

  @impl true
  def invoke(_tool, %{"query" => _query}, _opts) do
    {:ok,
     """
     docs/filesystem.md: An agent with `filesystem:` gets the tools ls, read_file, write_file, edit_file, glob and grep.
     docs/filesystem.md: Filesystem.State keeps files in the agent state; Filesystem.Local uses a real directory.
     docs/sandboxes.md: A sandbox backend also adds the execute tool for shell commands.
     """}
  end
end

defmodule BeamWeaver.Examples.DeepAgents.DeployMcpDocsAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Examples.DeepAgents.DeployMcpDocsAgent.SearchDocs
  alias BeamWeaver.Examples.DeepAgents.Support
  alias BeamWeaver.Filesystem.Local

  def run do
    root = Support.fresh_root!("deploy_mcp_docs_agent")

    File.write!(
      Path.join(root, "AGENTS.md"),
      "Answer from search_docs results only, and cite the page paths you used.\n"
    )

    {:ok, agent} =
      Support.create(
        name: "docs-agent",
        model: Support.model(),
        filesystem: Local.new(root: root),
        memory: ["/AGENTS.md"],
        tools: [SearchDocs]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: ["How do filesystem backends work in BeamWeaver?"]})

    IO.puts(Support.assert_text!(List.last(messages)))
    Support.assert_tools_called!(messages, ["search_docs"])
  end
end

BeamWeaver.Examples.DeepAgents.DeployMcpDocsAgent.run()
