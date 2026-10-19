defmodule BeamWeaver.Core.Messages.OpenAI do
  @moduledoc false

  import BeamWeaver.MapShape, only: [reject_nil_values: 1]

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.MapShape
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.Provider.MessageCodec
  alias BeamWeaver.Result

  @spec convert(term(), keyword(), (term() -> {:ok, [Message.t()]} | {:error, Error.t()})) ::
          {:ok, term()} | {:error, Error.t()}
  def convert(messages, opts, normalizer) when is_function(normalizer, 1) do
    if Keyword.get(opts, :api) == :responses do
      convert_responses_input(messages, opts, normalizer)
    else
      single? = not is_list(messages)

      with {:ok, messages} <- normalizer.(messages),
           {:ok, format} <- normalize_text_format(Keyword.get(opts, :text_format, :string)) do
        encoded = Enum.map(messages, &chat_completion_message(&1, format, opts))
        {:ok, if(single?, do: List.first(encoded) || %{}, else: encoded)}
      end
    end
  end

  # An assistant message with tool calls encodes to several input items.
  defp convert_responses_input(messages, opts, normalizer) do
    with {:ok, messages} <- normalizer.(messages) do
      Result.flat_traverse(messages, &MessageCodec.encode(&1, Keyword.put(opts, :provider, :openai)))
    end
  end

  defp normalize_text_format(format) when format in [:string, "string"], do: {:ok, :string}
  defp normalize_text_format(format) when format in [:block, "block"], do: {:ok, :block}

  defp normalize_text_format(format) do
    {:error,
     Error.new(
       :invalid_openai_text_format,
       "supported OpenAI text formats are :string and :block",
       %{format: format}
     )}
  end

  defp chat_completion_message(%Message{} = message, text_format, opts) do
    case user_tool_result(message) do
      nil ->
        content = chat_completion_content(message, text_format, opts)

        %{
          "role" => chat_completion_role(message),
          "content" => content
        }
        |> put_if_present("name", message.name)
        |> put_if(Keyword.get(opts, :include_id, false), "id", message.id)
        |> put_tool_call_id(message)
        |> put_assistant_tool_calls(message)
        |> put_refusal(message)

      block ->
        %{
          "role" => "tool",
          "content" => content_to_chat_completion(Map.get(block, :content) || "", text_format, opts),
          "tool_call_id" => Map.get(block, :tool_use_id) || Map.get(block, :tool_call_id)
        }
        |> reject_nil_values()
    end
  end

  defp chat_completion_role(%Message{role: :system, metadata: %{openai_role: role}})
       when role in [:developer, "developer"],
       do: "developer"

  defp chat_completion_role(%Message{role: role}), do: Atom.to_string(role)

  defp chat_completion_content(%Message{role: :assistant, content: content}, text_format, opts)
       when is_list(content) do
    content
    |> Enum.reject(&tool_call_content_block?/1)
    |> content_to_chat_completion(text_format, opts)
  end

  defp chat_completion_content(%Message{content: content}, text_format, opts),
    do: content_to_chat_completion(content, text_format, opts)

  defp content_to_chat_completion(content, :string, opts) when is_list(content) do
    content = BeamWeaver.MapShape.assert_atom_keys_in!(content)

    if Enum.all?(content, &text_content_block?/1) do
      Enum.map_join(content, "\n", &text_content_block_text/1)
    else
      Enum.map(content, &content_block_to_chat_completion(&1, opts))
    end
  end

  defp content_to_chat_completion(content, :block, opts) when is_list(content) do
    content
    |> BeamWeaver.MapShape.assert_atom_keys_in!()
    |> Enum.map(&content_block_to_chat_completion(&1, opts))
  end

  defp content_to_chat_completion(content, :block, _opts) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp content_to_chat_completion(content, _format, _opts), do: content

  defp content_block_to_chat_completion(text, _opts) when is_binary(text),
    do: %{"type" => "text", "text" => text}

  defp content_block_to_chat_completion(%ContentBlock.Text{text: text}, _opts),
    do: %{"type" => "text", "text" => text}

  defp content_block_to_chat_completion(%ContentBlock.PlainText{text: text}, _opts),
    do: %{"type" => "text", "text" => text}

  defp content_block_to_chat_completion(%{type: type, text: text}, _opts)
       when type in [:text, :plain_text] and is_binary(text),
       do: %{"type" => "text", "text" => text}

  defp content_block_to_chat_completion(%{type: :image_url} = block, _opts),
    do: MapShape.stringify_keys(block)

  defp content_block_to_chat_completion(
         %{type: :image, source: %{type: :base64, media_type: mime_type, data: data}},
         _opts
       )
       when is_binary(mime_type) and is_binary(data),
       do: image_data_part(mime_type, data)

  defp content_block_to_chat_completion(%{type: :image, source_type: source_type, data: data} = block, _opts)
       when source_type in [:base64, "base64"] and is_binary(data),
       do: image_data_part(Map.get(block, :mime_type), data)

  defp content_block_to_chat_completion(%{type: :image, url: url} = block, _opts) when is_binary(url) do
    image_url = put_if_present(%{"url" => url}, "detail", Map.get(Map.get(block, :metadata) || %{}, :detail))
    %{"type" => "image_url", "image_url" => image_url}
  end

  defp content_block_to_chat_completion(%{type: :image, data: data} = block, _opts) when is_binary(data),
    do: image_data_part(Map.get(block, :mime_type), data)

  defp content_block_to_chat_completion(%{type: :image, base64: data} = block, _opts) when is_binary(data),
    do: image_data_part(Map.get(block, :mime_type), data)

  defp content_block_to_chat_completion(%{type: :media, mime_type: mime_type, data: data}, _opts)
       when is_binary(mime_type) and is_binary(data) do
    if String.starts_with?(mime_type, "image/"),
      do: image_data_part(mime_type, Base.encode64(data)),
      else: %{"type" => "text", "text" => ""}
  end

  defp content_block_to_chat_completion(%{type: :file, file: file}, _opts) when is_map(file),
    do: %{"type" => "file", "file" => MapShape.stringify_keys(file)}

  defp content_block_to_chat_completion(%{type: :file, file_id: id}, _opts) when is_binary(id),
    do: %{"type" => "file", "file" => %{"file_id" => id}}

  defp content_block_to_chat_completion(%{type: :file, source_type: source_type, id: id}, _opts)
       when source_type in [:id, "id"] and is_binary(id),
       do: %{"type" => "file", "file" => %{"file_id" => id}}

  defp content_block_to_chat_completion(%{type: :file, data: data} = block, _opts) when is_binary(data),
    do: file_data_part(block, data)

  defp content_block_to_chat_completion(%{type: :file, base64: data} = block, _opts) when is_binary(data),
    do: file_data_part(block, data)

  defp content_block_to_chat_completion(%{type: :file, url: url}, _opts) when is_binary(url),
    do: %{"type" => "file", "file" => %{"file_url" => url}}

  defp content_block_to_chat_completion(%{type: :audio, data: data} = block, _opts) when is_binary(data),
    do: input_audio_part(block, data)

  defp content_block_to_chat_completion(%{type: :audio, base64: data} = block, _opts) when is_binary(data),
    do: input_audio_part(block, data)

  defp content_block_to_chat_completion(%{type: :input_audio} = block, _opts),
    do: MapShape.stringify_keys(block)

  defp content_block_to_chat_completion(%{type: :json, json: data}, _opts),
    do: %{"type" => "text", "text" => BeamWeaver.JSON.encode!(data)}

  defp content_block_to_chat_completion(%{type: :guard_content, guard_content: %{text: text}}, _opts)
       when is_binary(text),
       do: %{"type" => "text", "text" => text}

  defp content_block_to_chat_completion(%ContentBlock.Reasoning{reasoning: text}, _opts),
    do: %{"type" => "reasoning", "reasoning" => text}

  defp content_block_to_chat_completion(%ContentBlock.Unknown{value: value}, opts)
       when is_map(value),
       do: pass_through_unknown_block(value, opts)

  defp content_block_to_chat_completion(%ContentBlock.Unknown{provider_type: type, value: value}, _opts),
    do: %{"type" => type, "value" => value}

  defp content_block_to_chat_completion(%{type: _type} = block, _opts) do
    MapShape.assert_atom_keys!(block)
    MapShape.stringify_keys(block)
  end

  defp content_block_to_chat_completion(block, opts) when is_map(block) do
    MapShape.assert_atom_keys!(block)
    pass_through_unknown_block(block, opts)
  end

  defp content_block_to_chat_completion(value, _opts),
    do: %{"type" => "text", "text" => inspect(value)}

  defp image_data_part(mime_type, data),
    do: %{"type" => "image_url", "image_url" => %{"url" => MessageParts.data_url(mime_type || "image/png", data)}}

  defp file_data_part(block, data) do
    file_data = MessageParts.data_url(Map.get(block, :mime_type) || "application/octet-stream", data)

    %{
      "type" => "file",
      "file" => %{"file_data" => file_data, "filename" => Map.get(block, :filename) || "LC_AUTOGENERATED"}
    }
  end

  defp input_audio_part(block, data) do
    format = audio_format(Map.get(block, :mime_type) || Map.get(block, :format))
    %{"type" => "input_audio", "input_audio" => %{"data" => data, "format" => format}}
  end

  defp pass_through_unknown_block(block, opts) do
    if Keyword.get(opts, :pass_through_unknown_blocks, true) do
      MapShape.stringify_keys(block)
    else
      raise ArgumentError, "Unrecognized content block"
    end
  end

  defp text_content_block?(text) when is_binary(text), do: true
  defp text_content_block?(%ContentBlock.PlainText{text: text}) when is_binary(text), do: true

  defp text_content_block?(%{type: :text, text: text}) when is_binary(text),
    do: true

  defp text_content_block?(_block), do: false

  defp text_content_block_text(text) when is_binary(text), do: text
  defp text_content_block_text(%{text: text}), do: text

  defp tool_call_content_block?(block) when is_map(block) do
    Map.get(block, :type) in [:tool_use, :tool_call, :function_call]
  end

  defp tool_call_content_block?(_block), do: false

  defp put_tool_call_id(map, %Message{role: :tool, tool_call_id: id}),
    do: put_if_present(map, "tool_call_id", id)

  defp put_tool_call_id(map, _message), do: map

  defp put_assistant_tool_calls(map, %Message{role: :assistant} = message) do
    calls =
      (message.tool_calls || [])
      |> Kernel.++(content_tool_calls(message.content))
      |> deduplicate_tool_calls()

    if calls == [] do
      map
    else
      Map.put(map, "tool_calls", Enum.map(calls, &tool_call_to_chat_completion/1))
    end
  end

  defp put_assistant_tool_calls(map, _message), do: map

  defp content_tool_calls(content) when is_list(content),
    do: for(block <- content, tool_call_content_block?(block), do: content_tool_call(block))

  defp content_tool_calls(_content), do: []

  # A call without an id is never a duplicate.
  defp deduplicate_tool_calls(calls) do
    Enum.uniq_by(calls, fn call ->
      case tool_call_request_id(call) do
        id when is_binary(id) and id != "" -> id
        _missing -> make_ref()
      end
    end)
  end

  defp content_tool_call(%{type: :tool_use} = block) do
    %{
      id: Map.get(block, :id),
      name: Map.get(block, :name),
      args: Map.get(block, :input) || Map.get(block, :args) || %{}
    }
  end

  defp content_tool_call(%{type: type} = block) when type in [:function_call, :tool_call] do
    %{
      id: Map.get(block, :call_id) || Map.get(block, :id),
      name: Map.get(block, :name),
      arguments: Map.get(block, :arguments) || Map.get(block, :args) || %{}
    }
  end

  defp tool_call_to_chat_completion(call) when is_map(call) do
    %{
      "type" => "function",
      "id" => tool_call_request_id(call),
      "function" => %{
        "name" => Map.get(call, :name),
        "arguments" => function_arguments(call)
      }
    }
    |> reject_nil_values()
  end

  defp tool_call_request_id(call) when is_map(call) do
    Map.get(call, :id) || Map.get(call, :call_id)
  end

  defp function_arguments(%{arguments: arguments}) when is_binary(arguments), do: arguments
  defp function_arguments(%{arguments: arguments}), do: BeamWeaver.JSON.encode!(arguments)
  defp function_arguments(%{args: args}), do: BeamWeaver.JSON.encode!(args)
  defp function_arguments(_call), do: "{}"

  defp put_refusal(map, %Message{role: :assistant, metadata: %{refusal: refusal}}),
    do: put_if_present(map, "refusal", refusal)

  defp put_refusal(map, _message), do: map

  defp user_tool_result(%Message{role: :user, content: [block]}) when is_map(block) do
    if Map.get(block, :type) == :tool_result, do: block
  end

  defp user_tool_result(_message), do: nil

  defp put_if(map, true, key, value), do: put_if_present(map, key, value)
  defp put_if(map, _condition, _key, _value), do: map

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp audio_format("audio/" <> subtype), do: subtype
  defp audio_format(_mime_type), do: "wav"
end
