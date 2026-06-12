defmodule BeamWeaver.Runtime.AgentServerTest do
  use ExUnit.Case

  alias BeamWeaver.Runtime.Agent
  alias BeamWeaver.Runtime.Agent.Work
  alias BeamWeaver.Runtime.Error
  alias BeamWeaver.Tracing

  setup do
    Tracing.reset()

    on_exit(fn ->
      Tracing.reset()
    end)

    :ok
  end

  test "keeps the GenServer responsive while model work is blocked in a task" do
    agent = start_agent!()
    :ok = Agent.subscribe(agent)
    test_pid = self()

    assert {:ok, %Work{} = work} =
             Agent.start_model_call(
               agent,
               "input",
               fn input ->
                 send(test_pid, {:model_started, self()})

                 receive do
                   :finish -> {:ok, {:done, input}}
                 end
               end,
               timeout: 1_000
             )

    assert_receive {:model_started, task_pid}
    refute task_pid == agent

    assert %{active_count: 1, active_work: active_work} = Agent.status(agent)
    assert work.id in active_work

    send(task_pid, :finish)

    assert_receive {:beam_weaver_agent, _agent_id, {:completed, work_id, {:done, "input"}}}
    assert work_id == work.id
    assert %{active_count: 0, completed_count: 1} = Agent.status(agent)
  end

  test "model timeout cancels work and records a failed trace run" do
    agent = start_agent!()
    :ok = Agent.subscribe(agent)
    test_pid = self()

    assert {:ok, %Work{} = work} =
             Agent.start_model_call(
               agent,
               :slow,
               fn _input ->
                 send(test_pid, {:model_waiting, self()})

                 receive do
                   :never -> :ok
                 end
               end,
               timeout: 25
             )

    assert_receive {:model_waiting, task_pid}

    assert_receive {:beam_weaver_agent, _agent_id, {:failed, work_id, %Error{type: :timeout} = error}},
                   250

    assert work_id == work.id
    assert error.details.work_id == work.id
    refute Process.alive?(task_pid)

    assert {:ok, trace_run} = Tracing.get_run(work.trace_run_id)
    assert trace_run.status == :error
    assert trace_run.error.message =~ "work timed out"
  end

  test "tool work retries a crash and completes when the retry succeeds" do
    agent = start_agent!()
    :ok = Agent.subscribe(agent)
    test_pid = self()

    assert {:ok, work} =
             Agent.start_tool_call(
               agent,
               "flaky tool",
               41,
               fn input ->
                 attempt = Process.get(:attempt, 0) + 1
                 Process.put(:attempt, attempt)
                 send(test_pid, {:tool_attempt, attempt})

                 if attempt == 1 do
                   raise "temporary tool failure"
                 else
                   {:ok, input + 1}
                 end
               end,
               max_retries: 1
             )

    assert_receive {:tool_attempt, 1}
    assert_receive {:tool_attempt, 2}
    assert_receive {:beam_weaver_agent, _agent_id, {:completed, work_id, 42}}
    assert work_id == work.id

    assert {:ok, trace_run} = Tracing.get_run(work.trace_run_id)
    assert trace_run.status == :ok
  end

  test "tool crash without retries becomes a tagged runtime error" do
    agent = start_agent!()
    :ok = Agent.subscribe(agent)

    assert {:ok, work} =
             Agent.start_tool_call(agent, "bad tool", :input, fn _input ->
               raise "bad tool exploded"
             end)

    assert_receive {:beam_weaver_agent, _agent_id, {:failed, work_id, %Error{type: :exception} = error}}

    assert work_id == work.id
    assert error.message =~ "bad tool exploded"

    assert {:ok, trace_run} = Tracing.get_run(work.trace_run_id)
    assert trace_run.status == :error
  end

  test "cancellation stops active work cleanly" do
    agent = start_agent!()
    :ok = Agent.subscribe(agent)
    test_pid = self()

    assert {:ok, work} =
             Agent.start_model_call(
               agent,
               :input,
               fn _input ->
                 send(test_pid, {:cancellable_started, self()})

                 receive do
                   :finish -> :finished
                 end
               end,
               timeout: 1_000
             )

    assert_receive {:cancellable_started, task_pid}
    assert :ok = Agent.cancel(agent, work)

    assert_receive {:beam_weaver_agent, _agent_id, {:cancelled, work_id, %Error{type: :cancelled}}}

    assert work_id == work.id
    refute Process.alive?(task_pid)
    assert %{active_count: 0} = Agent.status(agent)
  end

  test "stream chunks are delivered before work completes" do
    agent = start_agent!()
    :ok = Agent.subscribe(agent)

    assert {:ok, work} =
             Agent.start_model_call(agent, "input", fn input, emit ->
               emit.({:delta, "first"})
               emit.({:delta, "second"})
               {:ok, {:final, input}}
             end)

    assert_receive {:beam_weaver_agent, _agent_id, {:stream, work_id, {:delta, "first"}}}
    assert work_id == work.id
    assert_receive {:beam_weaver_agent, _agent_id, {:stream, ^work_id, {:delta, "second"}}}
    assert_receive {:beam_weaver_agent, _agent_id, {:completed, ^work_id, {:final, "input"}}}
  end

  test "agent work preserves caller trace context as the parent run" do
    agent = start_agent!()
    :ok = Agent.subscribe(agent)
    {:ok, parent_run} = Tracing.start_run("request")

    assert {:ok, work} =
             Agent.start_model_call(agent, :input, fn _input ->
               {:ok, :done}
             end)

    assert_receive {:beam_weaver_agent, _agent_id, {:completed, work_id, :done}}
    assert work_id == work.id

    assert {:ok, %{run: root, children: [%{run: child}]}} = Tracing.get_tree(parent_run.id)
    assert root.id == parent_run.id
    assert child.id == work.trace_run_id
    assert child.parent_id == parent_run.id
    assert child.trace_id == parent_run.trace_id
  end

  defp start_agent! do
    start_supervised!({Agent, id: "test_agent_#{System.unique_integer([:positive])}"})
  end
end
