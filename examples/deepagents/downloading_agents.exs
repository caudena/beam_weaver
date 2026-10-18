# An agent shipped as files: a folder with AGENTS.md (its instructions) and
# skills/ is all it takes. Point a filesystem backend at the folder and load
# both; the code that runs it stays the same for any downloaded agent.
#
#   mix run examples/deepagents/downloading_agents.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DownloadingAgents do
  alias BeamWeaver.Agent
  alias BeamWeaver.Examples.DeepAgents.Support
  alias BeamWeaver.Filesystem.Local

  def run do
    package = Support.fresh_root!("downloading_agents")
    unpack_package!(package)

    {:ok, agent} =
      Support.create(
        name: "downloaded-agent",
        model: Support.model(),
        filesystem: Local.new(root: package),
        memory: ["/AGENTS.md"],
        skills: ["/skills"],
        system_prompt: "You are the agent defined in this folder: /AGENTS.md holds your instructions. Follow them."
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: ["Write a tagline for a reusable steel water bottle and save it."]})

    IO.puts(Support.assert_text!(List.last(messages)))

    for draft <- Path.wildcard(Path.join(package, "drafts/*")),
        do: IO.puts("\n#{Path.relative_to(draft, package)}:\n#{File.read!(draft)}")

    Support.assert_tools_called!(messages, ["write_file"])
    Support.assert_files!(Path.join(package, "drafts/*"))
  end

  # Stands in for downloading and unpacking an agent package.
  defp unpack_package!(package) do
    File.write!(Path.join(package, "AGENTS.md"), """
    You are a copywriter. The client collects your work from the /drafts folder, not from the chat, \
    so before you reply, save every piece you write with write_file to /drafts/<short-slug>.md. \
    A piece that is not saved there is lost. Then show the piece to the user.
    """)

    File.mkdir_p!(Path.join(package, "skills/tagline"))

    File.write!(Path.join(package, "skills/tagline/SKILL.md"), """
    ---
    name: tagline
    description: Use when writing a tagline or slogan.
    ---
    1. Write three options of at most eight words each and mark the best one.
    2. Save the options, best one marked, as a draft with write_file.
    3. Reply with the options and the draft's path.
    """)
  end
end

BeamWeaver.Examples.DeepAgents.DownloadingAgents.run()
