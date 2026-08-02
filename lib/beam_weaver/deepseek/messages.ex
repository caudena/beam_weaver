defmodule BeamWeaver.DeepSeek.Messages do
  @moduledoc """
  DeepSeek message translation and response normalization.

  DeepSeek uses OpenAI-compatible wire shapes, with additional handling for
  reasoning replay, prefix completion, provider metadata, and cache-aware cost.
  """

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.DeepSeek.Error
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

  @spec to_chat_messages([Message.t()]) :: {:ok, [map()]} | {:error, Error.t()}
  def to_chat_messages([]) do
    {:error,
     Error.new(:invalid_messages, "DeepSeek Chat Completions requires at least one message", %{
       provider: :deepseek,
       api: :chat_completions
     })}
  end

  def to_chat_messages(messages) when is_list(messages) do
    with :ok <- validate_text_messages(messages, :chat_completions),
         {:ok, wire_messages} <-
           messages
           |> Enum.map(&text_only_message/1)
           |> ChatCompletions.Messages.to_openai_messages()
           |> convert_error(),
         wire_messages <- decorate_chat_messages(wire_messages, messages),
         :ok <- validate_prefix_messages(wire_messages) do
      {:ok, wire_messages}
    end
  end

  def to_chat_messages(_messages) do
    {:error, Error.new(:invalid_messages, "DeepSeek messages must be a list")}
  end

  @spec validate_text_messages([Message.t()], :chat_completions | :responses) ::
          :ok | {:error, Error.t()}
  def validate_text_messages(messages, api) when is_list(messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case validate_text_message(message, api) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec chat_response_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def chat_response_to_message(response) when is_map(response) do
    response
    |> ChatCompletions.Messages.response_to_message()
    |> convert_error()
    |> put_provider_metadata(response, :chat_completions)
    |> put_reasoning_metadata(response)
    |> put_usage_cost(response)
  end

  def chat_response_to_message(_response) do
    {:error, Error.new(:invalid_response, "DeepSeek Chat Completions response is invalid")}
  end

  @spec responses_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def responses_to_message(response) when is_map(response) do
    response
    |> OpenAIMessages.response_to_message()
    |> convert_error()
    |> hydrate_responses_replay_blocks()
    |> put_provider_metadata(response, :responses)
    |> put_usage_cost(response)
  end

  def responses_to_message(_response) do
    {:error, Error.new(:invalid_response, "DeepSeek Responses response is invalid")}
  end

  @doc false
  @spec usage_metadata(map()) :: map() | nil
  def usage_metadata(%{"usage" => usage}) when is_map(usage) do
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

  def usage_metadata(_response), do: nil

  defp validate_text_message(%Message{content: content, role: role}, api) when is_list(content) do
    Enum.reduce_while(content, :ok, fn block, :ok ->
      case validate_content_block(block, role, api) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_text_message(%Message{content: content}, _api) when is_binary(content), do: :ok

  defp validate_text_message(%Message{}, _api) do
    {:error, Error.new(:invalid_message, "DeepSeek message content must be text")}
  end

  defp validate_text_message(_message, _api) do
    {:error, Error.new(:invalid_message, "expected a BeamWeaver message")}
  end

  defp validate_content_block(block, role, api) do
    type = content_type(block)
    allowed = if api == :responses, do: @responses_allowed_content_types, else: @chat_allowed_content_types

    cond do
      ContentBlock.data?(block) ->
        unsupported_media(content_feature(type), api)

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
         Error.new(:unsupported_feature, "DeepSeek supports text message content only", %{
           provider: :deepseek,
           api: api,
           feature: content_feature(type)
         })}
    end
  end

  defp unsupported_media(feature, api) do
    {:error,
     Error.new(:unsupported_feature, "DeepSeek does not support media message input", %{
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

  defp normalize_content_type(type) when is_atom(type), do: type

  defp normalize_content_type(type) when is_binary(type) do
    case type do
      "text" -> :text
      "plain_text" -> :plain_text
      "output_text" -> :output_text
      "reasoning" -> :reasoning
      "function_call" -> :function_call
      "tool_call" -> :tool_call
      "tool_use" -> :tool_use
      "web_search_call" -> :web_search_call
      "image" -> :image
      "image_url" -> :image
      "input_image" -> :image
      "audio" -> :audio
      "input_audio" -> :audio
      "file" -> :file
      "input_file" -> :file
      "video" -> :video
      _other -> :unknown
    end
  end

  defp normalize_content_type(_type), do: :unknown

  defp content_feature(nil), do: :unknown_content
  defp content_feature(type), do: type

  defp text_only_message(%Message{} = message), do: %{message | content: Message.text(message)}

  defp decorate_chat_messages(wire_messages, messages) do
    Enum.zip(wire_messages, messages)
    |> Enum.map(fn {wire, message} -> decorate_chat_message(wire, message) end)
  end

  defp decorate_chat_message(wire, %Message{role: :assistant} = message) do
    wire
    |> put_optional("reasoning_content", assistant_reasoning(message))
    |> put_optional("prefix", prefix?(message))
  end

  defp decorate_chat_message(wire, _message), do: wire

  defp assistant_reasoning(%Message{} = message) do
    metadata_value(message.metadata, :reasoning_content) ||
      metadata_value(message.response_metadata, :reasoning_content) ||
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
    |> case do
      "" -> nil
      reasoning -> reasoning
    end
  end

  defp reasoning_blocks(_content), do: nil

  defp prefix?(%Message{} = message) do
    metadata_value(message.metadata, :prefix) || metadata_value(message.response_metadata, :prefix)
  end

  defp validate_prefix_messages(messages) do
    prefix_indexes =
      messages
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%{"prefix" => true}, index} -> [index]
        _entry -> []
      end)

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

  defp put_provider_metadata({:ok, %Message{} = message}, response, api) do
    extras = %{
      model_provider: "deepseek",
      provider: :deepseek,
      api: api,
      model: response["model"],
      model_name: response["model"]
    }

    metadata = message.metadata |> Map.merge(extras) |> MessageParts.reject_nil_values()
    response_metadata = message.response_metadata |> Map.merge(extras) |> MessageParts.reject_nil_values()
    usage = merge_usage_details(message.usage_metadata, response)

    {:ok,
     %{
       message
       | metadata: metadata,
         response_metadata: response_metadata,
         usage_metadata: usage
     }}
  end

  defp put_provider_metadata(other, _response, _api), do: other

  defp put_reasoning_metadata({:ok, %Message{} = message}, response) do
    reasoning =
      get_in(response, ["choices", Access.at(0), "message", "reasoning_content"])

    metadata = put_optional(message.metadata, :reasoning_content, reasoning)
    response_metadata = put_optional(message.response_metadata, :reasoning_content, reasoning)
    content = prepend_reasoning_block(message.content, reasoning)

    {:ok,
     %{
       message
       | content: content,
         metadata: metadata,
         response_metadata: response_metadata
     }}
  end

  defp put_reasoning_metadata(other, _response), do: other

  defp hydrate_responses_replay_blocks({:ok, %Message{content: content} = message})
       when is_list(content) do
    content = Enum.map(content, &hydrate_responses_replay_block/1)
    {:ok, %{message | content: content}}
  end

  defp hydrate_responses_replay_blocks(other), do: other

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

  defp prepend_reasoning_block(content, reasoning) when is_binary(content) do
    [ContentBlock.reasoning(reasoning)] ++
      if(content == "", do: [], else: [ContentBlock.text(content)])
  end

  defp prepend_reasoning_block(content, reasoning) when is_list(content) do
    [ContentBlock.reasoning(reasoning) | content]
  end

  defp put_usage_cost({:ok, %Message{usage_metadata: usage} = message}, response)
       when is_map(usage) do
    with model when is_binary(model) <- response["model"],
         {:ok, profile} <- ProfileRegistry.fetch(:deepseek, model),
         cost when is_map(cost) <- UsageCost.calculate(profile, response["usage"] || usage) do
      usage = Map.merge(usage, cost)
      metadata = Map.merge(message.metadata, %{estimated_cost: cost.total_cost, cost_currency: "USD"})

      response_metadata =
        Map.merge(message.response_metadata, %{
          estimated_cost: cost.total_cost,
          cost_currency: "USD"
        })

      {:ok,
       %{
         message
         | usage_metadata: usage,
           metadata: metadata,
           response_metadata: response_metadata
       }}
    else
      _missing -> {:ok, message}
    end
  end

  defp put_usage_cost(other, _response), do: other

  defp merge_usage_details(nil, response), do: usage_metadata(response)

  defp merge_usage_details(usage, response) when is_map(usage) do
    case usage_metadata(response) do
      nil -> usage
      detailed -> Map.merge(usage, detailed)
    end
  end

  defp cached_input_tokens(usage) do
    get_in(usage, ["prompt_tokens_details", "cached_tokens"]) ||
      get_in(usage, ["input_tokens_details", "cached_tokens"]) || 0
  end

  defp metadata_value(metadata, key) when is_map(metadata),
    do: BeamWeaver.MapAccess.get(metadata, key)

  defp metadata_value(_metadata, _key), do: nil

  defp convert_error({:error, %BeamWeaver.OpenAI.Error{} = error}) do
    {:error, Error.new(error.type, error.message, error.details)}
  end

  defp convert_error(other), do: other

  defp put_optional(map, _key, value) when value in [nil, false, "", []], do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
