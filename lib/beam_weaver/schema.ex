defprotocol BeamWeaver.Schema do
  @moduledoc """
  Converts BeamWeaver schema declarations to JSON-schema-like maps.
  """

  @fallback_to_any true

  @spec to_json_schema(term()) :: map()
  def to_json_schema(schema)
end

defimpl BeamWeaver.Schema, for: Map do
  def to_json_schema(schema), do: schema
end

defimpl BeamWeaver.Schema, for: Atom do
  def to_json_schema(module) when is_atom(module) do
    ensure_schema_module_compiled(module)

    if function_exported?(module, :__beam_weaver_schema__, 0) do
      module.__beam_weaver_schema__()
    else
      BeamWeaver.Tool.Schema.type_schema(module)
    end
  end

  defp ensure_schema_module_compiled(module) do
    case Code.ensure_compiled(module) do
      {:module, _module} ->
        :ok

      {:error, :nofile} ->
        :error

      {:error, reason} ->
        raise ArgumentError, "schema module #{inspect(module)} could not be loaded: #{inspect(reason)}"
    end
  end
end

defimpl BeamWeaver.Schema, for: Any do
  def to_json_schema(_schema), do: %{}
end
