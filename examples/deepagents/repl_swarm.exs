Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.ReplSwarm do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    root = fresh_root!("repl_swarm")
    seed_swarm_skill!(root)

    worker =
      Spec.new(
        name: "general-purpose",
        description: "Handles one independent swarm item.",
        system_prompt: "Complete the assigned swarm item and return a compact result.",
        model: Support.model()
      )

    {:ok, agent} =
      Support.create(
        name: "repl-swarm",
        model: Support.model(),
        filesystem: Local.new(root: root),
        skills: ["/skills"],
        subagents: [worker]
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{messages: [Message.user("Use the swarm skill for three files.")]})

    IO.puts(Message.text(List.last(messages)))
  end

  defp seed_swarm_skill!(root) do
    dir = Path.join([root, "skills", "swarm"])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: swarm
    description: Use when dispatching many independent subagent tasks with bounded concurrency.
    metadata:
      module: ./index.ts
    ---
    Dispatch tasks in input order and cap concurrency.
    """)

    File.write!(
      Path.join(dir, "index.ts"),
      "export async function runSwarm(tasks) { return tasks; }\n"
    )
  end

  defp fresh_root!(name) do
    root = Path.join(System.tmp_dir!(), "beam_weaver_deepagents_#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end

BeamWeaver.Examples.DeepAgents.ReplSwarm.run()
