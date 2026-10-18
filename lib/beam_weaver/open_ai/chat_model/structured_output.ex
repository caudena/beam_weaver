defmodule BeamWeaver.OpenAI.ChatModel.StructuredOutput do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.Messages
  alias BeamWeaver.Provider.Options

  def format(opts) do
    case Keyword.get(opts, :response_format) || Keyword.get(opts, :structured_output) do
      nil ->
        {:ok, nil}

      %{"type" => "json_schema"} = format ->
        {:ok, %{"format" => format}}

      %{type: "json_schema"} = format ->
        {:ok, %{"format" => Options.stringify_keys(format)}}

      format ->
        with {:ok, format} <- schema_format(format, &Messages.structured_output_format/3),
             do: {:ok, %{"format" => format}}
    end
  end

  # The format `build` makes of a name and a schema, given as a pair or as a
  # map, which may also say whether it is `strict`.
  @doc false
  def schema_format(%{name: name, schema: schema} = format, build) when is_binary(name) and is_map(schema),
    do: {:ok, build.(name, schema, strict: Map.get(format, :strict, true))}

  def schema_format(%{"name" => name, "schema" => schema} = format, build) when is_binary(name) and is_map(schema),
    do: {:ok, build.(name, schema, strict: Map.get(format, "strict", true))}

  def schema_format({name, schema}, build) when is_binary(name) and is_map(schema), do: {:ok, build.(name, schema, [])}

  def schema_format(other, _build) do
    {:error,
     Error.new(:invalid_response_format, "structured output requires a name and schema", %{
       response_format: inspect(other)
     })}
  end
end
