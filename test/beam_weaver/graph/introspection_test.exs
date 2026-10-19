defmodule BeamWeaver.Graph.IntrospectionTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.LastValue
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Introspection
  alias BeamWeaver.Graph.StateGraph

  defmodule TicketRouter do
    use BeamWeaver.Graph

    graph do
      node :classify, &__MODULE__.classify/1
      node :billing, &__MODULE__.billing/1
      node :shipping, &__MODULE__.shipping/1

      edge start(), :classify
      edge :classify, :billing, when: %{category: :billing}
      edge :classify, :shipping, default: true
      edge :shipping, finish()
      edge :billing, finish()
    end

    def classify(_state), do: %{category: :billing}
    def billing(_state), do: %{queue: "billing"}
    def shipping(_state), do: %{queue: "shipping"}
  end

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

  describe "entry and finish points" do
    test "of a graph module" do
      {:ok, compiled} = TicketRouter.compiled_graph([])
      introspection = Compiled.get_graph(compiled)

      assert introspection.entry_points == ["classify"]
      assert introspection.finish_points == ["billing", "shipping"]
    end

    test "of a graph built with functions, sorted" do
      compiled =
        Graph.new()
        |> Graph.add_node(:shipping_eta, fn _state -> %{eta: "Thursday"} end)
        |> Graph.add_node(:billing_status, fn _state -> %{paid: true} end)
        |> Graph.add_node(:reply, fn _state -> %{reply: "Paid; arrives Thursday."} end)
        |> Graph.add_edge(Graph.start(), :shipping_eta)
        |> Graph.add_edge(Graph.start(), :billing_status)
        |> Graph.add_join([:shipping_eta, :billing_status], :reply)
        |> Graph.add_edge(:reply, Graph.end_node())
        |> Graph.compile!()

      introspection = Compiled.get_graph(compiled)

      assert introspection.entry_points == ["billing_status", "shipping_eta"]
      assert introspection.finish_points == ["reply"]
    end
  end
end
