defmodule BeamWeaver.Graph.CheckpointKeysTest do
  # `Checkpoint.Ecto` stores checkpoints as JSON, which gives every map key back
  # as a string. A thread read back from it must still have the graph's own
  # keys, exactly as with `Checkpoint.ETS`.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias BeamWeaver.Checkpoint.ETS
  alias BeamWeaver.Checkpoint.Ecto, as: EctoCheckpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Messages
  alias BeamWeaver.Graph.Send
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Test.LivePostgres
  alias BeamWeaver.Test.LiveSQLite
  alias BeamWeaver.Test.PostgresRepo
  alias BeamWeaver.Test.SQLiteRepo

  defmodule Triage do
    use BeamWeaver.Schema

    field :category, :string
  end

  defmodule TriageAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: [FakeChatModel.final(%{category: "shipping"})]
    response_schema BeamWeaver.Graph.CheckpointKeysTest.Triage
  end

  for adapter <- [:ets, :sqlite, :postgres] do
    describe "#{adapter} saver" do
      if adapter == :postgres, do: @describetag(:postgres)

      setup do
        {:ok, saver: new_saver(unquote(adapter))}
      end

      test "get_state, history, resume and update_state keep the graph's keys", %{saver: saver} do
        test_pid = self()

        graph =
          Graph.new(state_schema: Messages.state_schema())
          |> Graph.add_reducer(:log, &(&1 ++ &2))
          |> Graph.add_node(:draft, fn _state -> %{reply: "Refund approved.", log: ["draft"]} end)
          |> Graph.add_node(:review, fn state ->
            send(test_pid, {:review_keys, Enum.sort(Map.keys(state))})
            %{approved: Graph.interrupt("Send this reply?") == "yes", log: ["review"]}
          end)
          |> Graph.add_edge(Graph.start(), :draft)
          |> Graph.add_edge(:draft, :review)
          |> Graph.add_edge(:review, Graph.end_node())
          |> Graph.compile!(checkpointer: saver)

        config = thread_config()

        assert {:interrupted, _interrupt} =
                 Compiled.invoke(graph, %{messages: ["Refund order A-1001"], log: []}, config: config)

        assert {:ok, snapshot} = Compiled.get_state(graph, config)
        assert Enum.sort(Map.keys(snapshot.values)) == [:log, :messages, :reply]
        assert [%Message{role: :user}] = snapshot.values.messages

        assert graph
               |> Compiled.get_state_history(config)
               |> Enum.flat_map(&Map.keys(&1.values))
               |> Enum.all?(&is_atom/1)

        assert {:ok, %{approved: true, log: ["draft", "review"], reply: "Refund approved."} = result} =
                 Compiled.resume(graph, "yes", config: config)

        assert Enum.all?(Map.keys(result), &is_atom/1)
        assert_receive {:review_keys, [:log, :messages, :reply]}
        assert_receive {:review_keys, [:log, :messages, :reply]}

        assert {:ok, _config} = Compiled.update_state(graph, config, %{reply: "Refund sent."})
        assert {:ok, snapshot} = Compiled.get_state(graph, config)
        assert Enum.sort(Map.keys(snapshot.values)) == [:approved, :log, :messages, :reply]
        assert snapshot.values.reply == "Refund sent."
      end

      test "a run that continues after a failure reads the graph's keys", %{saver: saver} do
        attempts = :counters.new(1, [])

        graph =
          Graph.new()
          |> Graph.add_node(:lookup, fn _state -> %{order_status: "shipped"} end)
          |> Graph.add_node(:notify, fn %{order_status: status} ->
            :counters.add(attempts, 1, 1)

            if :counters.get(attempts, 1) == 1,
              do: {:error, Error.new(:mail_down, "the mail server is down")},
              else: %{notice: "Your order #{status}."}
          end)
          |> Graph.add_node(:audit, fn %{order_status: status} -> %{audited: status} end)
          |> Graph.add_edge(Graph.start(), :lookup)
          |> Graph.add_edge(:lookup, :notify)
          |> Graph.add_edge(:lookup, :audit)
          |> Graph.add_edge(:notify, Graph.end_node())
          |> Graph.add_edge(:audit, Graph.end_node())
          |> Graph.compile!(checkpointer: saver)

        config = thread_config()

        assert {:error, %Error{type: :mail_down}} = Compiled.invoke(graph, %{}, config: config)

        assert {:ok, %{order_status: "shipped", notice: "Your order shipped.", audited: "shipped"}} =
                 Compiled.invoke(graph, %{}, config: config)
      end

      test "a Send task keeps its update's keys and its id", %{saver: saver} do
        test_pid = self()
        failures = :counters.new(1, [])

        graph =
          Graph.new()
          |> Graph.add_reducer(:results, &(&1 ++ &2))
          |> Graph.add_node(:fan_out, fn _state ->
            [
              %Send{node: :lookup, update: %{order_id: "A-1001"}},
              %Send{node: :refund, update: %{order_id: "A-1002", amount: 40}},
              %Send{node: :charge, update: %{order_id: "A-1003"}}
            ]
          end)
          |> Graph.add_node(:lookup, fn %{order_id: order_id} ->
            send(test_pid, {:lookup_ran, order_id})
            %{results: ["#{order_id} shipped"]}
          end)
          |> Graph.add_node(:refund, fn %{order_id: order_id, amount: amount} ->
            answer = Graph.interrupt("Refund $#{amount} for #{order_id}?")
            %{results: ["#{order_id} refund: #{answer}"]}
          end)
          |> Graph.add_node(:charge, fn %{order_id: order_id} ->
            :counters.add(failures, 1, 1)

            if :counters.get(failures, 1) == 1,
              do: {:error, Error.new(:card_declined, "the card was declined")},
              else: %{results: ["#{order_id} charged"]}
          end)
          |> Graph.add_edge(Graph.start(), :fan_out)
          |> Graph.add_edge(:lookup, Graph.end_node())
          |> Graph.add_edge(:refund, Graph.end_node())
          |> Graph.add_edge(:charge, Graph.end_node())
          |> Graph.compile!(checkpointer: saver)

        config = thread_config()

        # The failed charge fails the step, and the refund question waits.
        assert {:error, %Error{type: :card_declined}} = Compiled.invoke(graph, %{results: []}, config: config)

        assert_receive {:lookup_ran, "A-1001"}

        assert {:ok, snapshot} = Compiled.get_state(graph, config)
        assert [%{value: "Refund $40 for A-1002?"}] = snapshot.interrupts

        assert snapshot.next_tasks == [
                 %{"node" => "refund", "update" => %{order_id: "A-1002", amount: 40}},
                 %{"node" => "charge", "update" => %{order_id: "A-1003"}}
               ]

        assert {:ok, %{results: results}} = Compiled.resume(graph, "yes", config: config)

        assert Enum.sort(results) == ["A-1001 shipped", "A-1002 refund: yes", "A-1003 charged"]
        refute_received {:lookup_ran, _order_id}
      end

      test "a step that stopped partway still routes from the tasks that finished", %{saver: saver} do
        failures = :counters.new(1, [])

        graph =
          Graph.new()
          |> Graph.add_reducer(:log, &(&1 ++ &2))
          |> Graph.add_node(:classify, fn _state -> %Command{update: %{log: ["classify"]}, goto: :billing} end,
            destinations: [:billing]
          )
          |> Graph.add_node(:split, fn _state -> [%Send{node: :check, update: %{order_id: "A-1001"}}] end)
          |> Graph.add_node(:grade, fn _state -> %{grade: :a, log: ["grade"]} end)
          |> Graph.add_node(:flaky, fn _state ->
            :counters.add(failures, 1, 1)

            if :counters.get(failures, 1) == 1,
              do: {:error, Error.new(:outage, "flaky failed")},
              else: %{log: ["flaky"]}
          end)
          |> Graph.add_node(:billing, fn _state -> %{log: ["billing"]} end)
          |> Graph.add_node(:check, fn %{order_id: order_id} -> %{log: ["check #{order_id}"]} end)
          |> Graph.add_node(:celebrate, fn _state -> %{log: ["celebrate"]} end)
          |> Graph.add_edge(Graph.start(), :classify)
          |> Graph.add_edge(Graph.start(), :split)
          |> Graph.add_edge(Graph.start(), :grade)
          |> Graph.add_edge(Graph.start(), :flaky)
          |> Graph.add_edge(:grade, :celebrate, when: fn output, _state -> output.grade == :a end)
          |> Graph.compile!(checkpointer: saver)

        config = thread_config()

        assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{log: []}, config: config)
        assert {:ok, %{log: log}} = Compiled.invoke(graph, %{}, config: config)

        assert Enum.sort(log) ==
                 Enum.sort(["classify", "grade", "flaky", "billing", "check A-1001", "celebrate"])
      end

      test "an update as a node of a failed step is its result, also after a replay fails again",
           %{saver: saver} do
        graph =
          Graph.new()
          |> Graph.add_reducer(:log, &(&1 ++ &2))
          |> Graph.add_node(:grade, fn _state -> %{grade: :a, log: ["graded"]} end)
          |> Graph.add_node(:flaky, fn _state -> {:error, Error.new(:outage, "flaky failed")} end)
          |> Graph.add_node(:celebrate, fn _state -> %{log: ["celebrate"]} end)
          |> Graph.add_node(:review, fn _state -> %{log: ["review"]} end)
          |> Graph.add_edge(Graph.start(), :grade)
          |> Graph.add_edge(Graph.start(), :flaky)
          |> Graph.add_edge(:grade, :celebrate, when: %{grade: :a})
          |> Graph.add_edge(:grade, :review, when: %{grade: :b})
          |> Graph.compile!(checkpointer: saver)

        config = thread_config()

        assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{log: []}, config: config)
        {:ok, snapshot} = Compiled.get_state(graph, config)
        assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{}, config: snapshot.config)

        assert {:ok, _config} = Compiled.update_state(graph, config, %{grade: :b}, as_node: :grade)
        assert {:ok, _config} = Compiled.update_state(graph, config, %{log: ["flaky, by hand"]}, as_node: :flaky)
        assert {:ok, %{next: ["review"]}} = Compiled.get_state(graph, config)
        assert {:ok, %{log: ["graded", "flaky, by hand", "review"]}} = Compiled.invoke(graph, %{}, config: config)
      end

      test "update_state keeps a paused subgraph where it paused", %{saver: saver} do
        test_pid = self()

        approval =
          Graph.new(name: "Approval")
          |> Graph.add_reducer(:log, &(&1 ++ &2))
          |> Graph.add_node(:prepare, fn %{status: status} ->
            send(test_pid, {:prepared, status})
            %{log: ["prepared"]}
          end)
          |> Graph.add_node(:ask, fn _state -> %{log: ["asked: " <> Graph.interrupt("Refund?")]} end)
          |> Graph.add_edge(Graph.start(), :prepare)
          |> Graph.add_edge(:prepare, :ask)
          |> Graph.add_edge(:ask, Graph.end_node())
          |> Graph.compile!()

        graph =
          Graph.new()
          |> Graph.add_reducer(:log, &(&1 ++ &2))
          |> Graph.add_node(:approval, approval)
          |> Graph.add_edge(Graph.start(), :approval)
          |> Graph.add_edge(:approval, Graph.end_node())
          |> Graph.compile!(checkpointer: saver)

        config = thread_config()

        assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{log: [], status: :open}, config: config)
        assert_receive {:prepared, :open}
        assert {:ok, _config} = Compiled.update_state(graph, config, %{status: :escalated})

        assert {:ok, %{log: ["prepared", "asked: yes"], status: :escalated}} =
                 Compiled.resume(graph, "yes", config: config)

        refute_received {:prepared, _status}
      end

      test "maps nested in the state, interrupts and Send updates keep their keys", %{saver: saver} do
        test_pid = self()
        line = %{sku: "S-1", qty: 2}
        order = %{:id => "A-1001", :status => :open, :lines => [line], "gift_note" => "Happy birthday"}

        graph =
          Graph.new()
          |> Graph.add_reducer(:refunds, &(&1 ++ &2))
          |> Graph.add_node(:load, fn _state -> %{order: order, totals: %{1 => 40, 2 => 15}} end)
          |> Graph.add_node(:fan_out, fn %{order: order} ->
            [%Send{node: :refund, update: %{request: %{order_id: order.id, line: hd(order.lines)}}}]
          end)
          |> Graph.add_node(:refund, fn %{request: request} ->
            send(test_pid, {:refund_request, request})
            answer = Graph.interrupt(%{question: "Refund this line?", line: request.line})
            %{refunds: [%{line: request.line, answer: answer}]}
          end)
          |> Graph.add_edge(Graph.start(), :load)
          |> Graph.add_edge(:load, :fan_out)
          |> Graph.add_edge(:refund, Graph.end_node())
          |> Graph.compile!(checkpointer: saver)

        config = thread_config()

        assert {:interrupted, %{value: %{question: "Refund this line?", line: ^line}}} =
                 Compiled.invoke(graph, %{refunds: []}, config: config)

        assert_receive {:refund_request, %{order_id: "A-1001", line: ^line}}

        assert {:ok, snapshot} = Compiled.get_state(graph, config)
        assert snapshot.values == %{order: order, totals: %{1 => 40, 2 => 15}, refunds: []}
        assert [%{"node" => "refund", "update" => %{request: %{order_id: "A-1001", line: ^line}}}] = snapshot.next_tasks
        assert [%{value: %{question: "Refund this line?", line: ^line}}] = snapshot.interrupts

        assert graph
               |> Compiled.get_state_history(config)
               |> Enum.all?(&(Map.get(&1.values, :order, order) == order))

        # The resumed task reads its `Send` update back from the checkpoint.
        assert {:ok, %{refunds: [%{line: ^line, answer: %{approved: true}}]}} =
                 Compiled.resume(graph, %{approved: true}, config: config)

        assert_receive {:refund_request, %{order_id: "A-1001", line: ^line}}

        assert {:ok, _config} = Compiled.update_state(graph, config, %{order: %{order | status: :refunded}})
        assert {:ok, %{values: %{order: %{status: :refunded, lines: [^line]}}}} = Compiled.get_state(graph, config)
      end

      test "update_state on a paused thread updates as the node that ran last", %{saver: saver} do
        graph =
          Graph.new()
          |> Graph.add_node(:draft, fn _state -> %{reply: "Your refund is on its way."} end)
          |> Graph.add_node(:send_reply, fn %{reply: reply} -> %{sent: reply} end)
          |> Graph.add_edge(Graph.start(), :draft)
          |> Graph.add_edge(:draft, :send_reply)
          |> Graph.add_edge(:send_reply, Graph.end_node())
          |> Graph.compile!(checkpointer: saver, interrupt_after: [:draft])

        config = thread_config()

        assert {:interrupted, %{nodes: ["draft"]}} = Compiled.invoke(graph, %{}, config: config)
        assert {:ok, _config} = Compiled.update_state(graph, config, %{reply: "Refund sent today."})
        assert {:ok, %{next: ["send_reply"], metadata: %{"as_node" => "draft"}}} = Compiled.get_state(graph, config)
        assert {:ok, %{sent: "Refund sent today."}} = Compiled.resume(graph, nil, config: config)
      end

      # Checkpoints from before map keys kept their types: the state's atom
      # keys are listed in "atom_channels" and a `Send` update's in
      # "atom_keys"; nested maps have string keys.
      test "a checkpoint saved before map keys kept their types loads as before", %{saver: saver} do
        test_pid = self()

        graph =
          Graph.new()
          |> Graph.add_reducer(:refunds, &(&1 ++ &2))
          |> Graph.add_node(:fan_out, fn _state -> [] end)
          |> Graph.add_node(:refund, fn state ->
            send(test_pid, {:refund_state, Map.take(state, [:order, :request])})
            %{refunds: [state.request["order_id"]]}
          end)
          |> Graph.add_edge(Graph.start(), :fan_out)
          |> Graph.add_edge(:refund, Graph.end_node())
          |> Graph.compile!(checkpointer: saver)

        config = thread_config()

        legacy = %{
          "v" => 1,
          "id" => "legacy-checkpoint",
          "channel_values" => %{"order" => %{"id" => "A-1001", "status" => :open}, "refunds" => []},
          "atom_channels" => ["order", "refunds"],
          "channel_versions" => %{"order" => 1, "refunds" => 1},
          "versions_seen" => %{},
          "next" => ["refund"],
          "next_tasks" => [
            %{"node" => "refund", "update" => %{"request" => %{"order_id" => "A-1001"}}, "atom_keys" => ["request"]}
          ],
          "tasks" => [],
          "interrupts" => []
        }

        assert {:ok, _config} =
                 BeamWeaver.Checkpoint.put(saver, config, legacy, %{"source" => "loop", "step" => 0}, %{})

        assert {:ok, snapshot} = Compiled.get_state(graph, config)
        assert snapshot.values == %{order: %{"id" => "A-1001", "status" => :open}, refunds: []}
        assert snapshot.next_tasks == [%{"node" => "refund", "update" => %{request: %{"order_id" => "A-1001"}}}]

        assert {:ok, %{refunds: ["A-1001"]}} = Compiled.invoke(graph, %{}, config: config)

        assert_receive {:refund_state,
                        %{order: %{"id" => "A-1001", "status" => :open}, request: %{"order_id" => "A-1001"}}}
      end

      if adapter != :ets do
        test "a saved map key whose atom no longer exists loads as a string", %{saver: saver} do
          graph =
            Graph.new()
            |> Graph.add_node(:load, fn _state -> %{order: %{id: "A-1001", legacy_coupon_code: "SPRING"}} end)
            |> Graph.add_edge(Graph.start(), :load)
            |> Graph.add_edge(:load, Graph.end_node())
            |> Graph.compile!(checkpointer: saver)

          config = thread_config()
          assert {:ok, _state} = Compiled.invoke(graph, %{}, config: config)

          # As if the code that wrote the key had since renamed it.
          retired = "retired_coupon_#{System.unique_integer([:positive])}"
          rename_saved_key(saver, "legacy_coupon_code", retired)

          assert {:ok, snapshot} = Compiled.get_state(graph, config)
          assert snapshot.values.order == %{:id => "A-1001", retired => "SPRING"}
          assert_raise ArgumentError, fn -> String.to_existing_atom(retired) end
        end
      end

      test "an agent's thread keeps its messages and structured response", %{saver: saver} do
        opts = [checkpointer: saver, config: thread_config()]

        assert {:ok, _result} = TriageAgent.invoke(%{messages: ["Where is order A-1001?"]}, opts)
        assert {:ok, snapshot} = TriageAgent.get_state(opts)
        assert Enum.sort(Map.keys(snapshot.values)) == [:messages, :structured_response]
        assert snapshot.values.structured_response == %{"category" => "shipping"}

        assert {:ok, result} = TriageAgent.invoke(%{messages: ["And order A-1002?"]}, opts)
        assert Enum.map(result.messages, & &1.role) == [:user, :assistant, :user, :assistant]
      end
    end
  end

  defp new_saver(:ets), do: ETS.new()

  defp new_saver(:sqlite) do
    checkpoints = LiveSQLite.unique_table("bw_key_checkpoints")
    writes = LiveSQLite.unique_table("bw_key_writes")

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

  defp new_saver(:postgres) do
    assert LivePostgres.available?()

    checkpoints = LivePostgres.unique_table("bw_key_checkpoints")
    writes = LivePostgres.unique_table("bw_key_writes")
    version = LivePostgres.migrate(adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}])

    on_exit(fn ->
      LivePostgres.drop_tables([writes, checkpoints])
      LivePostgres.clear_migration(version)
    end)

    EctoCheckpoint.new(repo: PostgresRepo, checkpoints_table: checkpoints, writes_table: writes)
  end

  # Renames a map key in the saved JSON of every checkpoint and write.
  defp rename_saved_key(%EctoCheckpoint{repo: repo} = saver, from, to) do
    for {table, column} <- [{saver.checkpoints_table, "checkpoint"}, {saver.writes_table, "value"}] do
      sql =
        case repo do
          SQLiteRepo -> ~s[UPDATE "#{table}" SET #{column} = replace(#{column}, ?1, ?2)]
          PostgresRepo -> ~s[UPDATE "#{table}" SET #{column} = replace(#{column}::text, $1, $2)::jsonb]
        end

      Ecto.Adapters.SQL.query!(repo, sql, [~s("#{from}"), ~s("#{to}")])
    end
  end

  defp thread_config do
    %{"configurable" => %{"thread_id" => "ticket-#{System.unique_integer([:positive])}"}}
  end
end
