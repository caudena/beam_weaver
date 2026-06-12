defprotocol BeamWeaver.Core.ContentBlockLike do
  @moduledoc """
  Converts values into typed BeamWeaver content blocks.
  """

  @fallback_to_any true

  @spec to_content_block(term()) ::
          {:ok, term()} | {:error, BeamWeaver.Core.Error.t()}
  def to_content_block(value)
end

defimpl BeamWeaver.Core.ContentBlockLike, for: BitString do
  alias BeamWeaver.Core.ContentBlock

  def to_content_block("data:" <> _rest = uri), do: ContentBlock.from_data_uri(uri)
  def to_content_block(text), do: {:ok, ContentBlock.text(text)}
end

defimpl BeamWeaver.Core.ContentBlockLike, for: Map do
  def to_content_block(map), do: BeamWeaver.Core.ContentBlock.Normalizer.from_map(map)
end

defimpl BeamWeaver.Core.ContentBlockLike, for: Any do
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error

  def to_content_block(%ContentBlock.Text{} = block), do: {:ok, block}
  def to_content_block(%ContentBlock.PlainText{} = block), do: {:ok, block}
  def to_content_block(%ContentBlock.Image{} = block), do: {:ok, block}
  def to_content_block(%ContentBlock.Audio{} = block), do: {:ok, block}
  def to_content_block(%ContentBlock.File{} = block), do: {:ok, block}
  def to_content_block(%ContentBlock.Video{} = block), do: {:ok, block}
  def to_content_block(%ContentBlock.Reasoning{} = block), do: {:ok, block}
  def to_content_block(%ContentBlock.Citation{} = block), do: {:ok, block}
  def to_content_block(%ContentBlock.ToolResult{} = block), do: {:ok, block}
  def to_content_block(%ContentBlock.Unknown{} = block), do: {:ok, block}

  def to_content_block(value) do
    {:error,
     Error.new(:invalid_content_block, "value cannot be converted to a content block", %{
       value: inspect(value)
     })}
  end
end
