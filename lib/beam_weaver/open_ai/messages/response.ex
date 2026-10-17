defmodule BeamWeaver.OpenAI.Messages.Response do
  @moduledoc false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.MessageParts

  @spec to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def to_message(%{"error" => %{"message" => message} = error})
      when is_binary(message) do
    {:error, Error.new(:response_error, message, %{error: MessageParts.stringify_keys(error)})}
  end

  def to_message(response) when is_map(response) do
    {tool_calls, invalid_tool_calls} = output_tool_calls(response)

    metadata =
      response
      |> response_metadata()
      |> put_invalid_tool_calls(invalid_tool_calls)

    Message.new(:assistant, response_content(response),
      id: response["id"],
      metadata: metadata,
      response_metadata: metadata,
      usage_metadata: usage_metadata(response),
      status: response["status"],
      tool_calls: tool_calls
    )
  end

  def to_message(_response) do
    {:error, Error.new(:invalid_response, "OpenAI response must be a JSON object")}
  end

  defp usage_metadata(%{"usage" => usage}) when is_map(usage), do: MessageParts.usage_metadata(usage, :responses)
  defp usage_metadata(_response), do: nil

  defp put_invalid_tool_calls(metadata, []), do: metadata

  defp put_invalid_tool_calls(metadata, invalid_tool_calls),
    do: Map.put(metadata, :invalid_tool_calls, invalid_tool_calls)

  defp output_text(%{"output_text" => text}) when is_binary(text), do: text

  defp output_text(%{"output" => output}) when is_list(output) do
    output
    |> Enum.flat_map(&message_content_text/1)
    |> Enum.join("")
  end

  defp output_text(_response), do: ""

  defp response_content(response) do
    blocks = output_content_blocks(response)

    if blocks == [] do
      output_text(response)
    else
      blocks
    end
  end

  defp output_content_blocks(%{"output" => output}) when is_list(output) do
    Enum.flat_map(output, &output_item_blocks/1)
  end

  defp output_content_blocks(%{"choices" => choices}) when is_list(choices) do
    choices
    |> Enum.flat_map(fn choice ->
      case get_in(choice, ["message", "content"]) do
        content when is_binary(content) -> [%{type: :text, text: content}]
        _missing -> []
      end
    end)
  end

  defp output_content_blocks(_response), do: []

  defp output_item_blocks(%{"type" => "message", "content" => content} = item)
       when is_list(content) do
    Enum.flat_map(content, &message_part_block(&1, item["id"]))
  end

  defp output_item_blocks(%{"type" => "reasoning"} = item) do
    [reasoning_block(item)]
  end

  # Preserve future provider output items as opaque content. Only explicit
  # function calls become client-executable calls below.
  defp output_item_blocks(%{"type" => type} = item) when is_binary(type), do: [provider_output_block(item)]

  defp output_item_blocks(_item), do: []

  defp message_part_block(%{"type" => type, "text" => text} = part, item_id)
       when type in ["output_text", "text"] and is_binary(text) do
    [
      %{
        type: :text,
        text: text,
        phase: part["phase"],
        annotations: part["annotations"]
      }
      |> MessageParts.reject_nil_values()
    ]
    |> put_part_item_id(item_id)
  end

  defp message_part_block(%{"type" => type} = part, item_id)
       when type in ["output_audio", "audio"] do
    [
      %{
        type: :audio,
        id: part["id"],
        data: part["data"],
        url: part["url"],
        audio: part["audio"],
        mime_type: part["mime_type"] || part["format"],
        raw_provider_block: part
      }
      |> MessageParts.reject_nil_values()
    ]
    |> put_part_item_id(item_id)
  end

  defp message_part_block(%{"type" => "refusal"} = part, item_id) do
    [
      %{
        type: :refusal,
        refusal: part["refusal"],
        raw_provider_block: part
      }
      |> MessageParts.reject_nil_values()
    ]
    |> put_part_item_id(item_id)
  end

  defp message_part_block(_part, _item_id), do: []

  defp reasoning_block(item) do
    %{
      type: :reasoning,
      id: item["id"],
      reasoning: reasoning_text(item),
      summary: item["summary"],
      status: item["status"],
      encrypted_content: item["encrypted_content"],
      raw_provider_block: item
    }
    |> MessageParts.reject_nil_values()
  end

  defp reasoning_text(%{"reasoning" => reasoning}) when is_binary(reasoning), do: reasoning

  defp reasoning_text(%{"content" => content} = item) when is_list(content) do
    text =
      content
      |> Enum.flat_map(fn
        %{"type" => type, "text" => text}
        when type in ["reasoning_text", "text"] and is_binary(text) ->
          [text]

        _part ->
          []
      end)
      |> Enum.join("")

    if text == "", do: reasoning_summary_text(item["summary"]), else: text
  end

  defp reasoning_text(%{"summary" => summaries}), do: reasoning_summary_text(summaries)

  defp reasoning_text(_item), do: nil

  defp reasoning_summary_text(summaries) when is_list(summaries) do
    text =
      summaries
      |> Enum.flat_map(fn
        %{"text" => text} when is_binary(text) -> [text]
        %{"summary_text" => text} when is_binary(text) -> [text]
        %{"type" => "summary_text", "text" => text} when is_binary(text) -> [text]
        _part -> []
      end)
      |> Enum.join("")

    if text == "", do: nil, else: text
  end

  defp reasoning_summary_text(_summaries), do: nil

  defp put_part_item_id(parts, nil), do: parts

  defp put_part_item_id(parts, item_id) do
    Enum.map(parts, &Map.put_new(&1, :id, item_id))
  end

  defp provider_output_block(%{"type" => "function_call"} = item) do
    %{
      type: :tool_call,
      id: item["call_id"] || item["id"],
      provider_id: item["id"],
      call_id: item["call_id"],
      name: item["name"],
      arguments: item["arguments"],
      status: item["status"],
      raw_provider_block: item
    }
    |> MessageParts.reject_nil_values()
  end

  defp provider_output_block(%{"type" => type} = item) do
    %{
      type: type,
      id: item["id"],
      status: item["status"],
      queries: item["queries"],
      results: item["results"],
      result: item["result"],
      action: item["action"],
      container_id: item["container_id"],
      input: item["input"],
      call_id: item["call_id"],
      caller: item["caller"],
      code: item["code"],
      created_by: item["created_by"],
      fingerprint: item["fingerprint"],
      max_output_length: item["max_output_length"],
      name: item["name"],
      namespace: item["namespace"],
      patch: item["patch"],
      output: item["output"],
      error: item["error"],
      tools: item["tools"],
      execution: item["execution"],
      raw_provider_block: item
    }
    |> MessageParts.reject_nil_values()
  end

  defp message_content_text(%{"type" => "message", "content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => type, "text" => text}
      when type in ["output_text", "text"] and is_binary(text) ->
        [text]

      %{"text" => text} when is_binary(text) ->
        [text]

      _part ->
        []
    end)
  end

  defp message_content_text(_item), do: []

  defp output_tool_calls(%{"output" => output}) when is_list(output) do
    output
    |> Enum.filter(&(Map.get(&1, "type") == "function_call"))
    |> split_tool_calls(&output_tool_call/1)
  end

  defp output_tool_calls(%{"choices" => choices}) when is_list(choices) do
    choices
    |> Enum.flat_map(&(get_in(&1, ["message", "tool_calls"]) || []))
    |> split_tool_calls(&chat_tool_call/1)
  end

  defp output_tool_calls(_response), do: {[], []}

  defp split_tool_calls(items, decode) do
    {valid, invalid} = items |> Enum.map(decode) |> Enum.split_with(&match?({:ok, _call}, &1))
    {Enum.map(valid, &elem(&1, 1)), Enum.map(invalid, &elem(&1, 1))}
  end

  defp output_tool_call(item),
    do: tool_call(item["call_id"] || item["id"], item["id"], item["call_id"], item["name"], item["arguments"])

  defp chat_tool_call(%{"function" => function} = item) when is_map(function),
    do: tool_call(item["id"], item["id"], item["id"], function["name"], function["arguments"])

  defp chat_tool_call(_item), do: {:error, Messages.invalid_tool_call(error: "invalid tool call")}

  defp tool_call(id, provider_id, call_id, name, arguments) do
    fields = [id: id, provider_id: provider_id, call_id: call_id, name: name]

    case decode_arguments(arguments) do
      {:ok, args} -> {:ok, Messages.tool_call(fields ++ [args: args])}
      {:error, error} -> {:error, Messages.invalid_tool_call(fields ++ [args: arguments, error: error])}
    end
  end

  defp decode_arguments(arguments) when is_binary(arguments) do
    case BeamWeaver.JSON.decode(arguments) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, decoded} ->
        {:error, "function call arguments decoded to #{inspect(decoded)}, expected an object"}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  defp decode_arguments(nil), do: {:ok, %{}}
  defp decode_arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  defp decode_arguments(arguments),
    do: {:error, "function call arguments are not decodable: #{inspect(arguments)}"}

  defp response_metadata(response) do
    header_metadata = response["_beamweaver_response_header_metadata"] || %{}

    %{
      id: response["id"],
      request_id: header_metadata[:request_id],
      model: response["model"],
      model_provider: "openai",
      provider: :openai,
      usage: response["usage"],
      output: normalize_output(response["output"]),
      audio: first_message_part(response, ["output_audio", "audio"]),
      reasoning: first_output_item(response, "reasoning"),
      reasoning_context: get_in(response, ["reasoning", "context"]),
      access_programs: response["access_programs"],
      headers: header_metadata[:headers],
      transport: BeamWeaver.Provider.ResponseDecoder.transport_metadata(header_metadata),
      provider_metadata: response["metadata"],
      moderation: response["moderation"],
      prompt_cache_diagnostics: response["prompt_cache_diagnostics"],
      incomplete_details: response["incomplete_details"],
      status: response["status"],
      user: response["user"],
      service_tier: response["service_tier"],
      raw_provider_response: response
    }
    |> MessageParts.reject_nil_values()
  end

  defp normalize_output(output) when is_list(output),
    do: output

  defp normalize_output(_output), do: nil

  defp first_output_item(%{"output" => output}, type) when is_list(output) do
    Enum.find(output, &(Map.get(&1, "type") == type))
  end

  defp first_output_item(_response, _type), do: nil

  defp first_message_part(%{"output" => output}, types) when is_list(output) do
    Enum.find_value(output, fn
      %{"type" => "message", "content" => content} when is_list(content) ->
        Enum.find(content, &(Map.get(&1, "type") in types))

      _item ->
        nil
    end)
  end

  defp first_message_part(_response, _types), do: nil
end
