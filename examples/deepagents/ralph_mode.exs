Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.RalphMode do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    root = fresh_root!("ralph_mode")

    File.write!(
      Path.join(root, "PROMPT.md"),
      "Build a small course outline. Use files as memory.\n"
    )

    {:ok, agent} =
      Support.create(
        name: "ralph-mode",
        model: Support.model("ralph_mode: completed one fresh-context loop"),
        filesystem: Local.new(root: root),
        memory: ["/PROMPT.md"],
        recursion_limit: 20
      )

    for iteration <- 1..2 do
      {:ok, %{messages: messages}} =
        Agent.invoke(agent, %{messages: [Message.user(File.read!(Path.join(root, "PROMPT.md")))]})

      File.write!(
        Path.join(root, "WORKLOG.md"),
        "iteration #{iteration}: #{Message.text(List.last(messages))}\n",
        [:append]
      )
    end

    IO.puts(File.read!(Path.join(root, "WORKLOG.md")) |> String.trim())
  end

  defp fresh_root!(name) do
    root = Path.join(System.tmp_dir!(), "beam_weaver_deepagents_#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end

BeamWeaver.Examples.DeepAgents.RalphMode.run()
