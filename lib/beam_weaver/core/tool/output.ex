defmodule BeamWeaver.Core.Tool.Output do
  @moduledoc false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.ToolResult

  def format(content, opts \\ []) do
    tool_call_id = Keyword.get(opts, :tool_call_id)
    name = Keyword.get(opts, :name)
    artifact = Keyword.get(opts, :artifact)
    status = Keyword.get(opts, :status, :success)

    cond do
      tool_output?(content) ->
        content

      is_list(content) and content != [] and Enum.all?(content, &tool_output?/1) ->
        content

      is_nil(tool_call_id) ->
        content

      true ->
        {content, artifact, status} = split_result(content, artifact, status)

        Message.tool(message_content(content),
          name: name,
          tool_call_id: tool_call_id,
          artifacts: List.wrap(artifact) |> Enum.reject(&is_nil/1),
          status: status
        )
    end
  end

  def split_result(%ToolResult{} = result, _artifact, _status),
    do: {result.content, result.artifact, result.status}

  def split_result({content, artifact}, _artifact, status), do: {content, artifact, status}
  def split_result(content, artifact, status), do: {content, artifact, status}

  defp tool_output?(%Message{role: :tool}), do: true
  defp tool_output?(%ToolResult{}), do: true
  defp tool_output?(_content), do: false

  defp message_content(content) when is_binary(content), do: content

  defp message_content([]), do: stringify_content([])

  defp message_content(content) when is_list(content) do
    if Enum.all?(content, &message_content_block?/1),
      do: content,
      else: stringify_content(content)
  end

  defp message_content(content), do: stringify_content(content)

  defp message_content_block?(text) when is_binary(text), do: true

  defp message_content_block?(block) when is_map(block) do
    type = Map.get(block, :type) || Map.get(block, "type")

    type in [
      :text,
      "text",
      :image_url,
      "image_url",
      :image,
      "image",
      :json,
      "json",
      :search_result,
      "search_result",
      :custom_tool_call_output,
      "custom_tool_call_output",
      :document,
      "document",
      :file,
      "file"
    ]
  end

  defp message_content_block?(_block), do: false

  defp stringify_content(content) do
    BeamWeaver.JSON.encode!(content)
  rescue
    _exception -> inspect(content)
  end
end
