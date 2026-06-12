defprotocol BeamWeaver.Adapter.Introspect do
  @moduledoc """
  Optional operational metadata for adapter structs.
  """

  @fallback_to_any true

  @spec metadata(term()) :: map()
  def metadata(adapter)
end

defimpl BeamWeaver.Adapter.Introspect, for: Any do
  def metadata(%{__struct__: module} = adapter) do
    adapter
    |> Map.from_struct()
    |> Map.take([:table, :checkpoints_table, :writes_table, :namespace, :dimensions, :index])
    |> Map.put(:adapter, module)
  end

  def metadata(adapter), do: %{adapter: inspect(adapter)}
end
