# A harness-tuning agent: it edits another agent's prompt file, runs the eval
# cases, and reports what passes.
#
# Filesystem permissions limit its writes to the declared surfaces,
# /prompt.txt and /tools.exs; everything else is read-only.
#
#   mix run examples/deepagents/better_harness.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.BetterHarness.RunEvals do
  use BeamWeaver.Tool

  name "run_evals"
  description "Run the target agent's eval cases against the current /prompt.txt and report which pass."

  schema do
    field :split, :string, enum: ["train", "holdout"], description: "Which eval cases to run"
  end

  # Each case checks the prompt text; a real harness would run the target agent.
  @cases %{
    "train" => [
      {"cites sources", ~r/source|cite|citation/i},
      {"answers concisely", ~r/concise|brief|short/i}
    ],
    "holdout" => [{"stays helpful", ~r/helpful/i}]
  }

  @impl true
  def invoke(_tool, %{"split" => split}, _opts) do
    prompt = File.read!(Path.join(BeamWeaver.Examples.DeepAgents.BetterHarness.root(), "prompt.txt"))

    {:ok,
     Enum.map_join(Map.fetch!(@cases, split), "\n", fn {name, check} ->
       "#{name}: #{if prompt =~ check, do: "pass", else: "FAIL"}"
     end)}
  end
end

defmodule BeamWeaver.Examples.DeepAgents.BetterHarness do
  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Examples.DeepAgents.BetterHarness.RunEvals
  alias BeamWeaver.Examples.DeepAgents.Support
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.Permission

  def root, do: Support.root("better_harness")

  def run do
    root = Support.fresh_root!("better_harness")
    File.write!(Path.join(root, "prompt.txt"), "You are a helpful assistant. Answer the user's question.\n")
    File.write!(Path.join(root, "tools.exs"), "# The target agent's tools: none yet.\n")

    {:ok, agent} =
      Support.create(
        name: "better-harness",
        model: Support.model(),
        filesystem: Local.new(root: root),
        filesystem_permissions: [
          Permission.new(operations: [:write], paths: ["/prompt.txt", "/tools.exs"], mode: :allow),
          Permission.new(operations: [:write], paths: ["/**"], mode: :deny)
        ],
        tools: [RunEvals],
        system_prompt: """
        You tune the harness of a target agent. Its prompt is /prompt.txt and its tools are \
        /tools.exs; you may change only those files. run_evals tests the files on disk, so a \
        change counts only once you have saved it with edit_file; describing a change in your \
        reply changes nothing.

        Work in this order:
        1. Read /prompt.txt.
        2. Change it with edit_file (write_file only creates new files).
        3. Run the train evals, then the holdout evals.
        4. If a case fails, edit the file again and rerun the evals.
        Then report the final results.
        """
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{
        messages: ["The target agent never cites sources and its answers ramble. Improve its prompt."]
      })

    IO.puts(Message.text(List.last(messages)))
    IO.puts("\n/prompt.txt now reads:\n#{File.read!(Path.join(root, "prompt.txt"))}")
    Support.assert_tools_called!(messages, [["edit_file", "write_file"], "run_evals"])
  end
end

BeamWeaver.Examples.DeepAgents.BetterHarness.run()
