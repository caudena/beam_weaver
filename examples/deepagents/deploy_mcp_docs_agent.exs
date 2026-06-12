Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DeployMcpDocsAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    root = fresh_root!("deploy_mcp_docs_agent")
    File.write!(Path.join(root, "AGENTS.md"), "Answer from docs first. Cite page paths.\n")

    {:ok, agent} =
      Support.create(
        name: "deploy-mcp-docs-agent",
        model: Support.model("deploy_mcp_docs_agent: docs search tool and memory are configured"),
        filesystem: Local.new(root: root),
        memory: ["/AGENTS.md"],
        tools: [docs_search_tool()]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("How do DeepAgents backends work?")]})

    IO.puts(Message.text(List.last(messages)))
  end

  defp docs_search_tool do
    Tool.from_function!(
      name: "search_docs",
      description: "Search connected documentation. This port uses a local MCP-like stub.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      },
      handler: fn %{"query" => query}, _opts ->
        "docs result for #{query}: backends expose ls/read/write/edit/glob/grep"
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

BeamWeaver.Examples.DeepAgents.DeployMcpDocsAgent.run()
