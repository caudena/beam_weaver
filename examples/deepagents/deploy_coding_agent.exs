Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DeployCodingAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.Permission
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    root = fresh_root!("deploy_coding_agent")
    File.write!(Path.join(root, "AGENTS.md"), "Plan, implement, test, review, then summarize.\n")

    permissions = [
      Permission.new(
        operations: [:read, :write],
        paths: ["/workspace/**"],
        mode: :allow
      ),
      Permission.new(operations: [:write], paths: ["/secrets/**"], mode: :deny)
    ]

    {:ok, agent} =
      Support.create(
        name: "deploy-coding-agent",
        model: Support.model("deploy_coding_agent: sandbox-backed coding agent ready"),
        filesystem: Local.new(root: root),
        memory: ["/AGENTS.md"],
        permissions: permissions
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("Prepare to edit a project in /workspace.")]})

    IO.puts(Message.text(List.last(messages)))
  end

  defp fresh_root!(name) do
    root = Path.join(System.tmp_dir!(), "beam_weaver_deepagents_#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "workspace"))
    root
  end
end

BeamWeaver.Examples.DeepAgents.DeployCodingAgent.run()
