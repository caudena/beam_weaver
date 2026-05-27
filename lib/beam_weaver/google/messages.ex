defmodule BeamWeaver.Google.Messages do
  @moduledoc """
  Google Gemini content translation.
  """

  @behaviour BeamWeaver.Provider.MessageTranslator

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Provider.Options

  @impl true
  def encode_message(%Message{} = message, opts \\ []) do
    with {:ok, {_system, [encoded]}} <- encode_messages([message], opts), do: {:ok, encoded}
  end

  @impl true
  def decode_message(payload, opts \\ []), do: response_to_message(payload, opts)

  @impl true
  def encode_messages(messages, opts \\ [])

  def encode_messages(messages, _opts) when is_list(messages) do
    {system_messages, content_messages} = Enum.split_with(messages, &(&1.role == :system))

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

    {:ok, {system, contents}}
  rescue
    exception -> {:error, Error.new(:invalid_message, Exception.message(exception))}
  end

  def encode_messages(_messages, _opts),
    do: {:error, Error.new(:invalid_message, "Google messages must be a list")}

  @spec response_to_message(map(), keyword()) :: {:ok, Message.t()} | {:error, Error.t()}
  def response_to_message(response, _opts \\ [])

  def response_to_message(%{"error" => %{"message" => message} = error}, _opts)
      when is_binary(message) do
    {:error, Error.new(:response_error, message, %{error: Options.stringify_keys(error)})}
  end

  def response_to_message(response, _opts) when is_map(response) do
    candidate = first_candidate(response)
    blocks = response_blocks(candidate)
    tool_calls = tool_calls(blocks)
    server_tool_calls = server_tool_calls(blocks)
    server_tool_results = server_tool_results(blocks)
    content = message_content(blocks)
    metadata = response_metadata(response, candidate)

    Message.new(:assistant, content,
      id: response["responseId"] || response["id"],
      metadata: metadata,
      response_metadata: metadata,
      usage_metadata: usage_metadata(response["usageMetadata"]),
      status: metadata[:finish_reason],
      server_tool_calls: server_tool_calls,
      server_tool_results: server_tool_results,
      tool_calls: tool_calls
    )
  end

  def response_to_message(_response, _opts),
    do: {:error, Error.new(:invalid_response, "Google response must be a JSON object")}

  defp content(%Message{role: role, content: message_content} = message) do
    %{
      "role" => provider_role(role),
      "parts" => parts(message_content) ++ tool_call_parts(message) ++ tool_result_parts(message)
    }
  end

  defp provider_role(:assistant), do: "model"
  defp provider_role(_role), do: "user"

  defp parts(content) when is_binary(content),
    do: if(content == "", do: [], else: [%{"text" => content}])

  defp parts(content) when is_list(content) do
    content
    |> assert_atom_content_blocks!()
    |> Enum.flat_map(&part/1)
  end

  defp parts(content), do: [%{"text" => to_string(content)}]

  defp part(%ContentBlock.Text{text: text}), do: [%{"text" => text}]
  defp part(%ContentBlock.PlainText{text: text}), do: [%{"text" => text}]

  defp part(%ContentBlock.Image{} = block),
    do: media_part(block.url, block.data, block.mime_type || "image/png")

  defp part(%ContentBlock.Audio{} = block),
    do: media_part(block.url, block.data, block.mime_type || "audio/mpeg")

  defp part(%ContentBlock.Video{} = block),
    do: media_part(block.url, block.data, block.mime_type || "video/mp4")

  defp part(%ContentBlock.File{} = block),
    do: media_part(block.file_id, block.data, block.mime_type || "application/octet-stream")

  defp part(%ContentBlock.Reasoning{reasoning: text}), do: [%{"thought" => true, "text" => text}]

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
    provider_block = Options.stringify_keys(block)

    case provider_type(Map.get(block, :type)) do
      "text" ->
        [%{"text" => Map.get(block, :text) || Map.get(block, :content) || ""}]

      "image" ->
        media_part(
          Map.get(block, :url),
          Map.get(block, :data) || Map.get(block, :base64),
          Map.get(block, :mime_type) || "image/png"
        )

      "audio" ->
        media_part(
          Map.get(block, :url),
          Map.get(block, :data) || Map.get(block, :base64),
          Map.get(block, :mime_type) || "audio/mpeg"
        )

      "video" ->
        media_part(
          Map.get(block, :url),
          Map.get(block, :data) || Map.get(block, :base64),
          Map.get(block, :mime_type) || "video/mp4"
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

      _other ->
        [Map.drop(provider_block, ["type"])]
    end
  end

  defp media_part(nil, data, mime_type) when is_binary(data) do
    [%{"inlineData" => %{"mimeType" => mime_type, "data" => data}}]
  end

  defp media_part(uri, _data, mime_type) when is_binary(uri) do
    [%{"fileData" => %{"mimeType" => mime_type, "fileUri" => uri}}]
  end

  defp media_part(_uri, _data, _mime_type), do: []

  defp tool_call_parts(%Message{tool_calls: calls}) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        "functionCall" => %{
          "name" => Map.get(call, :name),
          "args" => Map.get(call, :args, %{})
        }
      }
    end)
  end

  defp tool_call_parts(_message), do: []

  defp tool_result_parts(%Message{role: :tool} = message) do
    [
      %{
        "functionResponse" => %{
          "name" => message.name || message.tool_call_id || message.id || "tool",
          "response" => tool_response(message.content)
        }
      }
    ]
  end

  defp tool_result_parts(_message), do: []

  defp tool_response(content) when is_map(content), do: Options.stringify_keys(content)
  defp tool_response(content) when is_binary(content), do: %{"content" => content}
  defp tool_response(content), do: %{"content" => inspect(content)}

  defp empty_user_message?(%Message{role: :user, content: ""}), do: true
  defp empty_user_message?(_message), do: false

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
    [%{type: :reasoning, reasoning: text, signature: part["thoughtSignature"]}]
  end

  defp response_block(%{"text" => text}) when is_binary(text),
    do: [%{type: :text, text: text}]

  defp response_block(%{"functionCall" => %{"name" => name} = raw_call}) do
    [
      %{
        type: :tool_call,
        id: raw_call["id"] || "call_#{name}",
        name: name,
        args: raw_call["args"] || %{}
      }
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

  defp tool_calls(blocks) do
    blocks
    |> Enum.filter(&(Map.get(&1, :type) == :tool_call))
    |> Enum.map(fn block ->
      Messages.tool_call(
        id: block[:id],
        provider_id: block[:id],
        call_id: block[:id],
        name: block[:name],
        args: block[:args] || %{}
      )
    end)
  end

  defp server_tool_calls(blocks),
    do: Enum.filter(blocks, &(Map.get(&1, :type) == :server_tool_call))

  defp server_tool_results(blocks),
    do: Enum.filter(blocks, &(Map.get(&1, :type) == :server_tool_result))

  defp message_content([%{type: :text, text: text}]) when is_binary(text), do: text
  defp message_content([]), do: ""
  defp message_content(blocks), do: blocks

  defp usage_metadata(nil), do: nil

  defp usage_metadata(usage) when is_map(usage) do
    input = usage["promptTokenCount"] || usage["prompt_token_count"] || 0
    thought = usage["thoughtsTokenCount"] || usage["thoughts_token_count"] || 0
    output = (usage["candidatesTokenCount"] || usage["candidates_token_count"] || 0) + thought
    total = usage["totalTokenCount"] || usage["total_token_count"] || input + output
    cache_read = usage["cachedContentTokenCount"] || usage["cached_content_token_count"] || 0

    tool_use_prompt =
      usage["toolUsePromptTokenCount"] || usage["tool_use_prompt_token_count"] || 0

    %{
      input_tokens: input,
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
    |> reject_empty_details()
  end

  defp token_details(details) do
    details
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, 0} -> true
      {_key, []} -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp reject_empty_details(usage) do
    usage
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp response_metadata(response, candidate) do
    %{
      model_provider: "google",
      provider: :google,
      id: response["responseId"] || response["id"],
      model: response["modelVersion"] || response["model"],
      model_name: response["modelVersion"] || response["model"],
      model_version: response["modelVersion"],
      model_status: response["modelStatus"],
      finish_reason: candidate["finishReason"],
      finish_message: candidate["finishMessage"],
      safety_ratings: candidate["safetyRatings"],
      prompt_feedback: response["promptFeedback"],
      citations: candidate["citationMetadata"],
      citation_metadata: candidate["citationMetadata"],
      grounding_metadata: candidate["groundingMetadata"],
      grounding_attributions: candidate["groundingAttributions"],
      url_context_metadata: candidate["urlContextMetadata"],
      avg_logprobs: candidate["avgLogprobs"],
      logprobs_result: candidate["logprobsResult"],
      candidate_token_count: candidate["tokenCount"],
      candidate_index: candidate["index"],
      usage: response["usageMetadata"],
      headers: response["_beamweaver_response_headers"],
      raw_provider_response: response
    }
    |> Options.reject_nil_values()
  end
end
