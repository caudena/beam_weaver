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
end
