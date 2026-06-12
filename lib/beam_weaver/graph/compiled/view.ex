defmodule BeamWeaver.Graph.Compiled.View do
  @moduledoc false

  alias BeamWeaver.Graph.Introspection
  alias BeamWeaver.Graph.Renderer
  alias BeamWeaver.Schema

  def get_graph(compiled, opts), do: Introspection.from_compiled(compiled, opts)

  def get_context_json_schema(%{graph: %{context_schema: context_schema}}) do
    Schema.to_json_schema(context_schema)
  end

  def get_input_json_schema(%{graph: %{input_schema: input_schema}}) do
    Schema.to_json_schema(input_schema)
  end

  def get_output_json_schema(%{graph: %{output_schema: output_schema}}) do
    Schema.to_json_schema(output_schema)
  end

  def draw_mermaid(compiled, opts) do
    compiled |> get_graph(opts) |> Renderer.to_mermaid(opts)
  end

  def draw_ascii(compiled, opts) do
    compiled |> get_graph(opts) |> Renderer.to_ascii(opts)
  end

  def draw_png(compiled, opts) do
    compiled |> get_graph(opts) |> Renderer.to_png(opts)
  end
end
