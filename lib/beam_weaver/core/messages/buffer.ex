defmodule BeamWeaver.Core.Messages.Buffer do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  def render(messages, opts) do
    separator = Keyword.get(opts, :message_separator, "\n")

    case Keyword.get(opts, :format, :prefix) |> normalize_format() do
      {:ok, :prefix} ->
        {:ok, Enum.map_join(messages, separator, &buffer_line(&1, opts))}

      {:ok, :xml} ->
        {:ok, Enum.map_join(messages, separator, &xml_message(&1, opts))}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp buffer_line(%Message{} = message, opts),
    do: "#{buffer_prefix(message.role, opts)}: #{Message.text(message)}#{assistant_tool_info(message)}"

  defp buffer_prefix(:user, opts), do: Keyword.get(opts, :human_prefix, "Human")
  defp buffer_prefix(:assistant, opts), do: Keyword.get(opts, :ai_prefix, "AI")
  defp buffer_prefix(:system, opts), do: Keyword.get(opts, :system_prefix, "System")
  defp buffer_prefix(:tool, opts), do: Keyword.get(opts, :tool_prefix, "Tool")

  defp normalize_format(format) when format in [:prefix, "prefix"], do: {:ok, :prefix}
  defp normalize_format(format) when format in [:xml, "xml"], do: {:ok, :xml}

  defp normalize_format(format) do
    {:error,
     Error.new(:invalid_buffer_format, "supported buffer formats are :prefix and :xml", %{
       format: format
     })}
  end

  defp assistant_tool_info(%Message{role: :assistant, tool_calls: calls}) when calls != [],
    do: inspect(calls)

  defp assistant_tool_info(%Message{
         role: :assistant,
         metadata: %{function_call: function_call},
         tool_calls: []
       }),
       do: inspect(function_call)

  defp assistant_tool_info(%Message{
         role: :assistant,
         metadata: %{"function_call" => function_call},
         tool_calls: []
       }),
       do: inspect(function_call)

  defp assistant_tool_info(_message), do: ""

  defp xml_message(%Message{} = message, opts) do
    type = message.role |> buffer_prefix(opts) |> to_string() |> String.downcase() |> xml_attr()
    content_parts = xml_content_parts(message.content) ++ xml_server_tool_parts(message)

    if message.role == :assistant and message.tool_calls != [] do
      parts = ["<message type=#{type}>"]

      parts =
        if content_parts == [],
          do: parts,
          else: parts ++ ["  <content>#{Enum.join(content_parts, " ")}</content>"]

      tool_parts =
        Enum.map(message.tool_calls, fn call ->
          id = call |> Map.get(:id) |> Kernel.||("") |> to_string() |> xml_attr()
          name = call |> Map.get(:name, "") |> Kernel.||("") |> to_string() |> xml_attr()
          args = call |> Map.get(:args, %{}) |> json_string() |> xml_escape()
          "  <tool_call id=#{id} name=#{name}>#{args}</tool_call>"
        end)

      (parts ++ tool_parts ++ ["</message>"])
      |> Enum.join("\n")
    else
      "<message type=#{type}>#{Enum.join(content_parts, " ")}</message>"
    end
  end

  defp xml_content_parts(""), do: []
  defp xml_content_parts(content) when is_binary(content), do: [xml_escape(content)]

  defp xml_content_parts(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      "" ->
        []

      text when is_binary(text) ->
        [xml_escape(text)]

      block when is_map(block) ->
        List.wrap(xml_content_block(block))

      _other ->
        []
    end)
  end

  defp xml_content_parts(_content), do: []

  defp xml_content_block(%ContentBlock.PlainText{text: text}),
    do: text |> truncate_xml_text() |> maybe_xml_escape()

  defp xml_content_block(block) do
    cond do
      base64_block?(block) ->
        nil

      block_type(block) == :text ->
        block |> Map.get(:text) |> empty_to_nil() |> maybe_xml_escape()

      block_type(block) == :reasoning ->
        block
        |> Map.get(:reasoning)
        |> empty_to_nil()
        |> then(fn
          nil -> nil
          value -> "<reasoning>#{xml_escape(to_string(value))}</reasoning>"
        end)

      block_type(block) in [:image, :image_url] ->
        xml_media_block("image", block)

      block_type(block) == :audio ->
        xml_media_block("audio", block)

      block_type(block) == :video ->
        xml_media_block("video", block)

      block_type(block) == :"text-plain" ->
        block |> Map.get(:text) |> truncate_xml_text() |> maybe_xml_escape()

      block_type(block) == :server_tool_call ->
        xml_server_tool_call(block)

      block_type(block) == :server_tool_result ->
        xml_server_tool_result(block)

      true ->
        nil
    end
  end

  defp xml_server_tool_parts(%Message{} = message) do
    (Enum.map(message.server_tool_calls, &xml_server_tool_call/1) ++
       Enum.map(message.server_tool_results, &xml_server_tool_result/1))
    |> Enum.reject(&is_nil/1)
  end

  defp xml_server_tool_call(call) when is_map(call) do
    id = call |> Map.get(:id) |> Kernel.||("") |> to_string() |> xml_attr()
    name = call |> Map.get(:name) |> Kernel.||("") |> to_string() |> xml_attr()

    args =
      call
      |> Map.get(:args)
      |> Kernel.||(%{})
      |> json_string()
      |> truncate_xml_text()
      |> xml_escape()

    "<server_tool_call id=#{id} name=#{name}>#{args}</server_tool_call>"
  end

  defp xml_server_tool_call(_call), do: nil

  defp xml_server_tool_result(result) when is_map(result) do
    tool_call_id =
      result |> Map.get(:tool_call_id) |> Kernel.||("") |> to_string() |> xml_attr()

    status = result |> Map.get(:status) |> Kernel.||("") |> to_string() |> xml_attr()

    output =
      case Map.get(result, :output) do
        nil -> ""
        value -> value |> json_string() |> truncate_xml_text() |> xml_escape()
      end

    "<server_tool_result tool_call_id=#{tool_call_id} status=#{status}>#{output}</server_tool_result>"
  end

  defp xml_server_tool_result(_result), do: nil

  defp xml_media_block(tag, block) do
    url = Map.get(block, :url) || image_url(block)
    file_id = Map.get(block, :file_id)

    cond do
      is_binary(url) and url != "" ->
        "<#{tag} url=#{xml_attr(url)} />"

      is_binary(file_id) and file_id != "" ->
        "<#{tag} file_id=#{xml_attr(file_id)} />"

      true ->
        nil
    end
  end

  defp base64_block?(block) do
    Map.get(block, :base64) not in [nil, false] or data_url?(Map.get(block, :url)) or
      Map.get(block, :data) not in [nil, false] or data_url?(image_url(block))
  end

  defp image_url(%{image_url: %{url: url}}), do: url
  defp image_url(_block), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
  defp data_url?(value), do: match?("data:" <> _rest, value)

  defp maybe_xml_escape(nil), do: nil
  defp maybe_xml_escape(value), do: xml_escape(to_string(value))

  defp truncate_xml_text(nil), do: nil

  defp truncate_xml_text(value) do
    value = to_string(value)
    if String.length(value) > 500, do: String.slice(value, 0, 500) <> "...", else: value
  end

  defp json_string(value) do
    case BeamWeaver.JSON.encode(value) do
      {:ok, json} -> json
      {:error, _error} -> inspect(value)
    end
  end

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp xml_attr(value) do
    escaped =
      value
      |> xml_escape()
      |> String.replace("\"", "&quot;")

    ~s("#{escaped}")
  end

  defp block_type(block), do: Map.get(block, :type)
end
