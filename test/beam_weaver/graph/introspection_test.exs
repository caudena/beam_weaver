defmodule BeamWeaver.Graph.IntrospectionTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Graph.Channels.LastValue
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Introspection
  alias BeamWeaver.Graph.StateGraph

  describe "input_channels/1 with no input_schema" do
    test "excludes internal and private channels" do
      graph =
        StateGraph.new(channels: %{messages: LastValue.new(), secret: LastValue.new()})

      graph = %{
        graph
        | channel_visibility: Map.put(graph.channel_visibility, :secret, :private)
      }

      introspection = Introspection.from_compiled(%Compiled{name: graph.name, graph: graph})

      assert introspection.input_channels == ["messages"]
      refute "__node_outputs__" in introspection.input_channels
      refute "__edge_runs__" in introspection.input_channels
      refute "secret" in introspection.input_channels
    end

    test "matches the output_channels filtering contract" do
      graph = StateGraph.new(channels: %{messages: LastValue.new()})

      introspection = Introspection.from_compiled(%Compiled{name: graph.name, graph: graph})

      assert introspection.input_channels == introspection.output_channels
    end
  end
end
