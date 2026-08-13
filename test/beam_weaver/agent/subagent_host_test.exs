defmodule BeamWeaver.Agent.SubagentHostTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.Subagents
  alias BeamWeaver.Agent.Subagent.Compiled
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Agent.Subagent.Host.{Handle, Result}
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Command

  defmodule Host do
    @behaviour BeamWeaver.Agent.Subagent.Host

    defstruct [:owner, :response]

    @impl true
    def admit_child(host, proposal, context) do
      send(host.owner, {:proposal, proposal, context})
      {:ok, %Handle{id: "child-1", mode: proposal.mode}}
    end

    @impl true
    def child_result(%{response: :pending}, handle, _context), do: {:pending, handle}

    def child_result(%{response: :completed}, handle, _context) do
      {:ok, %Result{handle_id: handle.id, outcome: :completed, content: "finished"}}
    end

    def child_result(%{response: :ask}, handle, _context) do
      {:ok, %Result{handle_id: handle.id, outcome: :needs_parent_input, content: "question"}}
    end
  end

  test "host mode compiles only explicit descriptors and installs no child cache state" do
    middleware =
      Subagents.new(
        host: %Host{owner: self(), response: :pending},
        child_mode: :background,
        subagents: [%Spec{name: "worker", description: "Worker"}]
      )

    assert [%Compiled{name: "worker", agent: :host_managed}] = middleware.subagents
    assert Subagents.state_schema(middleware) == %{}
  end

  test "host-managed subagents receive a closed proposal without parent state" do
    tool = task_tool(%Host{owner: self(), response: :completed}, :foreground)
    runtime = %{context: %{caller: "parent"}}

    assert {:ok, %Command{update: %{messages: [%Message{} = message]}}} =
             Tool.invoke(tool, %{
               "subagent_type" => "worker",
               "description" => "inspect files",
               state: %{secret_parent_state: true},
               runtime: runtime,
               tool_call_id: "call-1"
             })

    assert message.content == "finished"
    assert message.metadata.outcome == :completed

    assert_receive {:proposal, proposal, ^runtime}

    assert Map.from_struct(proposal) == %{
             schema_version: 1,
             type: "worker",
             task: "inspect files",
             mode: :foreground,
             correlation_id: "call-1"
           }
  end

  test "background hosts may return a durable pending handle but cannot ask the parent" do
    pending = task_tool(%Host{owner: self(), response: :pending}, :background)

    assert {:ok, %Command{update: %{messages: [%Message{} = message]}}} =
             Tool.invoke(pending, %{
               "subagent_type" => "worker",
               "description" => "wait for a result",
               state: %{},
               tool_call_id: "call-2"
             })

    assert message.metadata == %{
             outcome: :pending,
             child_handle_id: "child-1",
             child_mode: :background
           }

    asking = task_tool(%Host{owner: self(), response: :ask}, :background)

    assert {:ok, content} =
             Tool.invoke(asking, %{
               "subagent_type" => "worker",
               "description" => "ask",
               state: %{},
               tool_call_id: "call-3"
             })

    assert content =~ "invalid child result"
  end

  defp task_tool(host, mode) do
    middleware =
      Subagents.new(
        model: :unused,
        host: host,
        child_mode: mode,
        subagents: [
          %Compiled{name: "worker", description: "Worker", agent: :must_not_run}
        ]
      )

    middleware |> Subagents.tools() |> hd()
  end
end
