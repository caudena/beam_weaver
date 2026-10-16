# A writing agent with two memory files: a team policy in /AGENTS.md and the
# user's preferences in /user/AGENTS.md. Both are loaded into the system
# prompt; the agent saves its draft as a file.
#
#   mix run examples/deepagents/deploy_content_writer.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DeployContentWriter do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Examples.DeepAgents.Support
  alias BeamWeaver.Filesystem.Local

  def run do
    root = Support.fresh_root!("deploy_content_writer")
    File.mkdir_p!(Path.join(root, "user"))
    File.write!(Path.join(root, "AGENTS.md"), "Team policy: be specific and concise. Save every draft under /drafts.\n")
    File.write!(Path.join(root, "user/AGENTS.md"), "User preference: sign every post as \"The BeamWeaver team\".\n")

    {:ok, agent} =
      Support.create(
        name: "content-writer",
        model: Support.model(),
        filesystem: Local.new(root: root),
        memory: ["/AGENTS.md", "/user/AGENTS.md"],
        system_prompt: "You write posts. Follow the team policy and the user's preferences in your memory files."
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: ["Draft a two-sentence announcement for BeamWeaver 1.0 and save it."]})

    IO.puts(Message.text(List.last(messages)))

    for draft <- Path.wildcard(Path.join(root, "drafts/*")),
        do: IO.puts("\n#{Path.relative_to(draft, root)}:\n#{File.read!(draft)}")

    Support.assert_tools_called!(messages, ["write_file"])
  end
end

BeamWeaver.Examples.DeepAgents.DeployContentWriter.run()
