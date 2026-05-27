defprotocol BeamWeaver.Tool.SchemaLike do
  @moduledoc """
  Converts explicit schema-like values into JSON-schema-like maps.
  """

  @fallback_to_any true

  @spec to_schema(term()) :: {:ok, map()} | {:error, BeamWeaver.Core.Error.t()}
  def to_schema(value)
end

defimpl BeamWeaver.Tool.SchemaLike, for: Map do
  def to_schema(map), do: {:ok, BeamWeaver.Tool.Schema.Fields.stringify_schema(map)}
end

defimpl BeamWeaver.Tool.SchemaLike, for: List do
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Tool.Schema.Fields

  def to_schema([]), do: {:ok, Fields.from_fields([])}

  def to_schema(list) do
    cond do
      Enum.all?(list, &nimble_option?/1) ->
        Fields.from_nimble_options(list)

      Enum.all?(list, &field_decl?/1) ->
        {:ok, Fields.from_fields(Enum.map(list, &normalize_field_decl/1))}

      true ->
        {:error,
         Error.new(
           :invalid_tool_schema,
           "list schema must be field declarations or NimbleOptions specs"
         )}
    end
  end

  defp field_decl?({name, _type}) when is_atom(name) or is_binary(name), do: true

  defp field_decl?({name, _type, opts}) when (is_atom(name) or is_binary(name)) and is_list(opts),
    do: true

  defp field_decl?(_entry), do: false

  defp normalize_field_decl({name, type}), do: {name, type, []}
  defp normalize_field_decl({name, type, opts}), do: {name, type, opts}

  defp nimble_option?({name, opts}) when (is_atom(name) or is_binary(name)) and is_list(opts) do
    Keyword.keyword?(opts) and Keyword.has_key?(opts, :type)
  end

  defp nimble_option?(_entry), do: false
end

defimpl BeamWeaver.Tool.SchemaLike, for: Atom do
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Tool.Schema.Fields
  alias BeamWeaver.Tool.SchemaLike

  def to_schema(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__beam_weaver_schema__, 0) do
      SchemaLike.to_schema(module.__beam_weaver_schema__())
    else
      Fields.from_ecto_schema(module)
    end
  rescue
    exception ->
      {:error,
       Error.new(:invalid_tool_schema, "schema module conversion failed", %{
         module: inspect(module),
         reason: Exception.message(exception)
       })}
  end
end

defimpl BeamWeaver.Tool.SchemaLike, for: Any do
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Tool.SchemaLike

  def to_schema(%module{} = _struct) do
    SchemaLike.to_schema(module)
  end

  def to_schema(value) do
    {:error,
     Error.new(:invalid_tool_schema, "value cannot be converted to a tool schema", %{
       value: inspect(value)
     })}
  end
end
