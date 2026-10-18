defmodule BeamWeaver.ZAI.Messages do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.ZAI, as: ZAIProfiles
  alias BeamWeaver.Models.UsageCost
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.Result
  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapShape
  alias BeamWeaver.Provider.ChatCompletionsWire

  # Media input follows the model's profile: GLM-5.3-Flash reads images, video
  # and PDFs, by URL or as base64 data, and files uploaded to Z.ai by their id;
  # the other models take text only. A `nil` profile allows media.
  @spec to_chat_messages([Message.t()], Profile.t() | nil) :: {:ok, [map()]} | {:error, Error.t()}
  def to_chat_messages(messages, profile) when is_list(messages) do
    messages
    |> ChatCompletionsWire.move_tool_media()
    |> Result.traverse(&to_chat_message(&1, profile))
  end

  def to_chat_messages(_messages, _profile) do
    {:error, Error.new(:invalid_messages, "Z.ai messages must be a list")}
  end

  @spec chat_response_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def chat_response_to_message(%{"error" => %{"message" => message} = error})
      when is_binary(message) do
    {:error, Error.new(:response_error, message, %{error: MessageParts.stringify_keys(error)})}
  end

  def chat_response_to_message(%{"choices" => [choice | _rest]} = response) do
    message = choice["message"] || %{}
    usage = usage_metadata(response)
    metadata = metadata(response, choice, usage)

    Message.new(:assistant, ChatCompletionsWire.response_content(message),
      id: response["id"],
      metadata: metadata,
      response_metadata: metadata,
      usage_metadata: usage,
      status: choice["finish_reason"],
      tool_calls: ChatCompletionsWire.tool_calls(message)
    )
  end

  def chat_response_to_message(_response) do
    {:error, Error.new(:invalid_response, "Z.ai chat-completions response is invalid")}
  end

  defp metadata(response, choice, usage) do
    message = choice["message"] || %{}
    header_metadata = response["_beamweaver_response_header_metadata"] || %{}
    decoded_headers = header_metadata[:headers] || %{}
    x_log_id = decoded_headers[:x_log_id]

    %{
      id: response["id"],
      request_id: response["request_id"] || response["id"] || header_metadata[:request_id],
      x_log_id: x_log_id,
      created: response["created"],
      object: response["object"],
      model: response["model"],
      model_name: response["model"],
      model_provider: "zai",
      provider: :zai,
      api: :chat_completions,
      usage: response["usage"],
      token_usage: response["usage"],
      finish_reason: choice["finish_reason"],
      reasoning_content: message["reasoning_content"],
      headers: header_metadata[:headers],
      transport: BeamWeaver.Provider.ResponseDecoder.transport_metadata(header_metadata),
      raw_provider_response: response,
      estimated_cost: usage && usage[:total_cost],
      cost_currency: "USD"
    }
    |> MessageParts.reject_nil_values()
  end

  @spec usage_metadata(map()) :: map() | nil
  def usage_metadata(%{"usage" => usage} = response) when is_map(usage) do
    input_tokens = usage["prompt_tokens"] || usage["input_tokens"] || 0
    output_tokens = usage["completion_tokens"] || usage["output_tokens"] || 0
    total_tokens = usage["total_tokens"] || input_tokens + output_tokens

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: total_tokens,
      input_token_details: input_token_details(usage),
      output_token_details: output_token_details(usage)
    }
    |> Map.merge(priced_usage(response, usage) || %{})
    |> BeamWeaver.MapShape.reject_nil_or_empty()
  end

  def usage_metadata(_response), do: nil

  defp to_chat_message(%Message{role: :tool} = message, _profile), do: ChatCompletionsWire.tool_message(message)

  defp to_chat_message(%Message{role: :assistant} = message, profile) do
    with {:ok, content} <- content_to_zai(message.content, %{profile: profile, skip_reasoning?: true}) do
      {:ok,
       %{
         "role" => "assistant",
         "content" => content
       }
       |> MapShape.put_optional("name", message.name)
       |> MapShape.put_optional("tool_calls", ChatCompletionsWire.assistant_tool_calls(message))
       |> MapShape.put_optional("reasoning_content", ChatCompletionsWire.assistant_reasoning_content(message))}
    end
  end

  defp to_chat_message(%Message{} = message, profile) when message.role in [:system, :user] do
    with {:ok, content} <- content_to_zai(message.content, %{profile: profile, skip_reasoning?: false}) do
      {:ok,
       %{
         "role" => Atom.to_string(message.role),
         "content" => content
       }
       |> MapShape.put_optional("name", message.name)}
    end
  end

  defp to_chat_message(_message, _profile),
    do: {:error, Error.new(:invalid_message, "expected a BeamWeaver message")}

  defp content_to_zai(content, _context) when is_binary(content), do: {:ok, content}

  defp content_to_zai(content, context) when is_list(content) do
    content
    |> BeamWeaver.MapShape.assert_atom_keys_in!()
    |> Result.traverse(&content_part(&1, context))
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

  defp content_to_zai(content, _context), do: {:ok, to_string(content)}

  defp content_part(%ContentBlock.Text{text: text}, _context),
    do: {:ok, %{"type" => "text", "text" => text}}

  defp content_part(%ContentBlock.PlainText{text: text}, _context),
    do: {:ok, %{"type" => "text", "text" => text}}

  defp content_part(%ContentBlock.Reasoning{}, %{skip_reasoning?: true}), do: {:ok, nil}

  defp content_part(%ContentBlock.Reasoning{reasoning: text}, _context),
    do: {:ok, %{"type" => "reasoning", "reasoning" => text}}

  defp content_part(%ContentBlock.Image{} = block, context),
    do: image_part(block.url, block.data, block.mime_type, context)

  defp content_part(%ContentBlock.Video{} = block, context),
    do: video_part(block.url, block.data, block.mime_type, context)

  defp content_part(%ContentBlock.File{} = block, context), do: file_part(block, context)

  defp content_part(%ContentBlock.Unknown{value: value}, _context) when is_map(value),
    do: {:ok, BeamWeaver.MapShape.stringify_keys(value)}

  defp content_part(%{__struct__: _module, type: type}, context), do: unsupported_content(type, context)

  defp content_part(%{} = block, context) do
    BeamWeaver.MapShape.assert_atom_keys!(block)

    case ChatCompletionsWire.provider_type(Map.get(block, :type)) do
      "text" ->
        {:ok, %{"type" => "text", "text" => Map.get(block, :text) || Map.get(block, :content) || ""}}

      "reasoning" ->
        if context.skip_reasoning?,
          do: {:ok, nil},
          else: {:ok, %{"type" => "reasoning", "reasoning" => Map.get(block, :reasoning) || Map.get(block, :text)}}

      "image" ->
        image_part(
          Map.get(block, :url),
          Map.get(block, :data) || Map.get(block, :base64),
          Map.get(block, :mime_type),
          context
        )

      "image_url" ->
        image_part(provider_url(block, :image_url), nil, nil, context)

      type when type in ["video", "video_url"] ->
        video_part(
          Map.get(block, :url) || provider_url(block, :video_url),
          Map.get(block, :data) || Map.get(block, :base64),
          Map.get(block, :mime_type),
          context
        )

      type when type in ["file", "file_url"] ->
        with {:ok, file} <- ContentBlock.from(block), do: content_part(file, context)

      type when type in ["audio", "audio_url", "input_audio"] ->
        unsupported_content(:audio, context)

      _other ->
        {:ok, BeamWeaver.MapShape.stringify_keys(block)}
    end
  end

  defp content_part(text, _context) when is_binary(text),
    do: {:ok, %{"type" => "text", "text" => text}}

  defp content_part(other, _context),
    do: {:ok, %{"type" => "text", "text" => to_string(other)}}

  # Images and video are a URL or base64 data, sent as a data URL.
  defp image_part(url, data, mime_type, context),
    do: media_part(:image, :image_inputs, "image_url", url, data, mime_type || "image/png", context)

  defp video_part(url, data, mime_type, context),
    do: media_part(:video, :video_inputs, "video_url", url, data, mime_type || "video/mp4", context)

  defp media_part(kind, feature, part, url, data, mime_type, context) do
    cond do
      not supports?(context, feature) -> unsupported_content(kind, context)
      is_binary(url) -> {:ok, %{"type" => part, part => %{"url" => url}}}
      is_binary(data) -> {:ok, %{"type" => part, part => %{"url" => MessageParts.data_url(mime_type, data)}}}
      true -> media_error(kind, "Z.ai #{kind} blocks need a url or base64 data", context)
    end
  end

  # Documents go in a `file` part: the id of a file uploaded with Z.ai's file
  # API, a URL, or base64 data.
  defp file_part(%ContentBlock.File{} = block, context) do
    cond do
      not supports?(context, :pdf_inputs) ->
        unsupported_content(:file, context)

      file = file_source(block) ->
        {:ok, %{"type" => "file", "file" => MapShape.put_optional(file, "filename", block.filename)}}

      true ->
        media_error(:file, "Z.ai file blocks need a file_id, a url or base64 data", context)
    end
  end

  defp file_source(%ContentBlock.File{file_id: id}) when is_binary(id), do: %{"file_id" => id}
  defp file_source(%ContentBlock.File{url: url}) when is_binary(url), do: %{"file_url" => url}

  defp file_source(%ContentBlock.File{data: data} = block) when is_binary(data),
    do: %{"file_data" => MessageParts.data_url(block.mime_type || "application/pdf", data)}

  defp file_source(%ContentBlock.File{}), do: nil

  defp provider_url(block, key) do
    case Map.get(block, key) do
      %{url: url} -> url
      %{"url" => url} -> url
      url when is_binary(url) -> url
      _other -> nil
    end
  end

  defp supports?(%{profile: nil}, _feature), do: true
  defp supports?(%{profile: profile}, feature), do: Map.get(profile, feature) == true

  defp unsupported_content(feature, %{profile: profile}) do
    model = profile && profile.id

    {:error,
     Error.new(:unsupported_feature, "Z.ai #{model || "model"} does not take #{feature} input", %{
       provider: :zai,
       model: model,
       feature: feature
     })}
  end

  defp media_error(feature, message, %{profile: profile}) do
    {:error,
     Error.new(:invalid_content_block, message, %{provider: :zai, model: profile && profile.id, feature: feature})}
  end

  defp cached_tokens(usage) do
    usage["cached_tokens"] ||
      get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
      get_in(usage, ["input_tokens_details", "cached_tokens"]) ||
      0
  end

  defp input_token_details(usage) do
    %{
      cache_read: positive(cached_tokens(usage))
    }
    |> BeamWeaver.MapShape.reject_nil_or_empty()
  end

  defp output_token_details(usage) do
    %{
      reasoning:
        positive(
          get_in(usage, ["output_tokens_details", "reasoning_tokens"]) ||
            get_in(usage, ["completion_tokens_details", "reasoning_tokens"])
        )
    }
    |> BeamWeaver.MapShape.reject_nil_or_empty()
  end

  defp positive(value) when is_number(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp priced_usage(%{"model" => model} = response, usage) when is_binary(model) do
    case ZAIProfiles.resolve(model) do
      {:ok, profile} ->
        profile
        |> UsageCost.calculate(usage, at: response_created_at(response))
        |> include_web_search_cost(response)

      {:error, _reason} ->
        nil
    end
  end

  defp priced_usage(_response, _usage), do: nil

  defp include_web_search_cost(%{total_cost: total_cost} = cost, %{"web_search" => [_ | _]}) do
    Map.put(cost, :total_cost, total_cost + 0.01)
  end

  defp include_web_search_cost(cost, _response), do: cost

  defp response_created_at(%{"created" => unix_seconds}) when is_integer(unix_seconds) do
    case DateTime.from_unix(unix_seconds) do
      {:ok, at} -> at
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp response_created_at(_response), do: DateTime.utc_now()
end
