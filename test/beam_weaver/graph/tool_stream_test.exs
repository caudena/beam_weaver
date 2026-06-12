defmodule BeamWeaver.Graph.ToolStreamTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.ToolRuntime
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Messages
  alias BeamWeaver.Graph.Nodes.ToolNode
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Transformers

  test "streams tool started, output deltas, and finished events" do
    tool =
      Tool.from_function!(
        name: "streaming_echo",
        description: "Stream chunks",
        input_schema: %{
          "required" => ["text"],
          "properties" => %{"text" => %{"type" => "string"}}
        },
        injected: %{"tool_runtime" => :tool_runtime},
        handler: fn %{"text" => text, "tool_runtime" => runtime}, _opts ->
          ToolRuntime.emit_output_delta(runtime, "a")
          ToolRuntime.emit_output_delta(runtime, "b")
          text
        end
      )

    graph =
      graph_for_tools(
        [
          %{id: "tc1", name: "streaming_echo", args: %{"text" => "done"}}
        ],
        [tool]
      )

    assert {:ok, events} = Compiled.stream_events(graph, %{messages: []})
    tool_events = tool_events(events)

    assert [
             %Envelope{
               event: %Events.ToolStart{tool_call_id: "tc1", tool_name: "streaming_echo"}
             },
             %Envelope{event: %Events.ToolDelta{tool_call_id: "tc1", delta: "a"}},
             %Envelope{event: %Events.ToolDelta{tool_call_id: "tc1", delta: "b"}},
             %Envelope{event: %Events.ToolFinish{tool_call_id: "tc1", output: "done"}}
           ] = tool_events
  end

  test "parallel tool output deltas remain scoped to their tool call IDs" do
    tool =
      Tool.from_function!(
        name: "streamer",
        description: "Stream marker chunks",
        input_schema: %{
          "required" => ["marker"],
          "properties" => %{"marker" => %{"type" => "string"}}
        },
        injected: %{"tool_runtime" => :tool_runtime},
        handler: fn %{"marker" => marker, "tool_runtime" => runtime}, _opts ->
          ToolRuntime.emit_output_delta(runtime, "#{marker}-1")
          ToolRuntime.emit_output_delta(runtime, "#{marker}-2")
          marker
        end
      )

    graph =
      graph_for_tools(
        [
          %{id: "a", name: "streamer", args: %{"marker" => "A"}},
          %{id: "b", name: "streamer", args: %{"marker" => "B"}}
        ],
        [tool]
      )

    assert {:ok, events} = Compiled.stream_events(graph, %{messages: []})
    tool_events = tool_events(events)

    deltas_by_call =
      tool_events
      |> Enum.filter(&match?(%Envelope{event: %Events.ToolDelta{}}, &1))
      |> Enum.group_by(
        fn %Envelope{event: %Events.ToolDelta{tool_call_id: tool_call_id}} -> tool_call_id end,
        fn %Envelope{event: %Events.ToolDelta{delta: delta}} -> delta end
      )

    assert deltas_by_call == %{"a" => ["A-1", "A-2"], "b" => ["B-1", "B-2"]}

    assert Enum.count(tool_events, &match?(%Envelope{event: %Events.ToolStart{}}, &1)) == 2
    assert Enum.count(tool_events, &match?(%Envelope{event: %Events.ToolFinish{}}, &1)) == 2
  end

  test "event stream exposes tool lifecycle events and graph updates" do
    tool =
      Tool.from_function!(
        name: "echo",
        description: "Echo",
        input_schema: %{"required" => ["text"]},
        handler: fn %{"text" => text}, _opts -> text end
      )

    graph =
      graph_for_tools(
        [
          %{id: "tc1", name: "echo", args: %{"text" => "hi"}}
        ],
        [tool]
      )

    assert {:ok, events} = Compiled.stream_events(graph, %{messages: []})

    assert Enum.any?(events, &match?(%Envelope{event: %Events.ToolStart{}}, &1))
    assert Enum.any?(events, &match?(%Envelope{event: %Events.ToolFinish{}}, &1))

    assert Enum.any?(
             events,
             &match?(
               %Envelope{event: %Events.GraphUpdate{update: %{"tools" => %{messages: [_]}}}},
               &1
             )
           )
  end

  test "projection helpers can select graph values without tool lifecycle events" do
    tool =
      Tool.from_function!(
        name: "echo",
        description: "Echo",
        input_schema: %{"required" => ["text"]},
        handler: fn %{"text" => text}, _opts -> text end
      )

    graph =
      graph_for_tools(
        [
          %{id: "tc1", name: "echo", args: %{"text" => "hi"}}
        ],
        [tool]
      )

    assert {:ok, events} = Compiled.stream_events(graph, %{messages: []})

    values =
      events
      |> Transformers.stream(:values)
      |> Enum.map(fn {_mode, event} -> event end)

    refute Enum.any?(values, fn
             %Envelope{event: %Events.ToolStart{}} -> true
             %Envelope{event: %Events.ToolDelta{}} -> true
             %Envelope{event: %Events.ToolFinish{}} -> true
             %Envelope{event: %Events.ToolError{}} -> true
             _other -> false
           end)

    assert Enum.any?(values, &match?(%Envelope{event: %Events.GraphValue{}}, &1))
  end

  test "handled tool failures emit tool-error events without executing as success" do
    tool =
      Tool.from_function!(
        name: "explode",
        description: "Returns an error",
        input_schema: %{"required" => ["text"]},
        handler: fn %{"text" => text}, _opts ->
          {:error, Error.new(:tool_boom, "failed on #{text}")}
        end
      )

    graph =
      graph_for_tools(
        [
          %{id: "tc1", name: "explode", args: %{"text" => "bad"}}
        ],
        [tool]
      )

    assert {:ok, events} = Compiled.stream_events(graph, %{messages: []})
    tool_events = tool_events(events)

    assert [
             %Envelope{event: %Events.ToolStart{tool_call_id: "tc1", tool_name: "explode"}},
             %Envelope{event: %Events.ToolError{tool_call_id: "tc1", message: error_message}}
           ] = tool_events

    assert error_message =~ "Tool error: failed on bad"
    assert error_message =~ "text"
    assert error_message =~ "bad"
    refute Enum.any?(tool_events, &match?(%Envelope{event: %Events.ToolFinish{}}, &1))
  end

  test "events stream mode exposes typed ToolNode lifecycle events" do
    tool =
      Tool.from_function!(
        name: "echo",
        description: "Echo with delta",
        input_schema: %{"required" => ["text"]},
        injected: %{"tool_runtime" => :tool_runtime},
        handler: fn %{"text" => text, "tool_runtime" => runtime}, _opts ->
          ToolRuntime.emit_output_delta(runtime, "partial")
          text
        end
      )

    graph =
      graph_for_tools(
        [
          %{id: "tc1", name: "echo", args: %{"text" => "done"}}
        ],
        [tool]
      )

    assert {:ok, events} = Compiled.stream_events(graph, %{messages: []})

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.ToolStart{tool_call_id: "tc1", tool_name: "echo"},
                 node: nil,
                 namespace: []
               },
               &1
             )
           )

    assert Enum.any?(events, &match?(%Envelope{event: %Events.ToolDelta{delta: "partial"}}, &1))

    assert Enum.any?(
             events,
             &match?(
               %Envelope{event: %Events.ToolFinish{tool_call_id: "tc1", output: "done"}},
               &1
             )
           )
  end

  test "typed tool events from subgraphs include child namespace metadata" do
    tool =
      Tool.from_function!(
        name: "echo",
        description: "Echo",
        input_schema: %{"required" => ["text"]},
        handler: fn %{"text" => text}, _opts -> text end
      )

    child =
      graph_for_tools(
        [
          %{id: "tc1", name: "echo", args: %{"text" => "nested"}}
        ],
        [tool]
      )

    parent =
      Graph.new(name: "ParentToolGraph", state_schema: Messages.state_schema())
      |> Graph.add_node(:child, child)
      |> Graph.add_edge(Graph.start(), :child)
      |> Graph.add_edge(:child, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(parent, %{messages: []})

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.ToolStart{tool_call_id: "tc1", tool_name: "echo"},
                 namespace: ["child"]
               },
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.ToolFinish{tool_call_id: "tc1", output: "nested"},
                 namespace: ["child"]
               },
               &1
             )
           )
  end

  defp graph_for_tools(tool_calls, tools) do
    Graph.new(state_schema: Messages.state_schema())
    |> Graph.add_node(:caller, fn _state ->
      %{messages: [Message.assistant("", tool_calls: tool_calls)]}
    end)
    |> Graph.add_node(:tools, ToolNode.new(tools))
    |> Graph.add_edge(Graph.start(), :caller)
    |> Graph.add_edge(:caller, :tools)
    |> Graph.add_edge(:tools, Graph.end_node())
    |> Graph.compile!()
  end

  defp tool_events(events) do
    Enum.filter(events, fn
      %Envelope{event: %Events.ToolStart{}} -> true
      %Envelope{event: %Events.ToolDelta{}} -> true
      %Envelope{event: %Events.ToolFinish{}} -> true
      %Envelope{event: %Events.ToolError{}} -> true
      _event -> false
    end)
  end
end
