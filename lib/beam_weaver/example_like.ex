defprotocol BeamWeaver.ExampleLike do
  @moduledoc """
  Converts examples into plain maps for selectors and prompt examples.
  """

  @fallback_to_any true

  @spec to_example(t()) :: {:ok, map()} | {:error, BeamWeaver.Core.Error.t()}
  def to_example(value)
end

defimpl BeamWeaver.ExampleLike, for: Map do
  def to_example(value), do: {:ok, value}
end

defimpl BeamWeaver.ExampleLike, for: BeamWeaver.Core.Document do
  def to_example(document),
    do: {:ok, Map.put(document.metadata || %{}, :content, document.content)}
end

defimpl BeamWeaver.ExampleLike, for: Any do
  alias BeamWeaver.Core.Error

  def to_example(_value),
    do: {:error, Error.new(:invalid_example_like, "expected an example map")}
end
