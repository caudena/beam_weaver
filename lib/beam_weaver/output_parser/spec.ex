defmodule BeamWeaver.OutputParser.Spec do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.OutputParser
  alias BeamWeaver.OutputParser.Parser

  def to_spec(%Parser{kind: :string}), do: {:ok, %{"type" => "output_parser_string"}}

  def to_spec(%Parser{kind: :json, opts: opts}) do
    {:ok,
     %{
       "type" => "output_parser_json",
       "partial" => Map.get(opts, :partial, false),
       "diff" => Map.get(opts, :diff, false)
     }}
  end

  def to_spec(%Parser{kind: :list, opts: opts}) do
    {:ok,
     %{
       "type" => "output_parser_list",
       "separator" => Map.get(opts, :separator),
       "markdown" => Map.get(opts, :markdown, false),
       "style" => opts |> Map.get(:style, :auto) |> Atom.to_string()
     }}
  end

  def to_spec(%Parser{kind: :csv, opts: opts}) do
    {:ok, %{"type" => "output_parser_csv", "separator" => Map.get(opts, :separator, ",")}}
  end

  def to_spec(%Parser{kind: :xml}), do: {:ok, %{"type" => "output_parser_xml"}}

  def to_spec(%Parser{kind: :openai_tools, opts: opts}) do
    {:ok,
     %{
       "type" => "output_parser_openai_tools",
       "first_only" => Map.get(opts, :first_only, false),
       "return_id" => Map.get(opts, :return_id, true),
       "key_name" => Map.get(opts, :key_name),
       "partial" => Map.get(opts, :partial, false)
     }}
  end

  def to_spec(%Parser{kind: :openai_functions, opts: opts}) do
    if is_nil(Map.get(opts, :schema)) and is_nil(Map.get(opts, :schemas)) and
         is_nil(Map.get(opts, :as)) do
      {:ok,
       %{
         "type" => "output_parser_openai_functions",
         "first_only" => Map.get(opts, :first_only, true),
         "args_only" => Map.get(opts, :args_only, false),
         "key_name" => Map.get(opts, :key_name),
         "partial" => Map.get(opts, :partial, false),
         "strict" => Map.get(opts, :strict, false),
         "required" => Map.get(opts, :required, true)
       }}
    else
      {:error,
       Error.new(
         :unsupported_runnable_spec,
         "OpenAI function parser schema/cast modules are not exportable",
         %{}
       )}
    end
  end

  def to_spec(%Parser{kind: :schema, opts: opts}) do
    if is_nil(Map.get(opts, :as)) do
      {:ok, %{"type" => "output_parser_schema", "schema" => Map.get(opts, :schema)}}
    else
      {:error,
       Error.new(:unsupported_runnable_spec, "schema parser cast modules are not exportable", %{
         as: inspect(Map.get(opts, :as))
       })}
    end
  end

  def from_spec(%{"type" => "output_parser_string"}), do: {:ok, OutputParser.string()}

  def from_spec(%{"type" => "output_parser_json"} = spec) do
    {:ok,
     OutputParser.json(
       partial: Map.get(spec, "partial", false),
       diff: Map.get(spec, "diff", false)
     )}
  end

  def from_spec(%{"type" => "output_parser_list"} = spec) do
    {:ok,
     OutputParser.list(
       separator: Map.get(spec, "separator"),
       markdown: Map.get(spec, "markdown", false),
       style: list_style(Map.get(spec, "style"))
     )}
  end

  def from_spec(%{"type" => "output_parser_csv"} = spec) do
    {:ok, OutputParser.csv(separator: Map.get(spec, "separator", ","))}
  end

  def from_spec(%{"type" => "output_parser_xml"}), do: {:ok, OutputParser.xml()}

  def from_spec(%{"type" => "output_parser_openai_tools"} = spec) do
    {:ok,
     OutputParser.openai_tools(
       first_only: Map.get(spec, "first_only", false),
       return_id: Map.get(spec, "return_id", true),
       key_name: Map.get(spec, "key_name"),
       partial: Map.get(spec, "partial", false)
     )}
  end

  def from_spec(%{"type" => "output_parser_openai_functions"} = spec) do
    {:ok,
     OutputParser.openai_functions(
       first_only: Map.get(spec, "first_only", true),
       args_only: Map.get(spec, "args_only", false),
       key_name: Map.get(spec, "key_name"),
       partial: Map.get(spec, "partial", false),
       strict: Map.get(spec, "strict", false),
       required: Map.get(spec, "required", true)
     )}
  end

  def from_spec(%{"type" => "output_parser_schema", "schema" => schema}) do
    {:ok, OutputParser.schema(schema)}
  end

  def from_spec(spec),
    do: {:error, Error.new(:invalid_runnable_spec, "invalid output parser spec", %{spec: spec})}

  defp list_style("markdown"), do: :markdown
  defp list_style("numbered"), do: :numbered
  defp list_style("comma"), do: :comma
  defp list_style("auto"), do: :auto
  defp list_style(nil), do: :auto
  defp list_style(style) when is_atom(style), do: style
  defp list_style(_style), do: :auto
end
