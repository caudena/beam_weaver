defprotocol BeamWeaver.Runnable.Configurable do
  @fallback_to_any true
  def configure(runnable, values)
end

defprotocol BeamWeaver.Runnable.Spec do
  @fallback_to_any true
  def to_spec(runnable)
end

defprotocol BeamWeaver.Runnable.Introspect do
  @fallback_to_any true
  def graph(runnable, opts)
  def input_schema(runnable)
  def output_schema(runnable)
  def config_specs(runnable)
end

defprotocol BeamWeaver.Runnable.Addable do
  @fallback_to_any true
  def add(left, right)
end

defimpl BeamWeaver.Runnable.Configurable, for: Any do
  alias BeamWeaver.Core.Error

  def configure(_runnable, _values) do
    {:error, Error.new(:unsupported_configurable, "runnable does not support configuration")}
  end
end

defimpl BeamWeaver.Runnable.Addable, for: Any do
  def add(nil, right), do: right
  def add(left, nil), do: left
  def add(left, right), do: [left, right]
end

defimpl BeamWeaver.Runnable.Addable, for: BitString do
  def add(left, right), do: left <> to_string(right)
end

defimpl BeamWeaver.Runnable.Addable, for: Map do
  def add(left, right) when is_map(right), do: Map.merge(left, right)
  def add(left, right), do: Map.put(left, :_right, right)
end

defimpl BeamWeaver.Runnable.Addable, for: List do
  def add(left, right) when is_list(right), do: left ++ right
  def add(left, right), do: left ++ [right]
end

defimpl BeamWeaver.Runnable.Addable, for: BeamWeaver.Core.Messages.AIChunk do
  alias BeamWeaver.Core.Messages.MessageChunk

  def add(left, right), do: MessageChunk.merge(left, right)
end

defimpl BeamWeaver.Runnable.Spec, for: Any do
  alias BeamWeaver.Core.Error

  def to_spec(runnable) do
    {:error,
     Error.new(:unsupported_runnable_spec, "runnable cannot be exported as a safe spec", %{
       runnable: inspect(runnable)
     })}
  end
end

defimpl BeamWeaver.Runnable.Introspect, for: Any do
  alias BeamWeaver.Runnable.Graph

  def graph(runnable, _opts), do: Graph.single(runnable)
  def input_schema(_runnable), do: %{"type" => "any"}
  def output_schema(_runnable), do: %{"type" => "any"}
  def config_specs(_runnable), do: []
end
