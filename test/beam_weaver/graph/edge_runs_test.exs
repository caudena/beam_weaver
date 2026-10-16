defmodule BeamWeaver.Graph.EdgeRunsTest do
  # `max_runs:` limits how often one run takes a guarded edge. A new run on the
  # thread counts from zero; the same run, continued after an interrupt, a
  # failure or an update, keeps its counts.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias BeamWeaver.Checkpoint.ETS
  alias BeamWeaver.Checkpoint.Ecto, as: EctoCheckpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Test.LiveSQLite
  alias BeamWeaver.Test.SQLiteRepo

  for adapter <- [:ets, :sqlite] do
    describe "#{adapter} saver" do
      setup do
        {:ok, saver: new_saver(unquote(adapter))}
      end

      test "each new run on a thread may take the edge max_runs times", %{saver: saver} do
        graph = review_loop(saver)
        config = thread_config()

        assert {:ok, %{reviews: 2, done: true}} = Compiled.invoke(graph, %{reviews: 0}, config: config)
        assert {:ok, %{reviews: 4}} = Compiled.invoke(graph, %{reviews: 0}, config: config)

        # An empty input on a finished thread starts a new run too.
        assert {:ok, %{reviews: 6}} = Compiled.invoke(graph, %{}, config: config)
      end

      test "a run resumed after an interrupt keeps its count", %{saver: saver} do
        graph = review_loop(saver, interrupt_after: [:review])
        config = thread_config()

        assert {:interrupted, %{nodes: ["review"]}} = Compiled.invoke(graph, %{reviews: 0}, config: config)
        assert {:interrupted, %{nodes: ["review"]}} = Compiled.resume(graph, nil, config: config)
        assert {:ok, %{reviews: 2, done: true}} = Compiled.resume(graph, nil, config: config)
      end

      test "a run continued after a failure keeps its count", %{saver: saver} do
        for continue <- [&Compiled.invoke(&1, %{}, config: &2), &Compiled.resume(&1, nil, config: &2)] do
          graph = review_loop(saver, review: fails_on_call(2))
          config = thread_config()

          assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{reviews: 0}, config: config)
          assert {:ok, %{reviews: 2, done: true}} = continue.(graph, config)
        end
      end

      test "a node retried inside the loop keeps the run's count", %{saver: saver} do
        graph = review_loop(saver, review: fails_on_call(2), retry: [max_attempts: 2])

        assert {:ok, %{reviews: 2, done: true}} =
                 Compiled.invoke(graph, %{reviews: 0}, config: thread_config())
      end

      test "a run continued after update_state keeps its count", %{saver: saver} do
        graph =
          Graph.new()
          |> Graph.add_reducer(:drafts, &+/2)
          |> Graph.add_node(:draft, fn _state -> %{drafts: 1} end)
          |> Graph.add_node(:review, fn _state -> %{verdict: :revise} end)
          |> Graph.add_node(:escalate, fn _state -> %{escalated: true} end)
          |> Graph.add_edge(Graph.start(), :draft)
          |> Graph.add_edge(:draft, :review)
          |> Graph.add_edge(:review, :draft, when: %{verdict: :revise}, max_runs: 1)
          |> Graph.add_edge(:review, :escalate, default: true)
          |> Graph.add_edge(:escalate, Graph.end_node())
          |> Graph.compile!(checkpointer: saver, interrupt_after: [:draft])

        config = thread_config()

        assert {:interrupted, %{nodes: ["draft"]}} = Compiled.invoke(graph, %{drafts: 0}, config: config)

        # The second draft, after the loop's one run.
        assert {:interrupted, %{nodes: ["draft"]}} = Compiled.resume(graph, nil, config: config)

        assert {:ok, _config} = Compiled.update_state(graph, config, %{note: "Mention the refund date."})
        assert {:ok, %{next: ["review"]}} = Compiled.get_state(graph, config)
        assert {:ok, %{drafts: 2, escalated: true}} = Compiled.invoke(graph, %{}, config: config)
      end
    end
  end

  # `review` asks for another round each time; its loop edge may run once.
  defp review_loop(saver, opts \\ []) do
    {review, opts} = Keyword.pop(opts, :review, fn _state -> %{reviews: 1, status: :again} end)
    {retry, opts} = Keyword.pop(opts, :retry)

    Graph.new()
    |> Graph.add_reducer(:reviews, &+/2)
    |> Graph.add_node(:review, review, if(retry, do: [retry: retry], else: []))
    |> Graph.add_node(:done, fn _state -> %{done: true} end)
    |> Graph.add_edge(Graph.start(), :review)
    |> Graph.add_edge(:review, :review, when: %{status: :again}, max_runs: 1)
    |> Graph.add_edge(:review, :done, default: true)
    |> Graph.add_edge(:done, Graph.end_node())
    |> Graph.compile!([checkpointer: saver] ++ opts)
  end

  # A review node that fails on its `n`th call.
  defp fails_on_call(n) do
    calls = :counters.new(1, [])

    fn _state ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == n,
        do: {:error, Error.new(:outage, "the review service is down")},
        else: %{reviews: 1, status: :again}
    end
  end

  defp new_saver(:ets), do: ETS.new()

  defp new_saver(:sqlite) do
    checkpoints = LiveSQLite.unique_table("bw_edge_runs_checkpoints")
    writes = LiveSQLite.unique_table("bw_edge_runs_writes")

    version =
      LiveSQLite.migrate(
        repo: SQLiteRepo,
        adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]
      )

    on_exit(fn ->
      LiveSQLite.drop_tables([writes, checkpoints])
      LiveSQLite.clear_migration(version)
    end)

    EctoCheckpoint.new(repo: SQLiteRepo, checkpoints_table: checkpoints, writes_table: writes)
  end

  defp thread_config do
    %{"configurable" => %{"thread_id" => "review-#{System.unique_integer([:positive])}"}}
  end
end
