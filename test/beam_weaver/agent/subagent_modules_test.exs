defmodule BeamWeaver.Agent.SubagentModulesTest.HandOff do
  # Hands "Plan the trip." to the subagent `to`, answers with the result it
  # gets back, and answers anything else with `answer`.
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message

  defstruct [:to, :answer]

  @impl true
  def invoke(%__MODULE__{to: to, answer: answer}, messages, _opts) do
    cond do
      result = Enum.find(messages, &(&1.role == :tool)) ->
        {:ok, Message.assistant("Done: " <> Message.text(result))}

      Message.text(List.last(messages)) == "Plan the trip." ->
        args = %{"subagent_type" => to, "description" => "Check the plan."}
        {:ok, Message.assistant("", tool_calls: [%{id: "task-1", name: "task", args: args}])}

      true ->
        {:ok, Message.assistant(answer)}
    end
  end
end

defmodule BeamWeaver.Agent.SubagentModulesTest.Planner do
  use BeamWeaver.Agent

  name "planner"
  description "Plans trips."
  model %BeamWeaver.Agent.SubagentModulesTest.HandOff{to: "checker", answer: "Planned."}

  subagents do
    subagent BeamWeaver.Agent.SubagentModulesTest.Checker
  end
end

defmodule BeamWeaver.Agent.SubagentModulesTest.Checker do
  use BeamWeaver.Agent

  name "checker"
  description "Checks plans."
  model %BeamWeaver.Agent.SubagentModulesTest.HandOff{to: "planner", answer: "Checked."}

  subagents do
    subagent BeamWeaver.Agent.SubagentModulesTest.Planner
  end
end

defmodule BeamWeaver.Agent.SubagentModulesTest.Researcher do
  use BeamWeaver.Agent

  name "researcher"
  description "Researches a question, with help from another researcher."
  model %BeamWeaver.Agent.SubagentModulesTest.HandOff{to: "researcher", answer: "Researched."}

  subagents do
    subagent BeamWeaver.Agent.SubagentModulesTest.Researcher
  end
end

defmodule BeamWeaver.Agent.SubagentModulesTest.SlowLookup do
  use BeamWeaver.Tool

  name "slow_lookup"
  description "Looks a thing up, slowly."

  schema do
    field :id, :string
  end

  @impl true
  def invoke(_tool, _args, _opts) do
    Process.sleep(1_000)
    {:ok, "found it"}
  end
end

defmodule BeamWeaver.Agent.SubagentModulesTest.LookupModel do
  # Calls slow_lookup, then answers with what the tool call returned.
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message

  defstruct []

  @impl true
  def invoke(%__MODULE__{}, messages, _opts) do
    case Enum.find(messages, &(&1.role == :tool)) do
      nil ->
        call = %{id: "lookup-1", name: "slow_lookup", args: %{"id" => "A-1"}}
        {:ok, Message.assistant("", tool_calls: [call])}

      result ->
        {:ok, Message.assistant(Message.text(result))}
    end
  end
end

defmodule BeamWeaver.Agent.SubagentModulesTest.Clerk do
  use BeamWeaver.Agent

  name "clerk"
  description "Looks orders up."
  model %BeamWeaver.Agent.SubagentModulesTest.LookupModel{}
  tools [BeamWeaver.Agent.SubagentModulesTest.SlowLookup]
  tool_timeout 50
  step_timeout 30_000
  run_timeout 60_000
  capability_profile :auto
end

defmodule BeamWeaver.Agent.SubagentModulesTest.Desk do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [FakeChatModel.tool_call("task", %{"subagent_type" => "clerk", "description" => "Find A-1."}), "Done."]

  subagents do
    subagent BeamWeaver.Agent.SubagentModulesTest.Clerk
  end
end

defmodule BeamWeaver.Agent.SubagentModulesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Agent.SubagentModulesTest.Checker
  alias BeamWeaver.Agent.SubagentModulesTest.Clerk
  alias BeamWeaver.Agent.SubagentModulesTest.Desk
  alias BeamWeaver.Agent.SubagentModulesTest.Planner
  alias BeamWeaver.Agent.SubagentModulesTest.Researcher
  alias BeamWeaver.Core.Message

  # Reading agents that name each other used to never finish.
  defp within_5_seconds(fun) do
    task = Task.async(fun)
    Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) || flunk("did not finish in 5 seconds")
  end

  defp tool_texts(result), do: for(%Message{role: :tool} = message <- result.messages, do: Message.text(message))

  describe "agent modules that name each other as subagents" do
    test "each runs and hands work to the other" do
      assert {:ok, {:ok, planned}} = within_5_seconds(fn -> Planner.invoke(%{messages: ["Plan the trip."]}) end)
      assert tool_texts(planned) == ["Checked."]

      assert {:ok, {:ok, checked}} = within_5_seconds(fn -> Checker.invoke(%{messages: ["Plan the trip."]}) end)
      assert tool_texts(checked) == ["Planned."]
    end

    test "an agent can be built with one of them" do
      assert {:ok, {:ok, agent}} =
               within_5_seconds(fn ->
                 Agent.build(model: "fake:chat", subagents: [Spec.from_agent_module(Planner)])
               end)

      assert %Agent.Built{} = agent
    end

    test "an agent module can name itself" do
      assert {:ok, {:ok, result}} = within_5_seconds(fn -> Researcher.invoke(%{messages: ["Plan the trip."]}) end)
      assert tool_texts(result) == ["Researched."]
      assert result.messages |> List.last() |> Message.text() == "Done: Researched."
    end
  end

  describe "a subagent module keeps its time limits and capability profile" do
    test "from_agent_module reads them" do
      spec = Spec.from_agent_module(Clerk)

      assert {spec.tool_timeout, spec.step_timeout, spec.run_timeout, spec.capability_profile} ==
               {50, 30_000, 60_000, :auto}

      assert %Spec{tool_timeout: 50} = Spec.new(name: "clerk", description: "Looks orders up.", tool_timeout: 50)
    end

    test "its tool_timeout limits its tool calls when it runs as a subagent" do
      assert {:ok, result} = Desk.invoke(%{messages: ["Where is A-1?"]})
      assert ["Tool error: tool timed out" <> _] = tool_texts(result)
    end
  end
end
