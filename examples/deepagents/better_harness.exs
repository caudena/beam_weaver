Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.BetterHarness do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Examples.DeepAgents.Support

  def run do
    root = fresh_root!("better_harness")
    File.write!(Path.join(root, "prompt.txt"), "You are a helpful target agent.\n")
    File.write!(Path.join(root, "tools.exs"), "# editable tool surface\n")

    experiment = %{
      name: "beam-weaver-harness",
      runner: "ex_unit",
      train_cases: ["case:addition", "case:retrieval"],
      holdout_cases: ["case:formatting"],
      surfaces: ["/prompt.txt", "/tools.exs"]
    }

    {:ok, outer_agent} =
      Support.create(
        name: "better-harness",
        model: Support.model(),
        filesystem: Local.new(root: root),
        system_prompt: "Improve only declared harness surfaces, then run train and holdout evals."
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(outer_agent, %{messages: [Message.user("Optimize #{experiment.name}.")]})

    IO.puts(Message.text(List.last(messages)))
  end

  defp fresh_root!(name) do
    root = Path.join(System.tmp_dir!(), "beam_weaver_deepagents_#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end
end

BeamWeaver.Examples.DeepAgents.BetterHarness.run()
