defmodule BeamWeaver.TodoTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Todo

  test "creates deterministic dependency-aware revisions" do
    items = [
      %{id: "inspect", content: "Inspect the code"},
      %{id: "change", content: "Make the change", dependencies: ["inspect"]}
    ]

    assert {:ok, first} = Todo.new("plan-1", items)
    assert {:ok, identical} = Todo.new("plan-1", Enum.map(items, &Map.new(&1, fn {k, v} -> {to_string(k), v} end)))

    assert first.hash == identical.hash
    assert first.revision == 1
    assert first.active_item_ids == ["inspect", "change"]
    assert :ok = Todo.validate(first)
  end

  test "rejects unknown dependencies and cycles" do
    assert {:error, %Error{type: :invalid_todo_dependency}} =
             Todo.new("plan", [%{id: "a", content: "a", dependencies: ["missing"]}])

    assert {:error, %Error{type: :todo_cycle}} =
             Todo.new("plan", [
               %{id: "a", content: "a", dependencies: ["b"]},
               %{id: "b", content: "b", dependencies: ["a"]}
             ])
  end

  test "requires current revision and evidence for state transitions" do
    assert {:ok, first} = Todo.new("plan", [%{id: "a", content: "a"}])

    assert {:error, %Error{type: :invalid_todo_item}} =
             Todo.new("invalid", [%{id: "done", content: "done", status: :completed}])

    assert {:error, %Error{type: :stale_todo}} =
             Todo.revise(first, first.items,
               expected_revision: 0,
               expected_hash: first.hash
             )

    assert {:error, %Error{type: :invalid_todo_item}} =
             Todo.revise(first, [%{id: "a", content: "a", status: :in_progress}],
               expected_revision: 1,
               expected_hash: first.hash
             )

    assert {:error, %Error{type: :invalid_todo_item}} =
             Todo.revise(
               first,
               [%{id: "a", content: "a", owner: "worker-1", assignment_id: "assignment-1"}],
               expected_revision: 1,
               expected_hash: first.hash
             )

    assert {:ok, second} =
             Todo.revise(
               first,
               [
                 %{
                   id: "a",
                   content: "a",
                   status: :in_progress,
                   owner: "worker-1",
                   assignment_id: "assignment-1",
                   evidence: [%{kind: :assignment, ref: "assignment-1"}]
                 }
               ],
               expected_revision: 1,
               expected_hash: first.hash
             )

    assert second.revision == 2
    assert second.previous_hash == first.hash
    assert :ok = Todo.validate(second)

    assert {:error, %Error{type: :invalid_todo_revision}} =
             Todo.revise(
               second,
               [
                 %{
                   id: "a",
                   content: "a",
                   status: :in_progress,
                   owner: "worker-2",
                   assignment_id: "assignment-2",
                   evidence: [%{kind: :assignment, ref: "assignment-2"}]
                 }
               ],
               expected_revision: second.revision,
               expected_hash: second.hash
             )
  end

  test "keeps existing item definitions and order immutable" do
    assert {:ok, first} =
             Todo.new("plan", [
               %{id: "a", content: "a"},
               %{id: "b", content: "b", dependencies: ["a"]}
             ])

    opts = [expected_revision: first.revision, expected_hash: first.hash]

    assert {:error, %Error{type: :invalid_todo_revision}} =
             Todo.revise(first, Enum.reverse(first.items), opts)

    changed = [Map.put(hd(first.items), :content, "different") | tl(first.items)]

    assert {:error, %Error{type: :invalid_todo_revision}} = Todo.revise(first, changed, opts)
  end

  test "approved intent survives handoff and cannot be rewritten in a revision" do
    intent = %{
      "origin" => "approved_plan",
      "payload" => %{"acceptance_criteria" => ["passes"], "verification_steps" => ["verify"]}
    }

    {:ok, original} =
      Todo.new("reviewed", [
        %{
          id: "a",
          content: "Work",
          intent: intent,
          status: :in_progress,
          owner: "old",
          assignment_id: "assignment-old",
          evidence: [%{kind: :assignment, ref: "assignment-old"}]
        }
      ])

    opts = [expected_revision: original.revision, expected_hash: original.hash]

    assert {:ok, moved} =
             Todo.handoff(
               original,
               %{"a" => %{owner: "new", assignment_id: "assignment-new"}},
               "continue-receipt",
               opts
             )

    assert [item] = moved.items
    assert item.intent == intent
    assert item.status == :in_progress
    assert item.owner == "new"
    assert moved.previous_hash == original.hash
    assert :ok = Todo.validate(moved)

    assert {:error, %Error{type: :invalid_todo_revision}} =
             Todo.revise(
               moved,
               [%{item | intent: Map.put(intent, "payload", %{})}],
               expected_revision: moved.revision,
               expected_hash: moved.hash
             )

    for invalid <- [nil, %{}, %{owner: "new"}, %{owner: "new", assignment_id: nil}] do
      assert {:error, _} = Todo.handoff(original, %{"a" => invalid}, "receipt", opts)
    end

    assert {:error, _} = Todo.handoff(original, %{"missing" => %{owner: "new", assignment_id: "a"}}, "receipt", opts)
  end

  test "shared maximum-size DAGs validate and cycles remain rejected" do
    items =
      for n <- 1..128 do
        %{
          id: "node-#{n}",
          content: "node #{n}",
          dependencies: for(previous <- [n - 1, n - 2], previous > 0, do: "node-#{previous}")
        }
      end

    task = Task.async(fn -> Todo.new("shared", items) end)
    assert {:ok, valid} = Task.await(task, 2_000)
    assert length(valid.items) == 128
    cyclic = List.update_at(items, 0, &%{&1 | dependencies: ["node-128"]})
    assert {:error, %Error{type: :todo_cycle}} = Todo.new("cycle", cyclic)
  end
end
