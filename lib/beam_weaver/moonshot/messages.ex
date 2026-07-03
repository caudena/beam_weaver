defmodule BeamWeaver.Moonshot.Messages do
  @moduledoc """
  Moonshot/Kimi Chat Completions message translation.
  """

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Moonshot.Error
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.Result

  @spec to_chat_messages([Message.t()]) :: {:ok, [map()]} | {:error, Error.t()}
  def to_chat_messages(messages) when is_list(messages) do
    Result.traverse(messages, &to_chat_message/1)
  end

  def to_chat_messages(_messages) do
    {:error, Error.new(:invalid_messages, "Moonshot messages must be a list")}
  end

  @spec structured_output_format(String.t(), map(), keyword()) :: map()
  def structured_output_format(name, schema, opts \\ [])
      when is_binary(name) and is_map(schema) do
    %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => name,
        "schema" => MessageParts.stringify_keys(schema),
        "strict" => Keyword.get(opts, :strict, true)
      }
    }
  end

  @spec chat_response_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def chat_response_to_message(%{"error" => %{"message" => message} = error})
      when is_binary(message) do
    {:error, Error.new(:response_error, message, %{error: MessageParts.stringify_keys(error)})}
  end

  def chat_response_to_message(%{"choices" => [choice | _rest]} = response) do
    message = choice["message"] || %{}
    metadata = metadata(response, choice)

    Message.new(:assistant, response_content(message),
      id: response["id"],
      metadata: metadata,
      response_metadata: metadata,
      usage_metadata: usage_metadata(response),
      status: choice["finish_reason"],
      tool_calls: tool_calls(message)
    )
    |> case do
      {:ok, message} -> {:ok, message}
      {:error, error} -> {:error, Error.new(error.type, error.message, error.details)}
    end
  end

  def chat_response_to_message(_response) do
    {:error, Error.new(:invalid_response, "Moonshot chat-completions response is invalid")}
  end

  @spec metadata(map(), map()) :: map()
  def metadata(response, choice) do
    message = choice["message"] || %{}
    header_metadata = response["_beamweaver_response_header_metadata"] || %{}

    %{
      id: response["id"],
      request_id: header_metadata[:request_id],
      model: response["model"],
      model_name: response["model"],
      model_provider: "moonshot",
      provider: :moonshot,
      usage: response["usage"],
      token_usage: response["usage"],
      finish_reason: choice["finish_reason"],
      system_fingerprint: response["system_fingerprint"],
      service_tier: response["service_tier"],
      logprobs: choice["logprobs"],
      reasoning_content: message["reasoning_content"],
      headers: header_metadata[:headers],
      transport: transport_metadata(header_metadata),
      raw_provider_response: response
    }
    |> MessageParts.reject_nil_values()
  end

  defp transport_metadata(%{request_id: request_id}) when is_binary(request_id) and request_id != "" do
    %{request_id: request_id}
  end

  defp transport_metadata(_metadata), do: nil

  @spec usage_metadata(map()) :: map() | nil
  def usage_metadata(%{"usage" => usage}) when is_map(usage) do
    %{
      input_tokens: usage["prompt_tokens"] || usage["input_tokens"] || 0,
      output_tokens: usage["completion_tokens"] || usage["output_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0,
      input_token_details: input_token_details(usage),
      output_token_details: output_token_details(usage)
    }
    |> BeamWeaver.MapShape.reject_nil_or_empty()
  end

  def usage_metadata(_response), do: nil

  defp to_chat_message(%Message{role: :tool} = message) do
    call_id = message.tool_call_id || message.id

    if is_binary(call_id) and call_id != "" do
      {:ok,
       %{
         "role" => "tool",
         "tool_call_id" => call_id,
         "content" => tool_output(message.content)
       }
       |> put_optional("name", message.name)}
    else
      {:error, Error.new(:invalid_tool_message, "tool messages require a tool_call_id or id")}
    end
  end

  defp to_chat_message(%Message{role: :assistant} = message) do
    with {:ok, content} <- assistant_content(message) do
      {:ok,
       %{
         "role" => "assistant",
         "content" => content
       }
       |> put_optional("name", message.name)
       |> put_optional("tool_calls", assistant_tool_calls(message))
       |> put_optional("reasoning_content", assistant_reasoning_content(message))
       |> put_optional("partial", metadata_value(message.metadata, :partial))}
    end
  end

  defp to_chat_message(%Message{} = message) when message.role in [:system, :user] do
    with {:ok, content} <- content_to_moonshot(message.content) do
      {:ok,
       %{
         "role" => Atom.to_string(message.role),
         "content" => content
       }
       |> put_optional("name", message.name)}
    end
  end

  defp to_chat_message(_message),
    do: {:error, Error.new(:invalid_message, "expected a BeamWeaver message")}

  defp tool_output(content) when is_binary(content), do: content

  defp tool_output(content) when is_map(content) or is_list(content) do
    case BeamWeaver.JSON.encode(content) do
      {:ok, json} -> json
      {:error, _error} -> inspect(content)
    end
  end

  defp tool_output(content), do: to_string(content)

  defp assistant_content(%Message{content: content}) when is_binary(content), do: {:ok, content}

  defp assistant_content(%Message{content: content}) when is_list(content) do
    content_to_parts(content, skip_reasoning?: true)
  end

  defp assistant_content(%Message{content: content}), do: {:ok, to_string(content)}

  defp content_to_moonshot(content) when is_binary(content), do: {:ok, content}
  defp content_to_moonshot(content) when is_list(content), do: content_to_parts(content)
  defp content_to_moonshot(content), do: {:ok, to_string(content)}

  defp content_to_parts(content, opts \\ []) when is_list(content) do
    skip_reasoning? = Keyword.get(opts, :skip_reasoning?, false)

    content
    |> assert_atom_content_blocks!()
    |> Result.traverse(&content_part(&1, skip_reasoning?))
    |> case do
      {:ok, parts} ->
        case Enum.reject(parts, &is_nil/1) do
          [] -> {:ok, ""}
          parts -> {:ok, parts}
        end

      error ->
        error
    end
  end

  defp content_part(%ContentBlock.Text{text: text}, _skip_reasoning?),
    do: {:ok, %{"type" => "text", "text" => text}}

  defp content_part(%ContentBlock.PlainText{text: text}, _skip_reasoning?),
    do: {:ok, %{"type" => "text", "text" => text}}

  defp content_part(%ContentBlock.Image{} = block, _skip_reasoning?) do
    media_part("image_url", block.url, block.data, block.mime_type || "image/png")
  end

  defp content_part(%ContentBlock.Video{} = block, _skip_reasoning?) do
    media_part("video_url", block.url, block.data, block.mime_type || "video/mp4")
  end

  defp content_part(%ContentBlock.Audio{}, _skip_reasoning?),
    do: unsupported_content_block(:audio)

  defp content_part(%ContentBlock.File{}, _skip_reasoning?),
    do: unsupported_content_block(:file)

  defp content_part(%ContentBlock.Reasoning{}, true), do: {:ok, nil}

  defp content_part(%ContentBlock.Reasoning{reasoning: text}, _skip_reasoning?),
    do: {:ok, %{"type" => "reasoning", "reasoning" => text}}

  defp content_part(%ContentBlock.Unknown{value: value}, _skip_reasoning?) when is_map(value),
    do: {:ok, BeamWeaver.MapShape.stringify_keys(value)}

  defp content_part(%{} = block, skip_reasoning?) do
    BeamWeaver.MapShape.assert_atom_keys!(block)
    provider_block = BeamWeaver.MapShape.stringify_keys(block)

    case provider_type(Map.get(block, :type)) do
      "text" ->
        {:ok, %{"type" => "text", "text" => Map.get(block, :text) || Map.get(block, :content) || ""}}

      "image" ->
        media_part(
          "image_url",
          Map.get(block, :url),
          Map.get(block, :data) || Map.get(block, :base64),
          Map.get(block, :mime_type) || "image/png"
        )

      "video" ->
        media_part(
          "video_url",
          Map.get(block, :url),
          Map.get(block, :data) || Map.get(block, :base64),
          Map.get(block, :mime_type) || "video/mp4"
        )

      "image_url" ->
        validate_url_part(provider_block, "image_url")

      "video_url" ->
        validate_url_part(provider_block, "video_url")

      type when type in ["audio", "audio_url", "input_audio"] ->
        unsupported_content_block(:audio)

      type when type in ["file", "input_file"] ->
        unsupported_content_block(:file)

      "reasoning" when skip_reasoning? ->
        {:ok, nil}

      "reasoning" ->
        {:ok, %{"type" => "reasoning", "reasoning" => Map.get(block, :reasoning) || Map.get(block, :text)}}

      _other ->
        {:ok, provider_block}
    end
  end

  defp content_part(text, _skip_reasoning?) when is_binary(text),
    do: {:ok, %{"type" => "text", "text" => text}}

  defp content_part(other, _skip_reasoning?),
    do: {:ok, %{"type" => "text", "text" => to_string(other)}}

  defp media_part(kind, nil, data, mime_type) when is_binary(data) do
    {:ok, %{"type" => kind, kind => %{"url" => MessageParts.data_url(mime_type, data)}}}
  end

  defp media_part(kind, url, _data, _mime_type) when is_binary(url) do
    with :ok <- validate_media_url(url, kind) do
      {:ok, %{"type" => kind, kind => %{"url" => url}}}
    end
  end

  defp media_part(kind, _url, _data, _mime_type) do
    {:error,
     Error.new(:invalid_content_block, "Moonshot #{kind} blocks require data or ms:// URL", %{
       provider: :moonshot,
       type: kind
     })}
  end

  defp validate_url_part(block, kind) do
    url =
      case block[kind] do
        %{"url" => url} -> url
        url when is_binary(url) -> url
        _other -> block["url"]
      end

    with :ok <- validate_media_url(url, kind) do
      {:ok, %{"type" => kind, kind => %{"url" => url}}}
    end
  end

  defp validate_media_url("data:" <> _rest, _kind), do: :ok
  defp validate_media_url("ms://" <> _rest, _kind), do: :ok

  defp validate_media_url(url, kind) when is_binary(url) do
    {:error,
     Error.new(:unsupported_feature, "Moonshot Kimi media input requires data: or ms:// URLs", %{
       provider: :moonshot,
       feature: media_feature(kind),
       url: url,
       supported: ["data:", "ms://"]
     })}
  end

  defp validate_media_url(_url, kind) do
    {:error,
     Error.new(:invalid_content_block, "Moonshot #{kind} URL is invalid", %{
       provider: :moonshot,
       type: kind
     })}
  end

  defp media_feature("image"), do: :image
  defp media_feature("image_url"), do: :image_url
  defp media_feature("video"), do: :video
  defp media_feature("video_url"), do: :video_url
  defp media_feature(kind), do: kind

  defp unsupported_content_block(:audio) do
    {:error,
     Error.new(:unsupported_feature, "Moonshot Kimi does not support audio content blocks", %{
       provider: :moonshot,
       feature: :audio_input
     })}
  end

  defp unsupported_content_block(:file) do
    {:error,
     Error.new(:unsupported_feature, "Moonshot Kimi does not support file content blocks", %{
       provider: :moonshot,
       feature: :file_input
     })}
  end

  defp provider_type(type) when is_atom(type), do: Atom.to_string(type)
  defp provider_type(type), do: type

  defp assert_atom_content_blocks!(content) do
    Enum.each(content, fn
      block when is_struct(block) -> BeamWeaver.MapShape.assert_atom_keys!(Map.from_struct(block))
      block when is_map(block) -> BeamWeaver.MapShape.assert_atom_keys!(block)
      _block -> :ok
    end)

    content
  end

  defp assistant_tool_calls(%Message{} = message) do
    case message.tool_calls || [] do
      [] -> nil
      calls -> Enum.map(calls, &assistant_tool_call/1)
    end
  end

  defp assistant_tool_call(call) do
    call = BeamWeaver.MapShape.stringify_keys(call)

    %{
      "id" => call["provider_id"] || call["call_id"] || call["id"],
      "type" => "function",
      "function" => %{
        "name" => call["name"],
        "arguments" => encode_arguments(call["arguments"] || call["args"])
      }
    }
    |> MessageParts.reject_nil_values()
  end

  defp assistant_reasoning_content(%Message{} = message) do
    metadata_value(message.metadata, :reasoning_content) ||
      content_reasoning(message.content)
  end

  defp content_reasoning(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %ContentBlock.Reasoning{reasoning: text} when is_binary(text) -> [text]
      %{"type" => "reasoning", "reasoning" => text} when is_binary(text) -> [text]
      %{"type" => "reasoning", "text" => text} when is_binary(text) -> [text]
      %{type: :reasoning, reasoning: text} when is_binary(text) -> [text]
      %{type: :reasoning, text: text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> Enum.join("")
    |> empty_to_nil()
  end

  defp content_reasoning(_content), do: nil

  defp response_content(message) do
    reasoning = message["reasoning_content"]
    content = message["content"]

    cond do
      is_binary(reasoning) and reasoning != "" and is_binary(content) and content != "" ->
        [
          %{type: :reasoning, reasoning: reasoning},
          %{type: :text, text: content}
        ]

      is_binary(reasoning) and reasoning != "" and is_list(content) ->
        [%{type: :reasoning, reasoning: reasoning} | Enum.map(content, &response_content_block/1)]

      is_binary(reasoning) and reasoning != "" ->
        [%{type: :reasoning, reasoning: reasoning}]

      is_binary(content) ->
        content

      is_list(content) ->
        Enum.map(content, &response_content_block/1)

      true ->
        ""
    end
  end

  defp tool_calls(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
    Enum.map(tool_calls, fn call ->
      function = call["function"] || %{}

      Messages.tool_call(
        id: call["id"],
        provider_id: call["id"],
        call_id: call["id"],
        name: function["name"],
        args: decode_arguments(function["arguments"])
      )
    end)
  end

  defp tool_calls(_message), do: []

  defp input_token_details(usage) do
    %{
      cache_read:
        get_in(usage, ["input_tokens_details", "cached_tokens"]) ||
          get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
          usage["cached_tokens"]
    }
    |> BeamWeaver.MapShape.reject_nil_or_empty()
  end

  defp output_token_details(usage) do
    %{
      reasoning:
        get_in(usage, ["output_tokens_details", "reasoning_tokens"]) ||
          get_in(usage, ["completion_tokens_details", "reasoning_tokens"])
    }
    |> BeamWeaver.MapShape.reject_nil_or_empty()
  end

  defp encode_arguments(arguments) when is_binary(arguments), do: arguments
  defp encode_arguments(arguments), do: BeamWeaver.JSON.encode!(arguments || %{})

  defp decode_arguments(arguments) when is_binary(arguments) do
    case BeamWeaver.JSON.decode(arguments) do
      {:ok, decoded} -> decoded
      {:error, _error} -> arguments
    end
  end

  defp decode_arguments(arguments), do: arguments

  defp response_content_block(%{"type" => type, "text" => text}) when type in ["text", "output_text"] do
    %{type: :text, text: text}
  end

  defp response_content_block(%{"type" => "reasoning", "reasoning" => reasoning}) do
    %{type: :reasoning, reasoning: reasoning}
  end

  defp response_content_block(block) when is_map(block) do
    %{
      type: block["type"],
      text: block["text"],
      reasoning: block["reasoning"],
      raw_provider_block: block
    }
    |> MessageParts.reject_nil_values()
  end

  defp response_content_block(block), do: block

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

  defp metadata_value(_metadata, _key), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, []), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
