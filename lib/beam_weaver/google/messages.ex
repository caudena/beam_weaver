defmodule BeamWeaver.Google.Messages do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Provider.ChatCompletionsWire
  alias BeamWeaver.Provider.Options

  @default_mime_types %{"image" => "image/png", "audio" => "audio/mpeg", "video" => "video/mp4"}

  def encode_message(%Message{} = message, opts) do
    with {:ok, {_system, [encoded]}} <- encode_messages([message], opts), do: {:ok, encoded}
  end

  def decode_message(payload, opts), do: response_to_message(payload, opts)

  def encode_messages(messages, opts \\ [])

  def encode_messages(messages, _opts) when is_list(messages) do
    {system_messages, content_messages} = split_system_messages(messages)

    system =
      system_messages
      |> Enum.flat_map(&parts(&1.content))
      |> case do
        [] -> nil
        parts -> %{"parts" => parts}
      end

    contents =
      content_messages
      |> Enum.reject(&empty_user_message?/1)
      |> Enum.map(&content/1)
      |> merge_adjacent_user_content()

    {:ok, {system, contents}}
  rescue
    error in ArgumentError -> {:error, Error.new(:invalid_message, Exception.message(error))}
  end

  def encode_messages(_messages, _opts),
    do: {:error, Error.new(:invalid_message, "Google messages must be a list")}

  defp split_system_messages(messages) do
    {system_messages, content_messages, _saw_content?} =
      Enum.reduce(messages, {[], [], false}, fn
        %Message{role: :system} = message, {system_messages, content_messages, false} ->
          if conversation_summary_message?(message) do
            {system_messages, [demote_system_message(message) | content_messages], true}
          else
            {[message | system_messages], content_messages, false}
          end

        %Message{role: :system} = message, {system_messages, content_messages, true} ->
          {system_messages, [demote_system_message(message) | content_messages], true}

        message, {system_messages, content_messages, _saw_content?} ->
          {system_messages, [message | content_messages], true}
      end)

    {Enum.reverse(system_messages), Enum.reverse(content_messages)}
  end

  defp conversation_summary_message?(%Message{content: content, metadata: metadata}) do
    (is_binary(content) and String.starts_with?(content, "Conversation summary:")) or
      MapAccess.get(metadata, :conversation_history_path) != nil
  end

  defp demote_system_message(%Message{metadata: metadata} = message) do
    %{message | role: :user, metadata: Map.put(metadata || %{}, :google_demoted_system, true)}
  end

  @spec response_to_message(map(), keyword()) :: {:ok, Message.t()} | {:error, Error.t()}
  def response_to_message(response, _opts \\ [])

  def response_to_message(%{"error" => %{"message" => message} = error}, _opts)
      when is_binary(message) do
    {:error, Error.new(:response_error, message, %{error: Options.stringify_keys(error)})}
  end

  def response_to_message(response, _opts) when is_map(response) do
    candidate = first_candidate(response)
    blocks = response_blocks(candidate)
    metadata = response_metadata(response, candidate)

    Message.new(:assistant, message_content(blocks),
      id: response["responseId"] || response["id"],
      metadata: metadata,
      response_metadata: metadata,
      usage_metadata: usage_metadata(response["usageMetadata"]),
      status: metadata[:finish_reason],
      server_tool_calls: Enum.filter(blocks, &(&1.type == :server_tool_call)),
      server_tool_results: Enum.filter(blocks, &(&1.type == :server_tool_result)),
      tool_calls: tool_calls(blocks)
    )
  end

  def response_to_message(_response, _opts),
    do: {:error, Error.new(:invalid_response, "Google response must be a JSON object")}

  defp content(%Message{role: :tool} = message) do
    %{
      "role" => provider_role(:tool),
      "parts" => tool_result_parts(message)
    }
  end

  defp content(%Message{role: :assistant, response_metadata: %{provider_replay: %{provider: "google", content: parts}}})
       when is_list(parts), do: %{"role" => "model", "parts" => parts}

  defp content(%Message{role: role, content: message_content} = message) do
    %{
      "role" => provider_role(role),
      "parts" =>
        parts(message_content) ++
          message_tool_call_parts(message_content, message) ++ tool_result_parts(message)
    }
  end

  defp provider_role(:assistant), do: "model"
  defp provider_role(_role), do: "user"

  # Gemini represents both ordinary user input and function responses with the
  # `user` role. Keep a complete tool-result batch and a following steer in one
  # Content so the provider observes all function responses before the new
  # instruction, rather than two ambiguous adjacent user turns.
  defp merge_adjacent_user_content(contents) do
    contents
    |> Enum.reduce([], fn
      %{"role" => "user", "parts" => parts} = current,
      [%{"role" => "user", "parts" => previous_parts} = previous | rest]
      when is_list(parts) and is_list(previous_parts) ->
        if function_response_parts?(previous_parts) or function_response_parts?(parts) do
          [%{current | "parts" => previous_parts ++ parts} | rest]
        else
          [current, previous | rest]
        end

      current, acc ->
        [current | acc]
    end)
    |> Enum.reverse()
  end

  defp function_response_parts?(parts) do
    Enum.any?(parts, &match?(%{"functionResponse" => %{}}, &1))
  end

  defp parts(""), do: []
  defp parts(content) when is_binary(content), do: [%{"text" => content}]

  defp parts(content) when is_list(content) do
    content
    |> BeamWeaver.MapShape.assert_atom_keys_in!()
    |> Enum.flat_map(&part/1)
  end

  defp parts(content), do: [%{"text" => to_string(content)}]

  defp part(%module{text: text, metadata: metadata}) when module in [ContentBlock.Text, ContentBlock.PlainText],
    do: [%{"text" => text} |> put_thought_signature(thought_signature(metadata))]

  defp part(%ContentBlock.Image{} = block),
    do: media_part(block.file_id || block.url, block.data, block.mime_type || "image/png")

  defp part(%ContentBlock.Audio{} = block),
    do: media_part(block.file_id || block.url, block.data, block.mime_type || "audio/mpeg")

  defp part(%ContentBlock.Video{} = block),
    do: media_part(block.file_id || block.url, block.data, block.mime_type || "video/mp4")

  defp part(%ContentBlock.File{} = block),
    do: media_part(block.file_id || block.url, block.data, block.mime_type || "application/octet-stream")

  defp part(%ContentBlock.Reasoning{reasoning: text, metadata: metadata}) do
    [%{"thought" => true, "text" => text} |> put_thought_signature(thought_signature(metadata))]
  end

  defp part(%ContentBlock.ToolResult{} = block) do
    [
      %{
        "functionResponse" => %{
          "name" => block.metadata[:name] || block.tool_call_id || "tool",
          "response" => tool_response(block.content)
        }
      }
    ]
  end

  defp part(%ContentBlock.Unknown{value: value}) when is_map(value),
    do: [Options.stringify_keys(value)]

  defp part(%{} = block), do: map_part(block)
  defp part(text) when is_binary(text), do: [%{"text" => text}]
  defp part(_other), do: []

  defp map_part(block) do
    BeamWeaver.MapShape.assert_atom_keys!(block)

    case ChatCompletionsWire.provider_type(Map.get(block, :type)) do
      # Gemini can sign the last text part of a reply; the signature goes
      # back on the same part.
      "text" ->
        [
          %{"text" => Map.get(block, :text) || Map.get(block, :content) || ""}
          |> put_thought_signature(thought_signature(block))
        ]

      type when type in ["image", "audio", "video"] ->
        media_part(
          Map.get(block, :url),
          Map.get(block, :data) || Map.get(block, :base64),
          Map.get(block, :mime_type) || @default_mime_types[type]
        )

      "file" ->
        media_part(
          Map.get(block, :file_id) || Map.get(block, :url),
          Map.get(block, :data) || Map.get(block, :base64),
          Map.get(block, :mime_type) || "application/octet-stream"
        )

      "tool_result" ->
        part(
          ContentBlock.tool_result(%{
            tool_call_id: Map.get(block, :tool_call_id) || Map.get(block, :id),
            content: Map.get(block, :content),
            metadata: block
          })
        )

      type when type in ["function_call", "tool_call", "tool_use"] ->
        function_call_part(block)

      _other ->
        [block |> Options.stringify_keys() |> Map.drop(["type"])]
    end
  end

  defp function_call_part(call) when is_map(call) do
    args = MapAccess.get(call, :args) || MapAccess.get(call, :arguments) || MapAccess.get(call, :input) || %{}
    function_call = %{"name" => MapAccess.get(call, :name) || "tool", "args" => normalize_function_call_args(args)}
    [put_thought_signature(%{"functionCall" => function_call}, thought_signature(call))]
  end

  defp normalize_function_call_args(args) when is_map(args), do: Options.stringify_keys(args)

  defp normalize_function_call_args(args) when is_binary(args) do
    case BeamWeaver.JSON.decode(args) do
      {:ok, decoded} when is_map(decoded) -> Options.stringify_keys(decoded)
      _error -> %{"input" => args}
    end
  end

  defp normalize_function_call_args(args), do: %{"input" => args}

  defp media_part(nil, data, mime_type) when is_binary(data) do
    [%{"inlineData" => %{"mimeType" => mime_type, "data" => data}}]
  end

  defp media_part(uri, _data, mime_type) when is_binary(uri) do
    [%{"fileData" => %{"mimeType" => mime_type, "fileUri" => uri}}]
  end

  defp media_part(_uri, _data, _mime_type), do: []

  defp message_tool_call_parts(content, %Message{} = message) do
    if ChatCompletionsWire.content_has_tool_call?(content), do: [], else: tool_call_parts(message)
  end

  # Invalid calls, whose arguments came back malformed, go back too, with the
  # arguments when they parse to an object: the agent answers each with an
  # error function response, which needs its call.
  defp tool_call_parts(%Message{tool_calls: calls} = message) when is_list(calls) do
    Enum.flat_map(calls ++ invalid_tool_calls(message), &function_call_part/1)
  end

  defp tool_call_parts(_message), do: []

  defp invalid_tool_calls(%Message{metadata: %{invalid_tool_calls: calls}}) when is_list(calls) do
    for call <- calls, is_map(call), is_binary(MapAccess.get(call, :name)) do
      args =
        case BeamWeaver.JSON.decode(MapAccess.get(call, :args) || "") do
          {:ok, %{} = args} -> args
          _other -> %{}
        end

      %{name: MapAccess.get(call, :name), args: args}
    end
  end

  defp invalid_tool_calls(_message), do: []

  defp tool_result_parts(%Message{role: :tool} = message) do
    {response, media_parts} = tool_response_with_media(message.content)

    function_response =
      %{
        "id" => message.tool_call_id || message.id,
        "name" => message.name || message.tool_call_id || message.id || "tool",
        "response" => response
      }
      |> Options.reject_nil_values()
      |> Options.put_optional("parts", media_parts)

    [
      %{
        "functionResponse" => function_response
      }
    ]
  end

  defp tool_result_parts(_message), do: []

  defp tool_response(content) when is_map(content), do: Options.stringify_keys(content)
  defp tool_response(content) when is_binary(content), do: %{"content" => content}
  defp tool_response(content), do: %{"content" => inspect(content)}

  # Gemini takes images and documents such as PDFs inline in a function
  # response's parts; the rest of the result goes in its `response`.
  defp tool_response_with_media(content) when is_list(content) do
    {media, ordinary} =
      Enum.split_with(content, fn
        %ContentBlock.Image{data: data} when is_binary(data) -> true
        %ContentBlock.File{data: data} when is_binary(data) -> true
        %{type: type, data: data} when type in [:image, :file] and is_binary(data) -> true
        _block -> false
      end)

    response =
      case ordinary do
        [] -> %{"content" => ""}
        [single] -> %{"content" => tool_response_block(single)}
        many -> %{"content" => Enum.map(many, &tool_response_block/1)}
      end

    media_parts =
      Enum.map(media, fn block ->
        %{
          "inlineData" => %{
            "mimeType" => Map.get(block, :mime_type) || default_tool_mime_type(block.type),
            "data" => Map.fetch!(block, :data)
          }
        }
      end)

    {response, media_parts}
  end

  defp tool_response_with_media(content), do: {tool_response(content), []}

  defp default_tool_mime_type(:image), do: "image/png"
  defp default_tool_mime_type(:file), do: "application/pdf"

  defp tool_response_block(%ContentBlock.Text{text: text}), do: text
  defp tool_response_block(%ContentBlock.PlainText{text: text}), do: text
  defp tool_response_block(%{type: type, text: text}) when type in [:text, :plain_text], do: text
  defp tool_response_block(value) when is_binary(value), do: value
  defp tool_response_block(value) when is_map(value), do: Options.stringify_keys(value)
  defp tool_response_block(value), do: inspect(value)

  defp empty_user_message?(%Message{role: :user, content: ""}), do: true
  defp empty_user_message?(_message), do: false

  defp first_candidate(%{"candidates" => [candidate | _rest]}) when is_map(candidate),
    do: candidate

  defp first_candidate(_response), do: %{}

  defp response_blocks(candidate) do
    candidate
    |> get_in(["content", "parts"])
    |> List.wrap()
    |> Enum.flat_map(&response_block/1)
  end

  defp response_block(%{"text" => text, "thought" => true} = part) when is_binary(text) do
    [
      %{
        type: :reasoning,
        reasoning: text,
        thought_signature: part["thoughtSignature"]
      }
      |> Options.reject_nil_values()
    ]
  end

  defp response_block(%{"text" => text} = part) when is_binary(text) do
    [
      %{
        type: :text,
        text: text,
        thought_signature: thought_signature(part)
      }
      |> Options.reject_nil_values()
    ]
  end

  defp response_block(%{"functionCall" => %{"name" => name} = raw_call} = part) do
    [
      %{
        type: :tool_call,
        id: raw_call["id"],
        name: name,
        args: raw_call["args"] || %{},
        thought_signature: thought_signature(part) || thought_signature(raw_call)
      }
      |> Options.reject_nil_values()
    ]
  end

  defp response_block(%{"inlineData" => data}) when is_map(data) do
    [
      %{
        type: media_type(data["mimeType"]),
        data: data["data"],
        mime_type: data["mimeType"]
      }
    ]
  end

  defp response_block(%{"executableCode" => code}),
    do: [%{type: :server_tool_call, name: "code_execution", args: code}]

  defp response_block(%{"codeExecutionResult" => result}),
    do: [%{type: :server_tool_result, content: result}]

  defp response_block(%{"toolCall" => raw_call}) when is_map(raw_call),
    do: [%{type: :server_tool_call, name: raw_call["name"], args: raw_call}]

  defp response_block(%{"toolResponse" => response}) when is_map(response),
    do: [%{type: :server_tool_result, content: response}]

  defp response_block(part) when is_map(part),
    do: [%{type: :unknown, provider_type: "google_part", value: part}]

  defp response_block(_part), do: []

  defp media_type("image/" <> _rest), do: :image
  defp media_type("audio/" <> _rest), do: :audio
  defp media_type("video/" <> _rest), do: :video
  defp media_type(_mime_type), do: :file

  # Gemini may omit ids, also for repeated calls to one function. A generated
  # id is unique, so each result stays addressable across the thread.
  defp tool_calls(blocks) do
    for %{type: :tool_call} = block <- blocks do
      id = block[:id] || "call_" <> ID.uuidv7()

      Messages.tool_call(
        id: id,
        provider_id: id,
        call_id: id,
        name: block[:name],
        thought_signature: block[:thought_signature],
        args: block.args
      )
    end
  end

  defp thought_signature(map) when is_map(map) do
    metadata = MapAccess.get(map, :metadata)

    MapAccess.get(map, :thought_signature) ||
      Map.get(map, "thoughtSignature") ||
      Map.get(map, :thoughtSignature) ||
      MapAccess.get(metadata, :thought_signature) ||
      MapAccess.get(metadata, :thoughtSignature)
  end

  defp thought_signature(_map), do: nil

  defp put_thought_signature(part, signature) when is_binary(signature) and signature != "" do
    Map.put(part, "thoughtSignature", signature)
  end

  defp put_thought_signature(part, _signature), do: part

  defp message_content(blocks) do
    blocks
    |> Enum.reject(&(&1.type in [:tool_call, :server_tool_call, :server_tool_result]))
    |> visible_message_content()
  end

  defp visible_message_content([%{type: :text, text: text}]) when is_binary(text), do: text
  defp visible_message_content([]), do: ""
  defp visible_message_content(blocks), do: blocks

  defp usage_metadata(nil), do: nil

  defp usage_metadata(usage) when is_map(usage) do
    input = usage["promptTokenCount"] || usage["prompt_token_count"] || 0
    thought = usage["thoughtsTokenCount"] || usage["thoughts_token_count"] || 0
    output = (usage["candidatesTokenCount"] || usage["candidates_token_count"] || 0) + thought
    total = usage["totalTokenCount"] || usage["total_token_count"] || input + output
    cache_read = usage["cachedContentTokenCount"] || usage["cached_content_token_count"] || 0

    tool_use_prompt =
      usage["toolUsePromptTokenCount"] || usage["tool_use_prompt_token_count"] || 0

    initial_input = usage["initialPromptTokenCount"]

    %{
      input_tokens: input,
      initial_input_tokens: initial_input,
      context_tokens: if(is_integer(initial_input), do: initial_input + output),
      output_tokens: output,
      total_tokens: total,
      input_token_details:
        token_details(%{
          cache_read: cache_read,
          prompt_tokens_details: usage["promptTokensDetails"] || usage["prompt_tokens_details"],
          cache_tokens_details: usage["cacheTokensDetails"] || usage["cache_tokens_details"],
          tool_use_prompt: tool_use_prompt,
          tool_use_prompt_tokens_details: usage["toolUsePromptTokensDetails"] || usage["tool_use_prompt_tokens_details"]
        }),
      output_token_details:
        token_details(%{
          reasoning: thought,
          candidates_tokens_details: usage["candidatesTokensDetails"] || usage["candidates_tokens_details"]
        }),
      service_tier: usage["serviceTier"] || usage["service_tier"]
    }
    |> BeamWeaver.MapShape.compact([nil, :empty_list, :empty_map])
  end

  defp token_details(details), do: Map.reject(details, fn {_key, value} -> value in [nil, 0, [], %{}] end)

  defp response_metadata(response, candidate) do
    header_metadata = response["_beamweaver_response_header_metadata"] || %{}

    %{
      model_provider: "google",
      provider: :google,
      id: response["responseId"] || response["id"],
      model: response["modelVersion"] || response["model"],
      model_name: response["modelVersion"] || response["model"],
      model_version: response["modelVersion"],
      model_status: response["modelStatus"],
      finish_reason: candidate["finishReason"],
      continuation_token: candidate["continuationToken"],
      finish_message: candidate["finishMessage"],
      safety_ratings: candidate["safetyRatings"],
      prompt_feedback: response["promptFeedback"],
      citations: candidate["citationMetadata"],
      citation_metadata: candidate["citationMetadata"],
      grounding_metadata: candidate["groundingMetadata"],
      provider_content: get_in(candidate, ["content", "parts"]),
      grounding_attributions: candidate["groundingAttributions"],
      url_context_metadata: candidate["urlContextMetadata"],
      avg_logprobs: candidate["avgLogprobs"],
      logprobs_result: candidate["logprobsResult"],
      candidate_token_count: candidate["tokenCount"],
      candidate_index: candidate["index"],
      usage: response["usageMetadata"],
      headers: header_metadata[:headers],
      service_tier: header_metadata[:service_tier]
    }
    |> Options.reject_nil_values()
  end
end
