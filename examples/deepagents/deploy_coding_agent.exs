# A coding agent on a real directory: it reads the project, fixes a failing
# test by editing the code, and follows the conventions in /AGENTS.md.
# Filesystem permissions allow writes under /workspace only.
#
#   mix run examples/deepagents/deploy_coding_agent.exs

Code.require_file("support/support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.DeployCodingAgent do
  alias BeamWeaver.Agent
  alias BeamWeaver.Examples.DeepAgents.Support
  alias BeamWeaver.Filesystem.Local
  alias BeamWeaver.Filesystem.Permission

  def run do
    root = Support.fresh_root!("deploy_coding_agent")
    seed_project!(root)

    {:ok, agent} =
      Support.create(
        name: "coding-agent",
        model: Support.model(),
        filesystem: Local.new(root: root),
        memory: ["/AGENTS.md"],
        filesystem_permissions: [
          Permission.new(operations: [:write], paths: ["/workspace/**"], mode: :allow),
          Permission.new(operations: [:write], paths: ["/**"], mode: :deny)
        ],
        system_prompt: """
        You are an Elixir developer working in /workspace. You have no shell, so you can't run the \
        tests: read the failing test and the code, fix the code with the smallest change, and say \
        what you changed.
        """
      )

    {:ok, %{messages: messages}} =
      Agent.invoke(agent, %{
        messages: ["The test in /workspace/test/greeter_test.exs fails. Fix the code so it passes."]
      })

    IO.puts(Support.assert_text!(List.last(messages)))
    IO.puts("\n/workspace/lib/greeter.ex:\n#{File.read!(Path.join(root, "workspace/lib/greeter.ex"))}")
    Support.assert_tools_called!(messages, ["read_file", ["edit_file", "write_file"]])
    Code.compile_file(Path.join(root, "workspace/lib/greeter.ex"))
    "Hello, Ada!" = apply(Greeter, :hello, ["Ada"])
  end

  defp seed_project!(root) do
    File.write!(Path.join(root, "AGENTS.md"), """
    # Conventions
    - Read a file before you edit it.
    - Keep changes minimal; never edit tests to make them pass.
    """)

    File.mkdir_p!(Path.join(root, "workspace/lib"))
    File.mkdir_p!(Path.join(root, "workspace/test"))

    File.write!(Path.join(root, "workspace/lib/greeter.ex"), """
    defmodule Greeter do
      def hello(name), do: "Hi " <> name
    end
    """)

    File.write!(Path.join(root, "workspace/test/greeter_test.exs"), """
    defmodule GreeterTest do
      use ExUnit.Case

      test "greets by name" do
        assert Greeter.hello("Ada") == "Hello, Ada!"
      end
    end
    """)
  end
end

BeamWeaver.Examples.DeepAgents.DeployCodingAgent.run()
