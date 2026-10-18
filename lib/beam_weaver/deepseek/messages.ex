defmodule BeamWeaver.DeepSeek.Messages do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Models.ProfileRegistry
  alias BeamWeaver.Models.UsageCost
  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.OpenAI.Messages, as: OpenAIMessages

  @chat_allowed_content_types [:text, :plain_text, :reasoning]
  @responses_allowed_content_types [
    :text,
    :plain_text,
    :output_text,
    :reasoning,
    :function_call,
    :tool_call,
    :tool_use,
    :web_search_call,
    :unknown
  ]

  @spec to_chat_messages([Message.t()], String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def to_chat_messages([], _model) do
    {:error,
     Error.new(:invalid_messages, "DeepSeek Chat Completions requires at least one message", %{
       provider: :deepseek,
       api: :chat_completions
     })}
  end

  def to_chat_messages(messages, model) when is_list(messages) do
    with :ok <- validate_messages(messages, :chat_completions, model),
         {:ok, wire_messages} <-
           messages
           |> Enum.map(&%{&1 | content: Message.text(&1)})
           |> ChatCompletions.Messages.to_openai_messages(),
         {:ok, wire_messages} <-
           wire_messages
           |> Enum.zip(messages)
           |> BeamWeaver.Result.traverse(fn {wire, message} -> decorate_chat_message(wire, message) end),
         :ok <- validate_prefix_messages(wire_messages) do
      {:ok, wire_messages}
    end
  end

  def to_chat_messages(_messages, _model) do
    {:error, Error.new(:invalid_messages, "DeepSeek messages must be a list")}
  end

  def validate_messages(messages, api, model) when is_list(messages),
    do: Enum.find_value(messages, :ok, fn message -> with :ok <- validate_message(message, api, model), do: nil end)

  @spec chat_response_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def chat_response_to_message(response) when is_map(response) do
    with {:ok, message} <- ChatCompletions.Messages.response_to_message(response) do
      {:ok,
       message
       |> put_provider_metadata(response, :chat_completions)
       |> put_reasoning_metadata(response)
       |> put_usage_cost(response)}
    end
  end

  def chat_response_to_message(_response) do
    {:error, Error.new(:invalid_response, "DeepSeek Chat Completions response is invalid")}
  end

  @spec responses_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def responses_to_message(response) when is_map(response) do
    with {:ok, message} <- OpenAIMessages.response_to_message(response) do
      {:ok,
       message
       |> hydrate_responses_replay_blocks()
       |> put_provider_metadata(response, :responses)
       |> put_usage_cost(response)}
    end
  end

  def responses_to_message(_response) do
    {:error, Error.new(:invalid_response, "DeepSeek Responses response is invalid")}
  end

  @spec usage_metadata(map()) :: map() | nil
  defp usage_metadata(%{"usage" => usage}) when is_map(usage) do
    input_tokens = usage["prompt_tokens"] || usage["input_tokens"] || 0
    output_tokens = usage["completion_tokens"] || usage["output_tokens"] || 0
    cache_hit = usage["prompt_cache_hit_tokens"] || cached_input_tokens(usage)
    cache_miss = usage["prompt_cache_miss_tokens"] || max(input_tokens - cache_hit, 0)
    reasoning_tokens = get_in(usage, ["completion_tokens_details", "reasoning_tokens"])
    reasoning_tokens = reasoning_tokens || get_in(usage, ["output_tokens_details", "reasoning_tokens"])

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: usage["total_tokens"] || input_tokens + output_tokens,
      input_token_details: %{
        cache_read: cache_hit,
        cache_miss: cache_miss
      },
      output_token_details: %{
        reasoning: reasoning_tokens
      }
    }
    |> BeamWeaver.MapShape.reject_nil_or_empty()
  end

  defp usage_metadata(_response), do: nil

  defp validate_message(%Message{content: content, role: role}, api, model) when is_list(content),
    do:
      Enum.find_value(content, :ok, fn block -> with :ok <- validate_content_block(block, role, api, model), do: nil end)

  defp validate_message(%Message{content: content}, _api, _model) when is_binary(content), do: :ok

  defp validate_message(%Message{}, _api, _model) do
    {:error, Error.new(:invalid_message, "DeepSeek message content must be text or content blocks")}
  end

  defp validate_message(_message, _api, _model) do
    {:error, Error.new(:invalid_message, "expected a BeamWeaver message")}
  end

  defp validate_content_block(block, role, api, model) do
    type = content_type(block)
    allowed = if api == :responses, do: @responses_allowed_content_types, else: @chat_allowed_content_types

    cond do
      type in [:image, :file] and BeamWeaver.Models.ProfileRegistry.DeepSeek.vision_model?(model) and
        (type == :image or api == :chat_completions) and role in [:user, :tool] ->
        :ok

      ContentBlock.data?(block) ->
        unsupported_media(type, api)

      type == :reasoning and role != :assistant ->
        {:error,
         Error.new(:invalid_message, "DeepSeek reasoning content is valid on assistant messages only", %{
           provider: :deepseek,
           api: api,
           role: role
         })}

      type in allowed ->
        :ok

      true ->
        {:error,
         Error.new(:unsupported_feature, "DeepSeek does not support this message content", %{
           provider: :deepseek,
           api: api,
           feature: type
         })}
    end
  end

  defp unsupported_media(feature, api) do
    {:error,
     Error.new(:unsupported_feature, "DeepSeek does not support this media input", %{
       provider: :deepseek,
       api: api,
       feature: feature
     })}
  end

  defp content_type(block) when is_binary(block), do: :text
  defp content_type(%ContentBlock.Text{}), do: :text
  defp content_type(%ContentBlock.PlainText{}), do: :plain_text
  defp content_type(%ContentBlock.Reasoning{}), do: :reasoning
  defp content_type(%ContentBlock.Image{}), do: :image
  defp content_type(%ContentBlock.Audio{}), do: :audio
  defp content_type(%ContentBlock.File{}), do: :file
  defp content_type(%ContentBlock.Video{}), do: :video
  defp content_type(%ContentBlock.Unknown{}), do: :unknown

  defp content_type(block) when is_map(block) do
    block
    |> BeamWeaver.MapAccess.get(:type)
    |> normalize_content_type()
  end

  defp content_type(_block), do: :unknown

  @content_types %{
    "text" => :text,
    "plain_text" => :plain_text,
    "output_text" => :output_text,
    "reasoning" => :reasoning,
    "function_call" => :function_call,
    "tool_call" => :tool_call,
    "tool_use" => :tool_use,
    "web_search_call" => :web_search_call,
    "image" => :image,
    "image_url" => :image,
    "input_image" => :image,
    "audio" => :audio,
    "input_audio" => :audio,
    "file" => :file,
    "input_file" => :file,
    "video" => :video
  }

  defp normalize_content_type(type) when is_atom(type), do: normalize_content_type(Atom.to_string(type))
  defp normalize_content_type(type) when is_binary(type), do: Map.get(@content_types, type, :unknown)
  defp normalize_content_type(_type), do: :unknown

  defp decorate_chat_message(wire, %Message{role: :assistant} = message) do
    {:ok,
     wire
     |> put_optional("reasoning_content", assistant_reasoning(message))
     |> put_optional("prefix", prefix?(message))}
  end

  defp decorate_chat_message(wire, %Message{content: content}) when is_list(content) do
    if Enum.any?(content, &(content_type(&1) in [:image, :file])) do
      with {:ok, [%{"content" => parts}]} <- OpenAIMessages.to_responses_input([Message.user(content)]) do
        {:ok, Map.put(wire, "content", Enum.map(parts, &chat_image_part/1))}
      end
    else
      {:ok, wire}
    end
  end

  defp decorate_chat_message(wire, _message), do: {:ok, wire}

  defp chat_image_part(%{"type" => "input_text", "text" => text}), do: %{"type" => "text", "text" => text}
  defp chat_image_part(%{"type" => "input_image", "file_id" => id}), do: %{"type" => "file", "file_id" => id}

  defp chat_image_part(%{"type" => "input_image"} = part) do
    %{"type" => "image_url", "image_url" => %{"url" => part["image_url"]} |> put_optional("detail", part["detail"])}
  end

  defp chat_image_part(%{"type" => "input_file"} = part), do: Map.put(part, "type", "file")
  defp chat_image_part(part), do: part

  defp assistant_reasoning(%Message{} = message) do
    MapAccess.get(message.metadata, :reasoning_content) ||
      MapAccess.get(message.response_metadata, :reasoning_content) ||
      reasoning_blocks(message.content)
  end

  defp reasoning_blocks(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %ContentBlock.Reasoning{reasoning: reasoning} when is_binary(reasoning) -> [reasoning]
      %{type: :reasoning, reasoning: reasoning} when is_binary(reasoning) -> [reasoning]
      %{type: :reasoning, text: reasoning} when is_binary(reasoning) -> [reasoning]
      _block -> []
    end)
    |> Enum.join("")
    |> BeamWeaver.MapShape.empty_to_nil()
  end

  defp reasoning_blocks(_content), do: nil

  defp prefix?(%Message{} = message) do
    MapAccess.get(message.metadata, :prefix) || MapAccess.get(message.response_metadata, :prefix)
  end

  defp validate_prefix_messages(messages) do
    prefix_indexes = for {%{"prefix" => true}, index} <- Enum.with_index(messages), do: index

    case prefix_indexes do
      [] ->
        :ok

      [index] when index == length(messages) - 1 ->
        :ok

      _indexes ->
        {:error,
         Error.new(:invalid_request, "DeepSeek prefix completion requires the final assistant message", %{
           provider: :deepseek,
           feature: :chat_prefix_completion,
           prefix_message_indexes: prefix_indexes
         })}
    end
  end

  defp put_provider_metadata(%Message{} = message, response, api) do
    extras = %{
      model_provider: "deepseek",
      provider: :deepseek,
      api: api,
      model: response["model"],
      model_name: response["model"]
    }

    %{
      message
      | metadata: message.metadata |> Map.merge(extras) |> MessageParts.reject_nil_values(),
        response_metadata: message.response_metadata |> Map.merge(extras) |> MessageParts.reject_nil_values(),
        usage_metadata: merge_usage_details(message.usage_metadata, response)
    }
  end

  defp put_reasoning_metadata(%Message{} = message, response) do
    reasoning = get_in(response, ["choices", Access.at(0), "message", "reasoning_content"])

    %{
      message
      | content: prepend_reasoning_block(message.content, reasoning),
        metadata: put_optional(message.metadata, :reasoning_content, reasoning),
        response_metadata: put_optional(message.response_metadata, :reasoning_content, reasoning)
    }
  end

  defp hydrate_responses_replay_blocks(%Message{content: content} = message) when is_list(content),
    do: %{message | content: Enum.map(content, &hydrate_responses_replay_block/1)}

  defp hydrate_responses_replay_blocks(message), do: message

  defp hydrate_responses_replay_block(%{
         raw_provider_block: %{"type" => type} = raw_provider_block
       })
       when type in ["custom_tool_call", "web_search_call"] do
    ContentBlock.unknown(type, raw_provider_block)
  end

  defp hydrate_responses_replay_block(block), do: block

  defp prepend_reasoning_block(content, reasoning)
       when not is_binary(reasoning) or reasoning == "",
       do: content

  defp prepend_reasoning_block("", reasoning), do: [ContentBlock.reasoning(reasoning)]

  defp prepend_reasoning_block(content, reasoning) when is_binary(content),
    do: [ContentBlock.reasoning(reasoning), ContentBlock.text(content)]

  defp prepend_reasoning_block(content, reasoning) when is_list(content) do
    [ContentBlock.reasoning(reasoning) | content]
  end

  defp put_usage_cost(%Message{usage_metadata: usage} = message, response) when is_map(usage) do
    with model when is_binary(model) <- response["model"],
         {:ok, profile} <- ProfileRegistry.fetch(:deepseek, model),
         cost when is_map(cost) <-
           UsageCost.calculate(profile, response["usage"] || usage, at: response_created_at(response)) do
      cost_metadata = %{estimated_cost: cost.total_cost, cost_currency: "USD"}

      %{
        message
        | usage_metadata: Map.merge(usage, cost),
          metadata: Map.merge(message.metadata, cost_metadata),
          response_metadata: Map.merge(message.response_metadata, cost_metadata)
      }
    else
      _missing -> message
    end
  end

  defp put_usage_cost(message, _response), do: message

  defp response_created_at(response) do
    case response["created_at"] || response["created"] do
      unix when is_integer(unix) -> DateTime.from_unix!(unix)
      unix when is_float(unix) -> unix |> trunc() |> DateTime.from_unix!()
      _other -> nil
    end
  end

  defp merge_usage_details(usage, response) do
    case usage_metadata(response) do
      nil -> usage
      detailed -> Map.merge(usage || %{}, detailed)
    end
  end

  defp cached_input_tokens(usage) do
    get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
      get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0
  end

  defp put_optional(map, _key, value) when value in [nil, false, "", []], do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
