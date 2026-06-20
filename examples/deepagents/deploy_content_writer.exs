Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DeployContentWriter do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    root = fresh_root!("deploy_content_writer")
    File.mkdir_p!(Path.join(root, "user"))
    File.write!(Path.join(root, "AGENTS.md"), "Global content policy: be specific and concise.\n")
    File.write!(Path.join([root, "user", "AGENTS.md"]), "User memory: prefers launch posts.\n")

    {:ok, agent} =
      Support.create(
        name: "deploy-content-writer",
        model: Support.model(),
        filesystem: Local.new(root: root),
        memory: ["/AGENTS.md", "/user/AGENTS.md"]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("Draft a launch announcement.")]})

    IO.puts(Message.text(List.last(messages)))
  end

  defp fresh_root!(name) do
    root = Path.join(System.tmp_dir!(), "beam_weaver_deepagents_#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end

BeamWeaver.Examples.DeepAgents.DeployContentWriter.run()
