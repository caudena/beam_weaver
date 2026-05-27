defmodule BeamWeaver.Graph.UITest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Runtime
  alias BeamWeaver.Graph.UI
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  test "UI reducer replaces, merges, removes, and rejects missing deletes" do
    # Upstream: langgraph/langgraph/graph/ui.py::ui_message_reducer
    first = UI.message("Card", %{title: "A"}, id: "1")
    replacement = UI.message("Card", %{title: "B"}, id: "1")
    merged = UI.message("Card", %{subtitle: "C"}, id: "1", merge: true)

    assert UI.reducer([], first) == [first]
    assert UI.reducer([first], replacement) == [replacement]
    assert UI.reducer([replacement], merged) == [%{merged | props: %{title: "B", subtitle: "C"}}]
    assert UI.reducer([first], UI.remove("1")) == []

    assert_raise ArgumentError, ~r/delete a UI message/, fn ->
      UI.reducer([], UI.remove("missing"))
    end
  end

  test "runtime push_ui_message streams UI events and graph state can use UI reducer" do
    # Upstream: langgraph/langgraph/graph/ui.py::push_ui_message
    graph =
      Graph.new(state_schema: UI.state_schema())
      |> Graph.add_node(:ui, fn _state, runtime ->
        {:ok, event} = Runtime.push_ui_message(runtime, "Panel", %{text: "hello"}, id: "ui-1")
        %{ui: event}
      end)
      |> Graph.add_edge(Graph.start(), :ui)
      |> Graph.add_edge(:ui, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    assert Enum.any?(events, fn
             %Envelope{event: %Events.Custom{payload: %{type: :ui, id: "ui-1", name: "Panel"}}} ->
               true

             _other ->
               false
           end)

    assert Enum.any?(events, fn
             %Envelope{
               event: %Events.GraphValue{value: %{ui: [%{id: "ui-1", name: "Panel"}]}}
             } ->
               true

             _other ->
               false
           end)
  end

  test "runtime delete_ui_message streams removal events" do
    graph =
      Graph.new()
      |> Graph.add_node(:ui, fn _state, runtime ->
        {:ok, event} = Runtime.delete_ui_message(runtime, "ui-1")
        %{removed: event.id}
      end)
      |> Graph.add_edge(Graph.start(), :ui)
      |> Graph.add_edge(:ui, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    assert Enum.any?(events, fn
             %Envelope{event: %Events.Custom{payload: %{type: :remove_ui, id: "ui-1"}}} -> true
             _other -> false
           end)
  end
end
