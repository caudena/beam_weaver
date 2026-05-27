defmodule BeamWeaver.Runnable.Graph do
  @moduledoc """
  Introspectable runnable graph data.
  """

  defstruct nodes: %{}, edges: [], input_schema: nil, output_schema: nil

  @type t :: %__MODULE__{
          nodes: map(),
          edges: [tuple()],
          input_schema: term(),
          output_schema: term()
        }

  def single(runnable) do
    id = node_id(runnable)
    %__MODULE__{nodes: %{id => %{label: label(runnable), runnable: runnable}}, edges: []}
  end

  def node_id(runnable) do
    base =
      runnable
      |> label()
      |> String.replace(~r/[^a-zA-Z0-9_]+/, "_")
      |> String.trim("_")

    if base == "", do: "runnable", else: base
  end

  def label(%{__struct__: module}), do: module |> Module.split() |> List.last()
  def label(module) when is_atom(module), do: module |> Module.split() |> List.last()
  def label(fun) when is_function(fun), do: "Function"
  def label(other), do: inspect(other)

  def safe_id(value) do
    value
    |> to_string()
    |> String.to_charlist()
    |> Enum.map_join(fn char ->
      if safe_id_char?(char) do
        <<char::utf8>>
      else
        "\\" <> (char |> Integer.to_string(16) |> String.downcase())
      end
    end)
  end

  def first_node(%__MODULE__{} = graph) do
    targets = graph.edges |> Enum.map(&edge_target/1) |> MapSet.new()

    graph.nodes
    |> Enum.reject(fn {id, _node} -> MapSet.member?(targets, id) end)
    |> single_node()
  end

  def last_node(%__MODULE__{} = graph) do
    sources = graph.edges |> Enum.map(&edge_source/1) |> MapSet.new()

    graph.nodes
    |> Enum.reject(fn {id, _node} -> MapSet.member?(sources, id) end)
    |> single_node()
  end

  def trim_first_node(%__MODULE__{} = graph) do
    case first_node(graph) do
      {id, _node} when id not in ["__start__", "__end__"] ->
        outgoing = Enum.filter(graph.edges, &(edge_source(&1) == id))

        if length(outgoing) == 1 do
          %{
            graph
            | nodes: Map.delete(graph.nodes, id),
              edges: Enum.reject(graph.edges, &(&1 in outgoing))
          }
        else
          graph
        end

      _other ->
        graph
    end
  end

  def trim_last_node(%__MODULE__{} = graph) do
    case last_node(graph) do
      {id, _node} when id not in ["__start__", "__end__"] ->
        incoming = Enum.filter(graph.edges, &(edge_target(&1) == id))

        if length(incoming) == 1 do
          %{
            graph
            | nodes: Map.delete(graph.nodes, id),
              edges: Enum.reject(graph.edges, &(&1 in incoming))
          }
        else
          graph
        end

      _other ->
        graph
    end
  end

  def to_json(%__MODULE__{} = graph, opts \\ []) do
    %{
      "nodes" =>
        graph.nodes
        |> Enum.sort_by(fn {id, _node} -> to_string(id) end)
        |> Enum.map(fn {id, node} ->
          data =
            if Keyword.get(opts, :with_schemas, false),
              do: Map.get(node, :schema, Map.get(node, "schema", node.label)),
              else: node.label

          %{"id" => id, "type" => "runnable", "data" => data}
        end),
      "edges" =>
        Enum.map(graph.edges, fn edge ->
          base = %{"source" => edge_source(edge), "target" => edge_target(edge)}

          case edge_label(edge) do
            nil -> base
            label -> Map.put(base, "data", label)
          end
        end)
    }
  end

  defp safe_id_char?(char) do
    (char >= ?a and char <= ?z) or
      (char >= ?A and char <= ?Z) or
      (char >= ?0 and char <= ?9) or
      char in [?_, ?-]
  end

  defp single_node([{id, node}]), do: {id, node}
  defp single_node(_nodes), do: nil

  defp edge_source({source, _target}), do: source
  defp edge_source({source, _target, _label}), do: source

  defp edge_target({_source, target}), do: target
  defp edge_target({_source, target, _label}), do: target

  defp edge_label({_source, _target}), do: nil
  defp edge_label({_source, _target, label}), do: label
end

defmodule BeamWeaver.Runnable.Graph.Renderer do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable.Graph

  def to_mermaid(%Graph{} = graph, opts \\ []) do
    nodes =
      graph.nodes
      |> Enum.sort_by(fn {id, _node} -> to_string(id) end)
      |> Enum.map(fn {id, node} -> "  #{Graph.safe_id(id)}[\"#{escape(node.label)}\"]" end)

    edges =
      graph.edges
      |> Enum.map(fn
        {from, to} ->
          "  #{Graph.safe_id(from)} --> #{Graph.safe_id(to)}"

        {from, to, label} ->
          "  #{Graph.safe_id(from)} -- \"#{escape(label)}\" --> #{Graph.safe_id(to)}"
      end)

    body = Enum.join(["graph TD" | nodes ++ edges], "\n")

    case Keyword.get(opts, :frontmatter) || Keyword.get(opts, :frontmatter_config) do
      nil -> body
      config -> Enum.join(["---", frontmatter(config), "---", body], "\n")
    end
  end

  def to_ascii(%Graph{} = graph, _opts \\ []) do
    graph.edges
    |> Enum.map(fn
      {from, to} -> "#{from} -> #{to}"
      {from, to, label} -> "#{from} -[#{label}]-> #{to}"
    end)
    |> case do
      [] ->
        graph.nodes
        |> Map.keys()
        |> Enum.map_join("\n", &to_string/1)

      lines ->
        Enum.join(lines, "\n")
    end
  end

  def to_png(%Graph{} = graph, opts \\ []) do
    case Keyword.get(opts, :renderer) do
      renderer when is_function(renderer, 1) ->
        {:ok, renderer.(to_mermaid(graph, opts))}

      renderer when is_function(renderer, 2) ->
        mermaid = to_mermaid(graph, opts)
        {:ok, renderer.(mermaid, api_url(mermaid, opts))}

      nil ->
        {:error, Error.new(:png_renderer_not_configured, "PNG renderer is not configured")}
    end
  end

  def api_url(mermaid, opts \\ []) do
    base_url = opts |> Keyword.get(:base_url, "https://mermaid.ink") |> String.trim_trailing("/")
    encoded = Base.url_encode64(mermaid, padding: false)

    query =
      opts
      |> Keyword.get(:background_color)
      |> background_query()

    base_url <> "/img/" <> encoded <> query
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("\"", "\\\"")
  end

  defp frontmatter(config) when is_map(config) do
    Enum.map_join(config, "\n", fn {key, value} -> yaml_line(key, value, 0) end)
  end

  defp frontmatter(config), do: to_string(config)

  defp yaml_line(key, value, depth) when is_map(value) do
    indent = String.duplicate("  ", depth)
    nested = Enum.map_join(value, "\n", fn {k, v} -> yaml_line(k, v, depth + 1) end)
    indent <> to_string(key) <> ":\n" <> nested
  end

  defp yaml_line(key, value, depth) do
    String.duplicate("  ", depth) <> to_string(key) <> ": " <> inspect(value)
  end

  defp background_query(nil), do: ""

  defp background_query("#" <> _rest = color),
    do: "?bgColor=" <> URI.encode_www_form(color)

  defp background_query(color), do: "?bgColor=" <> URI.encode_www_form("!" <> to_string(color))
end
