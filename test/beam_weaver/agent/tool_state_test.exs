defmodule BeamWeaver.Agent.ToolStateTest do
  # The state an agent's tools get: the state as the run returns it, without
  # the agent's private and managed keys, which a tool reads by naming them.
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware.ModelCallLimit
  alias BeamWeaver.Agent.Middleware.ShellTool
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models.FakeChatModel

  defmodule Ledger do
    use BeamWeaver.Agent.Middleware

    alias BeamWeaver.Graph

    @impl true
    def name(_middleware), do: :ledger

    @impl true
    def state_schema(_middleware), do: %{ledger: Graph.private_channel(BeamWeaver.Graph.Channels.LastValue)}

    @impl true
    def before_agent(_middleware, _state, _runtime), do: %{ledger: "kept by the middleware"}
  end

  defp tool_message(result), do: Enum.find(result.messages, &(&1.role == :tool))

  test "a tool gets the state without private keys and reads one by naming it" do
    parent = self()

    audit =
      Tool.from_function!(
        name: "audit",
        description: "Audits the conversation.",
        input_schema: %{"type" => "object", "properties" => %{}},
        injected: %{state: :state, ledger: {:state, :ledger}, runtime: :tool_runtime},
        handler: fn input, _opts ->
          send(parent, {:audit, input})
          "Audited."
        end
      )

    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{responses: [FakeChatModel.tool_call("audit"), "Done."]},
        tools: [audit],
        middleware: [Ledger, {ModelCallLimit, run_limit: 3}]
      )

    assert {:ok, result} = Agent.invoke(agent, %{messages: ["Audit, please."], customer: "Ada"})
    assert Message.text(tool_message(result)) == "Audited."

    # Not `usage`, `tool_set`, `remaining_steps`, the call counts or the ledger.
    assert_received {:audit, input}
    assert input.state |> Map.keys() |> Enum.sort() == [:customer, :messages]
    assert input.runtime.state == input.state
    assert input.ledger == "kept by the middleware"
  end

  test "the shell tool finds the session the middleware keeps in a private key" do
    workspace = Path.join(System.tmp_dir!(), "beam_weaver_tool_state_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    {:ok, agent} =
      Agent.build(
        model: %FakeChatModel{responses: [FakeChatModel.tool_call("shell", %{"command" => "pwd"}), "Done."]},
        middleware: [{ShellTool, policy: [allow: ["pwd"]], workspace_root: workspace}]
      )

    assert {:ok, result} = Agent.invoke(agent, %{messages: ["Where are we?"]})
    assert %Message{metadata: %{status: "success"}} = message = tool_message(result)
    assert Message.text(message) =~ Path.basename(workspace)
  end
end
