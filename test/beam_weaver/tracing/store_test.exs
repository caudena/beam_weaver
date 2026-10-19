defmodule BeamWeaver.Tracing.StoreTest do
  use ExUnit.Case, async: false

  import BeamWeaver.TestSupport.ConfigHelper
  import BeamWeaver.TestSupport.Eventually

  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Test.StoreExporter
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Context
  alias BeamWeaver.Tracing.Run
  alias BeamWeaver.Tracing.Store

  setup do
    Tracing.clear()
    Context.clear()

    on_exit(fn ->
      Tracing.clear()
      Context.clear()
    end)
  end

  test "drops the runs that finished first once max_runs is exceeded, never a run in progress" do
    merge_config(:tracing, max_runs: 2)

    {:ok, running} = Tracing.start_run("running")
    Context.clear()

    [first, second, third] = Enum.map(~w(first second third), &finished_run/1)

    assert {:ok, %{status: :running}} = Tracing.get_run(running.id)
    assert Tracing.get_run(first.id) == :error
    assert Tracing.get_run(second.id) == :error
    assert {:ok, %{status: :ok}} = Tracing.get_run(third.id)

    assert {:ok, %{status: :ok}} = Tracing.finish_run(running)
    assert {:ok, _run} = Tracing.get_run(running.id)
    assert {:ok, _run} = Tracing.get_run(third.id)
  end

  test "max_runs: 0 keeps only the runs in progress" do
    merge_config(:tracing, max_runs: 0)

    {:ok, root} = Tracing.start_run("root")
    {:ok, child} = Tracing.start_run("child")

    assert {:ok, %{run: %{id: root_id}, children: [%{run: %{id: child_id}}]}} = Tracing.get_tree(root.id)
    assert {root_id, child_id} == {root.id, child.id}

    assert {:ok, _child} = Tracing.finish_run(child)
    assert Tracing.get_run(child.id) == :error
    assert {:ok, %{children: []}} = Tracing.get_tree(root.id)

    assert {:ok, _root} = Tracing.finish_run(root)
    assert Tracing.get_run(root.id) == :error
  end

  test "repeated agent calls keep the store within max_runs" do
    merge_config(:tracing, max_runs: 5)

    for _call <- 1..5 do
      assert {:ok, _result} = BeamWeaver.Test.TracedAgent.invoke(%{messages: ["hi"]})
    end

    assert length(Store.list()) == 5
  end

  test "clear/0 drops every run" do
    run = finished_run("cleared")
    assert {:ok, _run} = Tracing.get_run(run.id)

    assert :ok = Tracing.clear()
    assert Tracing.get_run(run.id) == :error
  end

  test "a run left running by a process that exits fails with the exit reason" do
    test = self()

    {owner, ref} =
      spawn_monitor(fn ->
        {:ok, run} = Tracing.start_run("orphaned")
        send(test, {:run, run})
        Process.sleep(:infinity)
      end)

    assert_receive {:run, run}
    assert {:ok, %{status: :running}} = Tracing.get_run(run.id)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

    assert eventually(fn -> match?({:ok, %{status: :error}}, Tracing.get_run(run.id)) end)
    assert {:ok, %{error: %{kind: :exit, reason: ":killed"}, ended_at: %DateTime{}}} = Tracing.get_run(run.id)
  end

  test "runs inside a node killed at its timeout leave the store like finished runs" do
    merge_config(:tracing, max_runs: 0)

    for _call <- 1..3 do
      assert {:error, %{type: :node_timeout}} = Compiled.invoke(stuck_graph(), %{})
    end

    assert eventually(fn -> Store.list() == [] end)
  end

  test "the store watches a process only while it has a run in progress" do
    store = Process.whereis(Store)

    {:ok, run} = Tracing.start_run("watched")
    assert {:process, self()} in monitors(store)

    assert {:ok, _run} = Tracing.finish_run(run)
    refute {:process, self()} in monitors(store)
  end

  describe "exporters and runs whose process exits" do
    test "each run left running gets one :error event with the exit reason" do
      exporter = [exporter: StoreExporter, exporter_opts: [test_pid: self()]]

      {owner, [root, child]} =
        start_owner(fn ->
          {:ok, root} = Tracing.start_run("root", exporter)
          {:ok, child} = Tracing.start_run("child", exporter)
          [root, child]
        end)

      assert_receive {:exported, :started, %Run{id: root_id}}
      assert_receive {:exported, :started, %Run{id: child_id}}
      assert {root_id, child_id} == {root.id, child.id}

      kill(owner)

      for id <- [root_id, child_id] do
        assert_receive {:exported, :error,
                        %Run{id: ^id, status: :error, ended_at: %DateTime{}, error: %{kind: :exit, reason: ":killed"}}}
      end

      refute_receive {:exported, _event, _run}, 100
      assert {:ok, %{status: :error}} = Tracing.get_run(root_id)
    end

    test "a run finished before its process exits keeps its one end event" do
      exporter = [exporter: StoreExporter, exporter_opts: [test_pid: self()]]

      {owner, [open, done]} =
        start_owner(fn ->
          {:ok, open} = Tracing.start_run("open", exporter)
          {:ok, done} = Tracing.start_run("done", exporter)
          {:ok, done} = Tracing.finish_run(done, exporter)
          [open, done]
        end)

      done_id = done.id
      open_id = open.id
      assert_receive {:exported, :ok, %Run{id: ^done_id}}

      kill(owner)

      assert_receive {:exported, :error, %Run{id: ^open_id}}
      refute_receive {:exported, :error, %Run{id: ^done_id}}, 100
      assert {:ok, %{status: :ok}} = Tracing.get_run(done_id)
    end

    test "a run finished normally exports as before, and the exit of its process sends nothing" do
      exporter = [exporter: StoreExporter, exporter_opts: [test_pid: self()]]

      {owner, run} =
        start_owner(fn ->
          {:ok, run} = Tracing.start_run("normal", exporter)
          {:ok, run} = Tracing.finish_run(run, exporter)
          run
        end)

      id = run.id
      assert_receive {:exported, :started, %Run{id: ^id, status: :running}}
      assert_receive {:exported, :ok, %Run{id: ^id, status: :ok}}

      kill(owner)
      refute_receive {:exported, _event, %Run{id: ^id}}, 100
    end

    test "an exporter that makes the :error event wait doesn't hold up the store" do
      exporter = [exporter: StoreExporter, exporter_opts: [test_pid: self(), wait_on: :error]]
      {owner, run} = start_owner(fn -> elem(Tracing.start_run("waiting", exporter), 1) end)

      kill(owner)

      assert_receive {:waiting, export_pid}
      assert {:ok, %{status: :error}} = Tracing.get_run(run.id)
      assert {:ok, _other} = Tracing.start_run("next")

      send(export_pid, :continue)
    end

    test "the store's status doesn't show the exporter options it keeps for running runs" do
      secret = "sk-live-0123456789abcdefghijklmn"

      {:ok, _run} =
        Tracing.start_run("keyed", exporter: StoreExporter, exporter_opts: [test_pid: self(), api_key: secret])

      refute inspect(:sys.get_status(Store)) =~ secret
    end

    test "the exported error is redacted" do
      exporter = [exporter: StoreExporter, exporter_opts: [test_pid: self()]]
      {owner, run} = start_owner(fn -> elem(Tracing.start_run("leaky", exporter), 1) end)
      ref = Process.monitor(owner)

      Process.exit(owner, {:shutdown, "Bearer sk-live-0123456789abcdefghijklmn"})
      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}

      id = run.id
      assert_receive {:exported, :error, %Run{id: ^id, error: %{kind: :exit, reason: reason}}}
      refute reason =~ "sk-live"
      assert reason =~ BeamWeaver.Transport.Redactor.redacted()
    end

    test "the configured exporter gets the :error event of a run in a node killed at its timeout" do
      merge_config(:tracing, exporter: StoreExporter, exporter_opts: [test_pid: self()])

      assert {:error, %{type: :node_timeout}} = Compiled.invoke(stuck_graph(), %{})

      assert_receive {:exported, :started, %Run{name: "stuck call", id: id}}
      assert_receive {:exported, :error, %Run{id: ^id, error: %{kind: :exit}}}, 1_000
      refute_receive {:exported, _event, %Run{id: ^id}}, 100
    end
  end

  defp stuck_graph do
    Graph.new()
    |> Graph.add_node(:slow, fn _state -> Tracing.with_run("stuck call", fn -> Process.sleep(:infinity) end) end,
      timeout: 20
    )
    |> Graph.add_edge(Graph.start(), :slow)
    |> Graph.add_edge(:slow, Graph.end_node())
    |> Graph.compile!()
  end

  # Runs `fun` in a new process that then waits until it is killed, and
  # returns that process and what `fun` returned.
  defp start_owner(fun) do
    test = self()

    owner =
      spawn(fn ->
        send(test, {:owner_result, fun.()})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_result, result}
    {owner, result}
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp monitors(pid) do
    {:monitors, monitors} = Process.info(pid, :monitors)
    monitors
  end

  defp finished_run(name) do
    {:ok, run} = Tracing.start_run(name)
    {:ok, run} = Tracing.finish_run(run)
    run
  end
end

defmodule BeamWeaver.Test.TracedAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["hello"]
end

defmodule BeamWeaver.Test.StoreExporter do
  @behaviour BeamWeaver.Tracing.Exporter

  # With `wait_on: event`, the export of that event waits for `:continue`,
  # like an exporter whose buffer is full.
  @impl true
  def export(event, run, opts) do
    test = Keyword.fetch!(opts, :test_pid)
    send(test, {:exported, event, run})

    if opts[:wait_on] == event do
      send(test, {:waiting, self()})

      receive do
        :continue -> :ok
      end
    end

    :ok
  end
end
