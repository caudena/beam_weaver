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

      %{name: name, schema: schema} = format when is_binary(name) and is_map(schema) ->
        {:ok,
         %{
           "format" => Messages.structured_output_format(name, schema, strict: Map.get(format, :strict, true))
         }}

      %{"name" => name, "schema" => schema} = format when is_binary(name) and is_map(schema) ->
        {:ok,
         %{
           "format" => Messages.structured_output_format(name, schema, strict: Map.get(format, "strict", true))
         }}

      {name, schema} when is_binary(name) and is_map(schema) ->
        {:ok, %{"format" => Messages.structured_output_format(name, schema)}}

      other ->
        {:error,
         Error.new(:invalid_response_format, "structured output requires a name and schema", %{
           response_format: inspect(other)
         })}
    end
  end
end
