defmodule BeamWeaver.Tools.Shell.SessionResumeTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.HITL
  alias BeamWeaver.Agent.Middleware.ShellTool
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Tools.Shell.Sessions

  @moduletag :tmp_dir

  test "the shell session survives a human-review pause and resume without leaking", %{
    tmp_dir: dir
  } do
    thread_id = "shell-resume-#{System.unique_integer([:positive])}"
    key = Sessions.key(thread_id, :shell_session, "shell")

    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{
          responses: [FakeChatModel.tool_call("shell", %{"command" => "echo hi"}), "done"]
        },
        middleware: [{ShellTool, policy: [allow: ["echo"]], workspace_root: dir}],
        interrupt_on: %{"shell" => true}
      )

    opts = [
      checkpointer: Checkpoint.ETS.new(),
      config: %{"configurable" => %{"thread_id" => thread_id}}
    ]

    assert {:interrupted, _} = Agent.invoke(agent, %{messages: ["run echo"]}, opts)

    # The paused run keeps its session registered for the thread.
    assert {:ok, _pid} = Sessions.fetch(key)

    {:ok, result} = Agent.resume_review(agent, [HITL.decision(:approve)], opts)

    # The tool worked on resume (the session was found, not reported missing).
    tool_text =
      result.messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.map(&Message.text/1)
      |> Enum.join()

    assert tool_text =~ "hi"
    refute tool_text =~ "not available"

    # The completed run stopped its session rather than leaking it.
    assert :error = Sessions.fetch(key)
  end
end
