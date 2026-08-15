# Immutable Todos

`BeamWeaver.Todo` is a small pure value for application-owned progress state.
It is separate from `BeamWeaver.Tools.Todo`, which remains a model-facing
whole-list planning tool for ordinary agents.

```elixir
{:ok, todo} =
  BeamWeaver.Todo.new("release-plan", [
    %{id: "inspect", content: "Inspect the implementation"},
    %{id: "change", content: "Make the change", dependencies: ["inspect"]}
  ])

{:ok, next} =
  BeamWeaver.Todo.revise(
    todo,
    [
      %{
        id: "inspect",
        content: "Inspect the implementation",
        status: :completed,
        evidence: [%{kind: :completion, ref: "checkpoint-42"}]
      },
      %{id: "change", content: "Make the change", dependencies: ["inspect"]}
    ],
    expected_revision: todo.revision,
    expected_hash: todo.hash
  )
```

Plans are bounded to 128 items and 512 dependency edges. IDs, item definitions,
and existing order are immutable; new items may only be appended. Dependencies
must be known, unique, and acyclic. State changes require an evidence reference
with the corresponding `:assignment`, `:blocker`, `:blocker_resolved`,
`:completion`, or `:cancellation` kind. BeamWeaver validates the kind and stable
hash; evidence is append-only, and an assigned owner/assignment pair cannot
move to another owner. The application owns the referenced evidence and
persistence.

The value is not a scheduler, authorization system, database schema, or mutable
process store. Persist each accepted revision through your application's normal
checkpoint or database boundary.
