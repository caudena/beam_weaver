defmodule BeamWeaver.OutputParser do
  @moduledoc """
  Runnable-compatible output parsers.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.OutputParser.Delimited
  alias BeamWeaver.OutputParser.JSON
  alias BeamWeaver.OutputParser.OpenAI, as: OpenAIOutputParser
  alias BeamWeaver.OutputParser.Parser
  alias BeamWeaver.OutputParser.Schema
  alias BeamWeaver.OutputParser.XML

  def string, do: Parser.new(:string)

  def json(opts \\ []),
    do:
      Parser.new(:json, %{
        partial: Keyword.get(opts, :partial, false),
        diff: Keyword.get(opts, :diff, false)
      })

  def list(opts \\ []),
    do:
      Parser.new(:list, %{
        separator: Keyword.get(opts, :separator),
        markdown: Keyword.get(opts, :markdown, false),
        style: Keyword.get(opts, :style, :auto)
      })

  def markdown_list(opts \\ []),
    do:
      Parser.new(:list, %{
        separator: Keyword.get(opts, :separator),
        markdown: true,
        style: :markdown
      })

  def numbered_list(opts \\ []),
    do:
      Parser.new(:list, %{
        separator: Keyword.get(opts, :separator),
        markdown: false,
        style: :numbered
      })

  def comma_separated_list(opts \\ []),
    do:
      Parser.new(:list, %{
        separator: Keyword.get(opts, :separator, ","),
        markdown: false,
        style: :comma
      })

  def csv(opts \\ []), do: Parser.new(:csv, %{separator: Keyword.get(opts, :separator, ",")})
  def xml(_opts \\ []), do: Parser.new(:xml)

  def openai_tools(opts \\ []),
    do:
      Parser.new(:openai_tools, %{
        first_only: Keyword.get(opts, :first_only, false),
        return_id: Keyword.get(opts, :return_id, true),
        key_name: Keyword.get(opts, :key_name),
        partial: Keyword.get(opts, :partial, false)
      })

  def openai_functions(opts \\ []),
    do:
      Parser.new(:openai_functions, %{
        first_only: Keyword.get(opts, :first_only, true),
        args_only: Keyword.get(opts, :args_only, false),
        key_name: Keyword.get(opts, :key_name),
        partial: Keyword.get(opts, :partial, false),
        strict: Keyword.get(opts, :strict, false),
        required: Keyword.get(opts, :required, true),
        schema: Keyword.get(opts, :schema),
        schemas: Keyword.get(opts, :schemas),
        as: Keyword.get(opts, :as)
      })

  def schema(schema, opts \\ []),
    do: Parser.new(:schema, %{schema: schema, as: Keyword.get(opts, :as)})

  @doc false
  def put_opts(%Parser{} = parser, opts),
    do: %{parser | opts: Map.merge(parser.opts || %{}, Map.new(opts))}

  @doc false
  def option(%Parser{} = parser, key, default \\ nil),
    do: Map.get(parser.opts || %{}, key, default)

  def parse(parser, input, opts \\ []), do: BeamWeaver.Runnable.invoke(parser, input, opts)

  def parse_result(parser, generations, opts \\ []) do
    parser =
      cond do
        Keyword.get(opts, :partial, false) and match?(%Parser{}, parser) ->
          put_opts(parser, partial: true)

        Keyword.get(opts, :partial, false) and is_map(parser) and Map.has_key?(parser, :partial) ->
          %{parser | partial: true}

        true ->
          parser
      end

    parse(parser, List.wrap(generations) |> List.first(), opts)
  end

  def parse_with_prompt(parser, completion, _prompt, opts \\ []),
    do: parse(parser, completion, opts)

  @spec async_parse(term(), term(), keyword()) :: Async.handle()
  def async_parse(parser, input, opts \\ []),
    do: BeamWeaver.Runnable.async_invoke(parser, input, opts)

  @spec async_parse_result(term(), term(), keyword()) :: Async.handle()
  def async_parse_result(parser, generations, opts \\ []) do
    Async.run_call(opts, &parse_result(parser, generations, &1))
  end

  @spec async_parse_with_prompt(term(), term(), term(), keyword()) :: Async.handle()
  def async_parse_with_prompt(parser, completion, prompt, opts \\ []) do
    Async.run_call(opts, &parse_with_prompt(parser, completion, prompt, &1))
  end

  def parse_partial(%Parser{} = parser, input),
    do: BeamWeaver.Runnable.invoke(put_opts(parser, partial: true), input)

  def transform(parser, input, opts \\ []), do: BeamWeaver.Runnable.transform(parser, input, opts)

  def get_format_instructions(%Parser{kind: :json}), do: "Return a valid JSON value."

  def get_format_instructions(%Parser{kind: :schema, opts: %{schema: schema}}),
    do: "Return JSON matching this schema: #{BeamWeaver.JSON.encode!(schema)}"

  def get_format_instructions(%Parser{kind: :xml}), do: "Return valid XML."
  def get_format_instructions(%Parser{kind: :csv}), do: "Return comma-separated values."

  def get_format_instructions(%Parser{kind: :list, opts: %{style: :numbered}}),
    do: "Return a numbered list with one item per line."

  def get_format_instructions(%Parser{kind: :list, opts: %{style: :markdown}}),
    do: "Return a Markdown list with one item per line."

  def get_format_instructions(%Parser{kind: :list, opts: %{style: :comma}}),
    do: "Return a comma-separated list of values."

  def get_format_instructions(%Parser{kind: :list}), do: "Return a list of values."
  def get_format_instructions(_parser), do: ""

  def output_schema_for(%Parser{kind: :string}), do: %{"type" => "string"}
  def output_schema_for(%Parser{kind: :json}), do: %{"type" => "any"}
  def output_schema_for(%Parser{kind: :list}), do: %{"type" => "array"}
  def output_schema_for(%Parser{kind: :csv}), do: %{"type" => "array"}
  def output_schema_for(%Parser{kind: :xml}), do: %{"type" => "object"}
  def output_schema_for(%Parser{kind: :openai_tools}), do: %{"type" => "array"}
  def output_schema_for(%Parser{kind: :openai_functions}), do: %{"type" => "object"}
  def output_schema_for(%Parser{kind: :schema, opts: %{schema: schema}}), do: schema

  @spec text(term()) :: String.t()
  def text(%Message{} = message), do: Message.text(message)
  def text(%Messages.AIChunk{content: content}), do: content || ""
  def text(%Messages.Chunk{content: content}), do: content || ""
  def text(text) when is_binary(text), do: text
  def text(other), do: to_string(other)

  @spec parse_json(String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def parse_json(text, opts \\ []) when is_binary(text), do: JSON.parse(text, opts)

  @spec parse_partial_json(String.t()) :: {:ok, term()} | {:error, Error.t()}
  def parse_partial_json(text) when is_binary(text), do: JSON.parse_partial(text)

  @spec parse_json_markdown(String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def parse_json_markdown(text, opts \\ []) when is_binary(text),
    do: JSON.parse_markdown(text, opts)

  @spec parse_and_check_json_markdown(String.t(), [String.t() | atom()]) ::
          {:ok, map()} | {:error, Error.t()}
  def parse_and_check_json_markdown(text, expected_keys) when is_list(expected_keys),
    do: JSON.parse_and_check_markdown(text, expected_keys)

  @spec parse_list(String.t(), String.t() | nil) :: [String.t()]
  def parse_list(text, separator)

  def parse_list(text, separator) when is_binary(separator), do: Delimited.list(text, separator)
  def parse_list(text, separator), do: Delimited.list(text, separator)

  def parse_markdown_list(text), do: Delimited.markdown_list(text)

  def parse_numbered_list(text), do: Delimited.numbered_list(text)

  def parse_comma_separated_list(text, separator \\ ","),
    do: Delimited.comma_separated_list(text, separator)

  def parse_list_with_parser(%Parser{kind: :list, opts: %{style: :numbered}}, text),
    do: parse_numbered_list(text)

  def parse_list_with_parser(%Parser{kind: :list, opts: %{style: :markdown}}, text),
    do: parse_markdown_list(text)

  def parse_list_with_parser(%Parser{kind: :list, opts: %{style: :comma} = opts}, text) do
    separator = Map.get(opts, :separator)
    parse_comma_separated_list(text, separator || ",")
  end

  def parse_list_with_parser(%Parser{kind: :list, opts: %{markdown: true}}, text),
    do: parse_markdown_list(text)

  def parse_list_with_parser(%Parser{kind: :list, opts: opts}, text) do
    separator = Map.get(opts, :separator)
    parse_list(text, separator)
  end

  def parse_list_with_parser(%{style: :numbered}, text), do: parse_numbered_list(text)
  def parse_list_with_parser(%{style: :markdown}, text), do: parse_markdown_list(text)

  def parse_list_with_parser(%{style: :comma, separator: separator}, text),
    do: parse_comma_separated_list(text, separator || ",")

  def parse_list_with_parser(%{markdown: true}, text), do: parse_markdown_list(text)

  def parse_list_with_parser(%{separator: separator}, text),
    do: parse_list(text, separator)

  def transform_string(input) do
    if Enumerable.impl_for(input) do
      {:ok, Stream.map(input, &text/1)}
    else
      {:error, Error.new(:invalid_runnable_input, "transform input must be Enumerable")}
    end
  end

  def transform_list(%Parser{kind: :list} = parser, input) do
    if Enumerable.impl_for(input) do
      stream =
        Stream.flat_map([input], fn chunks ->
          chunks
          |> Enum.map_join(&text/1)
          |> then(&parse_list_with_parser(parser, &1))
          |> Enum.map(&[&1])
        end)

      {:ok, stream}
    else
      {:ok, parser |> parse_list_with_parser(text(input)) |> Enum.map(&[&1])}
    end
  end

  def parse_csv(text, separator \\ ","), do: Delimited.csv(text, separator)

  def parse_xml(text), do: XML.parse(text)
  @spec transform_xml(Enumerable.t()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def transform_xml(input) do
    if Enumerable.impl_for(input) do
      text =
        Enum.reduce(input, nil, fn item, acc ->
          item = text(item)
          if is_nil(acc), do: item, else: BeamWeaver.Runnable.Addable.add(acc, item)
        end) || ""

      with {:ok, node} <- parse_xml(text) do
        {:ok, XML.transform_chunks(node)}
      end
    else
      {:error, Error.new(:invalid_runnable_input, "transform input must be Enumerable")}
    end
  end

  @spec parse_openai_tools(term(), keyword() | map()) ::
          {:ok, [map()] | map() | nil} | {:error, Error.t()}
  def parse_openai_tools(input, opts \\ []), do: OpenAIOutputParser.parse_tools(input, opts)

  @spec stream_openai_tools(Parser.t(), term()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_openai_tools(%Parser{kind: :openai_tools} = parser, input),
    do: OpenAIOutputParser.stream_tools(parser.opts || %{}, input)

  @spec parse_openai_functions(term(), keyword()) ::
          {:ok, map() | [map()] | nil} | {:error, Error.t()}
  def parse_openai_functions(input, opts \\ []),
    do: OpenAIOutputParser.parse_functions(input, opts)

  @spec validate_schema(map(), term()) :: :ok | {:error, Error.t()}
  def validate_schema(schema, data), do: Schema.validate(schema, data)

  def cast_schema(data, as), do: Schema.cast(data, as)

  def stream_cumulative(%Parser{kind: :json} = parser, input) do
    if Enumerable.impl_for(input) do
      stream =
        input
        |> Stream.transform({"", nil, nil}, fn chunk, {buffer, last_key, last_value} ->
          chunk_text = text(chunk)
          appended = buffer <> chunk_text
          {parse_input, buffer} = cumulative_parse_input(chunk_text, appended, last_value)

          case parse_json(parse_input, partial: option(parser, :partial, false)) do
            {:ok, parsed} ->
              key = :erlang.term_to_binary(parsed)

              cond do
                key == last_key ->
                  {[], {buffer, last_key, last_value}}

                option(parser, :diff, false) and not is_nil(last_value) ->
                  {[diff(last_value, parsed)], {buffer, key, parsed}}

                true ->
                  {[parsed], {buffer, key, parsed}}
              end

            {:error, _error} ->
              {[], {buffer, last_key, last_value}}
          end
        end)

      {:ok, stream}
    else
      case Parser.invoke(parser, input, []) do
        {:ok, value} -> {:ok, [value]}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp cumulative_parse_input(_chunk_text, appended, nil), do: {appended, appended}

  defp cumulative_parse_input(chunk_text, appended, _last_value) do
    trimmed = String.trim(chunk_text)

    if String.starts_with?(trimmed, ["{", "["]) do
      {chunk_text, chunk_text}
    else
      {appended, appended}
    end
  end

  defp diff(old, new) when old == new, do: []

  defp diff(old, new) do
    [%{"op" => "replace", "path" => "", "value" => new, "old" => old}]
  end
end

defimpl BeamWeaver.Runnable.Introspect,
  for: [
    BeamWeaver.OutputParser.Parser
  ] do
  def graph(parser, _opts), do: BeamWeaver.Runnable.Graph.single(parser)
  def input_schema(_parser), do: %{"type" => "any"}
  def output_schema(parser), do: BeamWeaver.OutputParser.output_schema_for(parser)
  def config_specs(_parser), do: []
end

defimpl BeamWeaver.Runnable.Spec,
  for: [
    BeamWeaver.OutputParser.Parser
  ] do
  def to_spec(parser), do: BeamWeaver.OutputParser.Spec.to_spec(parser)
end
