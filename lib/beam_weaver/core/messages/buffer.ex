defmodule BeamWeaver.Core.Messages.Buffer do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  def render(messages, opts \\ []) do
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

  defp buffer_line(%Message{} = message, opts) do
    prefix = buffer_prefix(message, opts)
    tool_info = assistant_tool_info(message)
    "#{prefix}: #{Message.text(message)}#{tool_info}"
  end

  defp buffer_prefix(%Message{} = message, opts) do
    buffer_prefix(message.role, opts)
  end

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
    type = message |> xml_message_type(opts) |> xml_attr()
    content_parts = xml_content_parts(message.content) ++ xml_server_tool_parts(message)

    if message.role == :assistant and message.tool_calls != [] do
      parts = ["<message type=#{type}>"]

      parts =
        if content_parts == [],
          do: parts,
          else: parts ++ ["  <content>#{Enum.join(content_parts, " ")}</content>"]

      tool_parts =
        Enum.map(message.tool_calls, fn call ->
          id = call |> tool_call_id() |> Kernel.||("") |> to_string() |> xml_attr()
          name = call |> tool_call_name() |> Kernel.||("") |> to_string() |> xml_attr()
          args = call |> tool_call_args() |> json_string() |> xml_escape()
          "  <tool_call id=#{id} name=#{name}>#{args}</tool_call>"
        end)

      (parts ++ tool_parts ++ ["</message>"])
      |> Enum.join("\n")
    else
      "<message type=#{type}>#{Enum.join(content_parts, " ")}</message>"
    end
  end

  defp xml_message_type(%Message{} = message, opts) do
    xml_role_type(message, opts)
  end

  defp xml_role_type(%Message{role: :user}, opts),
    do: opts |> Keyword.get(:human_prefix, "Human") |> to_string() |> String.downcase()

  defp xml_role_type(%Message{role: :assistant}, opts),
    do: opts |> Keyword.get(:ai_prefix, "AI") |> to_string() |> String.downcase()

  defp xml_role_type(%Message{role: :system}, opts),
    do: opts |> Keyword.get(:system_prefix, "System") |> to_string() |> String.downcase()

  defp xml_role_type(%Message{role: :tool}, opts),
    do: opts |> Keyword.get(:tool_prefix, "Tool") |> to_string() |> String.downcase()

  defp xml_content_parts(content) when is_binary(content) do
    if content == "", do: [], else: [xml_escape(content)]
  end

  defp xml_content_parts(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      text when is_binary(text) ->
        if text == "", do: [], else: [xml_escape(text)]

      block when is_map(block) ->
        case xml_content_block(block) do
          nil -> []
          value -> [value]
        end

      _other ->
        []
    end)
  end

  defp xml_content_parts(_content), do: []

  defp xml_content_block(%ContentBlock.Text{text: text}), do: text |> empty_to_nil() |> maybe_xml_escape()

  defp xml_content_block(%ContentBlock.PlainText{text: text}),
    do: text |> truncate_xml_text() |> maybe_xml_escape()

  defp xml_content_block(%ContentBlock.Reasoning{reasoning: reasoning}) do
    reasoning
    |> empty_to_nil()
    |> then(fn
      nil -> nil
      value -> "<reasoning>#{xml_escape(to_string(value))}</reasoning>"
    end)
  end

  defp xml_content_block(%ContentBlock.Image{} = block) do
    if base64_block?(block), do: nil, else: xml_media_block("image", block)
  end

  defp xml_content_block(%ContentBlock.Audio{} = block) do
    if base64_block?(block), do: nil, else: xml_media_block("audio", block)
  end

  defp xml_content_block(%ContentBlock.Video{} = block) do
    if base64_block?(block), do: nil, else: xml_media_block("video", block)
  end

  defp xml_content_block(block) do
    cond do
      base64_block?(block) ->
        nil

      block_type(block) == :text ->
        block |> map_value(:text) |> empty_to_nil() |> maybe_xml_escape()

      block_type(block) == :reasoning ->
        block
        |> map_value(:reasoning)
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
        block |> map_value(:text) |> truncate_xml_text() |> maybe_xml_escape()

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
    id = call |> map_value(:id) |> Kernel.||("") |> to_string() |> xml_attr()
    name = call |> map_value(:name) |> Kernel.||("") |> to_string() |> xml_attr()

    args =
      call
      |> map_value(:args)
      |> Kernel.||(%{})
      |> json_string()
      |> truncate_xml_text()
      |> xml_escape()

    "<server_tool_call id=#{id} name=#{name}>#{args}</server_tool_call>"
  end

  defp xml_server_tool_call(_call), do: nil

  defp xml_server_tool_result(result) when is_map(result) do
    tool_call_id =
      result |> map_value(:tool_call_id) |> Kernel.||("") |> to_string() |> xml_attr()

    status = result |> map_value(:status) |> Kernel.||("") |> to_string() |> xml_attr()

    output =
      case map_value(result, :output) do
        nil -> ""
        value -> value |> json_string() |> truncate_xml_text() |> xml_escape()
      end

    "<server_tool_result tool_call_id=#{tool_call_id} status=#{status}>#{output}</server_tool_result>"
  end

  defp xml_server_tool_result(_result), do: nil

  defp xml_media_block(tag, block) do
    image_url = map_value(block, :image_url)

    url =
      map_value(block, :url) ||
        nested_map_value(image_url, :url)

    file_id = map_value(block, :file_id)

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
    image_url = map_value(block, :image_url)

    truthy?(map_value(block, :base64)) or data_url?(map_value(block, :url)) or
      truthy?(map_value(block, :data)) or data_url?(nested_map_value(image_url, :url))
  end

  defp tool_call_id(call) when is_map(call), do: Map.get(call, :id)

  defp tool_call_name(call) when is_map(call),
    do: Map.get(call, :name, "")

  defp tool_call_args(call) when is_map(call),
    do: Map.get(call, :args, %{})

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)

  defp nested_map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp nested_map_value(_map, _key), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(value), do: value
  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_value), do: true
  defp data_url?(value) when is_binary(value), do: String.starts_with?(value, "data:")
  defp data_url?(_value), do: false

  defp maybe_xml_escape(nil), do: nil
  defp maybe_xml_escape(value), do: xml_escape(to_string(value))

  defp truncate_xml_text(nil), do: nil

  defp truncate_xml_text(value) do
    value = to_string(value)
    if String.length(value) > 500, do: String.slice(value, 0, 500) <> "...", else: value
  end

  defp json_string(value) do
    BeamWeaver.JSON.encode!(value)
  rescue
    _exception -> inspect(value)
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

  defp block_type(block), do: map_value(block, :type)
end
