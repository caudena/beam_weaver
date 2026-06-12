defmodule BeamWeaver.OutputParser.Parser do
  @moduledoc false
  @behaviour BeamWeaver.Runnable

  defstruct [:kind, opts: %{}]

  @type kind ::
          :string
          | :json
          | :list
          | :csv
          | :xml
          | :openai_tools
          | :openai_functions
          | :schema

  @type t :: %__MODULE__{kind: kind(), opts: map()}

  @spec new(kind(), map() | keyword()) :: t()
  def new(kind, opts \\ %{}), do: %__MODULE__{kind: kind, opts: Map.new(opts)}

  def invoke(%__MODULE__{kind: :string}, input, _opts),
    do: {:ok, BeamWeaver.OutputParser.text(input)}

  def invoke(%__MODULE__{kind: :json, opts: opts}, input, _opts),
    do:
      BeamWeaver.OutputParser.parse_json(BeamWeaver.OutputParser.text(input),
        partial: Map.get(opts, :partial, false)
      )

  def invoke(%__MODULE__{kind: :list} = parser, input, _opts) do
    text = BeamWeaver.OutputParser.text(input)
    {:ok, BeamWeaver.OutputParser.parse_list_with_parser(parser, text)}
  end

  def invoke(%__MODULE__{kind: :csv, opts: opts}, input, _opts),
    do:
      {:ok,
       BeamWeaver.OutputParser.parse_csv(
         BeamWeaver.OutputParser.text(input),
         Map.get(opts, :separator, ",")
       )}

  def invoke(%__MODULE__{kind: :xml}, input, _opts),
    do: BeamWeaver.OutputParser.parse_xml(BeamWeaver.OutputParser.text(input))

  def invoke(%__MODULE__{kind: :openai_tools, opts: opts}, input, _opts),
    do: BeamWeaver.OutputParser.parse_openai_tools(input, opts)

  def invoke(%__MODULE__{kind: :openai_functions, opts: opts}, input, _opts),
    do: BeamWeaver.OutputParser.parse_openai_functions(input, opts)

  def invoke(%__MODULE__{kind: :schema, opts: %{schema: schema} = opts}, input, _opts) do
    with {:ok, data} <- BeamWeaver.OutputParser.parse_json(BeamWeaver.OutputParser.text(input)),
         :ok <- BeamWeaver.OutputParser.validate_schema(schema, data) do
      BeamWeaver.OutputParser.cast_schema(data, Map.get(opts, :as))
    end
  end

  def stream(%__MODULE__{kind: :json} = parser, input, _opts),
    do: BeamWeaver.OutputParser.stream_cumulative(parser, input)

  def stream(%__MODULE__{kind: :openai_tools} = parser, input, _opts),
    do: BeamWeaver.OutputParser.stream_openai_tools(parser, input)

  def transform(%__MODULE__{kind: :string}, input, _opts),
    do: BeamWeaver.OutputParser.transform_string(input)

  def transform(%__MODULE__{kind: :json} = parser, input, _opts),
    do: BeamWeaver.OutputParser.stream_cumulative(parser, input)

  def transform(%__MODULE__{kind: :list} = parser, input, _opts),
    do: BeamWeaver.OutputParser.transform_list(parser, input)

  def transform(%__MODULE__{kind: :xml}, input, _opts),
    do: BeamWeaver.OutputParser.transform_xml(input)

  def transform(%__MODULE__{} = parser, input, opts), do: invoke(parser, input, opts)
end
