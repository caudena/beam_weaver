defmodule BeamWeaver.Stream.TransformersTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Transformers

  test "data transformers project root-scope graph event modes" do
    events = [
      Stream.envelope(%Events.GraphValue{value: %{answer: 1}}),
      Stream.envelope(%Events.GraphUpdate{update: %{node: %{answer: 2}}}),
      Stream.envelope(%Events.Custom{payload: {:progress, 3}}),
      Stream.envelope(%Events.Checkpoint{config: %{"id" => "cp"}, values: %{answer: 2}, step: 1}),
      Stream.envelope(%Events.Task{kind: :start, node: "model", step: 1, task_id: "task"}),
      Stream.envelope(%Events.Debug{payload: %{type: :tick}}),
      Stream.envelope(%Events.Done{result: %{answer: 2}})
    ]

    assert {:ok, transformer, emitted} =
             Transformers.process_many(Transformers.new(), events)

    assert [
             {:values, %Envelope{event: %Events.GraphValue{value: %{answer: 1}}}},
             {:updates, %Envelope{event: %Events.GraphUpdate{update: %{node: %{answer: 2}}}}},
             {:custom, %Envelope{event: %Events.Custom{payload: {:progress, 3}}}},
             {:checkpoints,
              %Envelope{
                event: %Events.Checkpoint{
                  config: %{"id" => "cp"},
                  values: %{answer: 2},
                  step: 1
                }
              }},
             {:tasks,
              %Envelope{
                event: %Events.Task{
                  kind: :start,
                  node: "model",
                  payload: nil,
                  step: 1,
                  task_id: "task"
                }
              }},
             {:debug, %Envelope{event: %Events.Debug{payload: %{type: :tick}}}},
             {:lifecycle, %Envelope{event: %Events.Done{result: %{answer: 2}}}}
           ] =
             emitted

    assert transformer.captured == emitted
  end

  test "projection modes are opt-in and unrelated events pass through" do
    transformer = Transformers.new([:updates, :custom])

    assert {:ok, transformer, [{:updates, %Envelope{event: %Events.GraphUpdate{update: %{node: %{x: 1}}}}}]} =
             Transformers.process(
               transformer,
               Stream.envelope(%Events.GraphUpdate{update: %{node: %{x: 1}}})
             )

    assert {:pass, ^transformer} =
             Transformers.process(
               transformer,
               Stream.envelope(%Events.GraphValue{value: %{x: 1}})
             )

    assert {:pass, ^transformer} =
             Transformers.process(
               transformer,
               Stream.envelope(%Events.Message{message: :ignored})
             )
  end

  test "scope filtering ignores subgraphs unless a scoped transformer opts in" do
    root = Stream.envelope(%Events.GraphUpdate{update: %{root: true}})

    child =
      Stream.envelope(%Events.GraphUpdate{update: %{child: true}},
        namespace: ["child"]
      )

    assert {:ok, _transformer, [{:updates, %Envelope{event: %Events.GraphUpdate{update: %{root: true}}}}]} =
             Transformers.process_many(Transformers.new(:updates), [root, child])

    assert {:ok, _transformer, [{:updates, %Envelope{event: %Events.GraphUpdate{update: %{child: true}}}}]} =
             Transformers.process_many(Transformers.new(:updates, scope: ["child"]), [root, child])

    grandchild =
      Stream.envelope(%Events.GraphUpdate{update: %{grandchild: true}},
        namespace: ["child", "worker"]
      )

    assert {:ok, _transformer,
            [
              {:updates, %Envelope{event: %Events.GraphUpdate{update: %{child: true}}}},
              {:updates, %Envelope{event: %Events.GraphUpdate{update: %{grandchild: true}}}}
            ]} =
             Transformers.process_many(
               Transformers.new(:updates, scope: ["child"], include_subgraphs?: true),
               [root, child, grandchild]
             )
  end

  test "stream reducer preserves interleaving across selected transformer modes" do
    events = [
      Stream.envelope(%Events.Custom{payload: "a"}),
      Stream.envelope(%Events.GraphValue{value: %{x: 1}}),
      Stream.envelope(%Events.Task{kind: :finish, node: "model", payload: %{x: 1}}),
      Stream.envelope(%Events.Done{result: :ok})
    ]

    assert Enum.to_list(Transformers.stream(events, [:custom, :values, :tasks, :lifecycle])) == [
             {:custom, Enum.at(events, 0)},
             {:values, Enum.at(events, 1)},
             {:tasks, Enum.at(events, 2)},
             {:lifecycle, Enum.at(events, 3)}
           ]
  end

  test "required modes expose native transformer registration" do
    assert Transformers.new(["tasks", "lifecycle", "unknown"])
           |> Transformers.required_modes() == [:lifecycle, :tasks]
  end
end
