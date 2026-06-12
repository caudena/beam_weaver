Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DownloadingAgents do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    root = fresh_root!("downloading_agents")
    package_dir = Path.join(root, "content-writer")
    File.mkdir_p!(package_dir)
    File.write!(Path.join(package_dir, "AGENTS.md"), "Downloaded agent instructions.\n")

    {:ok, agent} =
      Support.create(
        name: "downloaded-content-writer",
        model: Support.model("downloading_agents: unpacked folder agent is runnable"),
        filesystem: Local.new(root: package_dir),
        memory: ["/AGENTS.md"]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("Run the downloaded content writer.")]})

    IO.puts(Message.text(List.last(messages)))
  end

  defp fresh_root!(name) do
    root = Path.join(System.tmp_dir!(), "beam_weaver_deepagents_#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end

BeamWeaver.Examples.DeepAgents.DownloadingAgents.run()
