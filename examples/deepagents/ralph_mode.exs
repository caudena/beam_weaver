# "Ralph mode": run the same prompt again and again, each time in a fresh
# conversation. Nothing carries over except the files, so the agent reads its
# earlier work from disk and continues it.
#
#   mix run examples/deepagents/ralph_mode.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.RalphMode do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Examples.DeepAgents.Support
  alias BeamWeaver.Filesystem.Local

  @iterations 2

  def run do
    root = Support.fresh_root!("ralph_mode")

    File.write!(Path.join(root, "PROMPT.md"), """
    You are writing a course outline on Elixir processes in /course.md. Each run of this prompt
    adds one module, and this conversation is one run:
    1. Read /course.md if it exists.
    2. Add one new module after the last one: a numbered title and one sentence.
    3. Save /course.md with write_file (a new file) or edit_file (an existing one).
    Once the save succeeds, this run is done: say which module you added and stop. Never add
    more than one module per run.
    """)

    {:ok, agent} = Support.create(name: "ralph", model: Support.model(), filesystem: Local.new(root: root))

    for iteration <- 1..@iterations do
      {:ok, %{messages: messages}} =
        Agent.invoke(agent, %{messages: [File.read!(Path.join(root, "PROMPT.md"))]})

      IO.puts("Run #{iteration}: #{Message.text(List.last(messages))}")
      Support.assert_tools_called!(messages, [["write_file", "edit_file"]])
    end

    IO.puts("\n/course.md:\n#{File.read!(Path.join(root, "course.md"))}")
  end
end

BeamWeaver.Examples.DeepAgents.RalphMode.run()
