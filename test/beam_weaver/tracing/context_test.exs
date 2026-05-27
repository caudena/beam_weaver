defmodule BeamWeaver.Tracing.ContextTest do
  use ExUnit.Case

  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Context

  setup do
    Tracing.reset()
    Context.clear()

    on_exit(fn ->
      Tracing.reset()
      Context.clear()
    end)

    :ok
  end

  test "propagates parent run context across Task.Supervisor work" do
    {:ok, supervisor} = Task.Supervisor.start_link()

    {:ok, parent} =
      Tracing.start_run("agent",
        kind: :agent,
        tags: [:agent, "tenant:alpha"],
        metadata: %{tenant: "alpha", shared: "parent"}
      )

    task =
      Tracing.async(supervisor, fn ->
        {:ok, child} =
          Tracing.start_run("model call",
            kind: :model,
            tags: [:model],
            metadata: %{shared: "child"}
          )

        Tracing.finish_run(child)
        child.id
      end)

    child_id = Task.await(task)
    Tracing.finish_run(parent)

    assert {:ok, %{run: tree_parent, children: [%{run: tree_child, children: []}]}} =
             Tracing.get_tree(parent.id)

    assert tree_parent.id == parent.id
    assert tree_child.id == child_id
    assert tree_child.parent_id == parent.id
    assert tree_child.trace_id == parent.trace_id
    assert tree_child.status == :ok
    assert tree_child.tags == ["agent", "tenant:alpha", "model"]
    assert tree_child.metadata == %{tenant: "alpha", shared: "child"}
  end

  test "nested runs inherit trace metadata and restore parent context after finish" do
    {:ok, parent} =
      Tracing.start_run("parent",
        tags: [:root],
        metadata: %{tenant: "alpha", shared: "parent"}
      )

    {:ok, child} =
      Tracing.start_run("child",
        tags: [:child],
        metadata: %{shared: "child", request_id: "req-1"}
      )

    assert child.parent_id == parent.id
    assert child.trace_id == parent.trace_id
    assert child.tags == ["root", "child"]
    assert child.metadata == %{tenant: "alpha", shared: "child", request_id: "req-1"}

    assert {:ok, _child} = Tracing.finish_run(child)
    assert Tracing.capture_context().run_id == parent.id
    assert Tracing.capture_context().metadata == parent.metadata

    {:ok, sibling} = Tracing.start_run("sibling")
    assert sibling.parent_id == parent.id
    assert sibling.metadata == %{tenant: "alpha", shared: "parent"}
  end

  test "parallel trace roots keep inherited metadata isolated per process" do
    tasks =
      for tenant <- ["alpha", "beta"] do
        Task.async(fn ->
          {:ok, root} = Tracing.start_run("root", metadata: %{tenant: tenant})
          {:ok, child} = Tracing.start_run("child")
          Tracing.finish_run(child)
          Tracing.finish_run(root)
          {tenant, root.id, child.id}
        end)
      end

    results = Enum.map(tasks, &Task.await/1)

    for {tenant, root_id, child_id} <- results do
      assert {:ok, %{run: root, children: [%{run: child}]}} = Tracing.get_tree(root_id)
      assert root.id == root_id
      assert root.metadata == %{tenant: tenant}
      assert child.id == child_id
      assert child.metadata == %{tenant: tenant}
      assert child.parent_id == root_id
      assert child.trace_id == root.trace_id
    end
  end

  test "attach_context restores the previous process context after running" do
    {:ok, first} = Tracing.start_run("first")
    first_context = Tracing.capture_context()

    {:ok, second} = Tracing.start_run("second")
    second_context = Tracing.capture_context()

    assert second_context.run_id == second.id

    Tracing.attach_context(first_context, fn ->
      assert Tracing.capture_context().run_id == first.id
    end)

    assert Tracing.capture_context().run_id == second.id
  end
end
