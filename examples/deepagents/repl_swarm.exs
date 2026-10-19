# A swarm: the agent fans independent work out to several subagents at once
# and combines what they return. A skill in /skills/swarm tells it how.
#
# Least privilege: the coordinator may read only its skills, so the files are
# read by the workers, which share its filesystem without that restriction.
#
#   mix run examples/deepagents/repl_swarm.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.ReplSwarm do
  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware.Filesystem
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Examples.DeepAgents.Support
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.Permission

  def run do
    root = Support.fresh_root!("repl_swarm")
    seed_inbox_and_skill!(root)

    worker =
      Spec.new(
        name: "worker",
        description: "Does the work for one item, such as reading and summarizing one file.",
        system_prompt: "Do the one task you are given and return only its result.",
        model: Support.model(),
        base_middleware: [Filesystem],
        permissions: [],
        middleware: Support.limits()
      )

    {:ok, agent} =
      Support.create(
        name: "swarm",
        model: Support.model(),
        filesystem: Local.new(root: root),
        filesystem_permissions: [
          Permission.new(operations: [:read], paths: ["/skills/**"], mode: :allow),
          Permission.new(operations: [:read, :write], paths: ["/**"], mode: :deny)
        ],
        skills: ["/skills"],
        subagents: [worker],
        system_prompt: """
        You coordinate worker subagents through the task tool. You can read only /skills; the \
        workers can read every other file. Follow the swarm skill for work on many items.
        """
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{
        messages: [
          "Use the swarm skill to summarize each of these files in one line: " <>
            "/inbox/invoice.txt, /inbox/outage.txt, /inbox/hiring.txt"
        ]
      })

    IO.puts(Support.assert_text!(List.last(messages)))
    Support.assert_tools_called!(messages, ["task"])
    true = Enum.any?(messages, fn message -> Enum.count(message.tool_calls, &(&1.name == "task")) >= 3 end)
  end

  defp seed_inbox_and_skill!(root) do
    File.mkdir_p!(Path.join(root, "inbox"))
    File.write!(Path.join(root, "inbox/invoice.txt"), "Invoice 118: 3 licenses, 1,200 EUR, due 30 November.\n")

    File.write!(
      Path.join(root, "inbox/outage.txt"),
      "Checkout was down 14:02-14:19 UTC; a bad deploy was rolled back.\n"
    )

    File.write!(
      Path.join(root, "inbox/hiring.txt"),
      "Two senior Elixir engineers start on Monday in the Lisbon office.\n"
    )

    File.mkdir_p!(Path.join(root, "skills/swarm"))

    File.write!(Path.join(root, "skills/swarm/SKILL.md"), """
    ---
    name: swarm
    description: Use when the same job must be done for many independent items, such as files.
    ---
    1. List the items.
    2. Start one worker task per item, all in the same message so they run in parallel.
       Give each task the item's path and the exact output you want back.
    3. Combine the results in input order.
    """)
  end
end

BeamWeaver.Examples.DeepAgents.ReplSwarm.run()
