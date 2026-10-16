defprotocol BeamWeaver.Runnable.Addable do
  @moduledoc false
  @fallback_to_any true
  def add(left, right)
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
