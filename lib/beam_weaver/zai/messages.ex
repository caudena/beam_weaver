defmodule BeamWeaver.ZAI.Messages do
  @moduledoc """
  Z.ai Chat Completions message translation.
  """

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.Result
  alias BeamWeaver.ZAI.Error

  @input_price_per_mtok 1.40
  @cached_input_price_per_mtok 0.26
  @output_price_per_mtok 4.40

  @spec to_chat_messages([Message.t()]) :: {:ok, [map()]} | {:error, Error.t()}
  def to_chat_messages(messages) when is_list(messages) do
    Result.traverse(messages, &to_chat_message/1)
  end

  def to_chat_messages(_messages) do
    {:error, Error.new(:invalid_messages, "Z.ai messages must be a list")}
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
    {:error, Error.new(:invalid_response, "Z.ai chat-completions response is invalid")}
  end

  @spec metadata(map(), map()) :: map()
  def metadata(response, choice) do
    message = choice["message"] || %{}
    header_metadata = response["_beamweaver_response_header_metadata"] || %{}
    decoded_headers = header_metadata[:headers] || %{}
    x_log_id = decoded_headers[:x_log_id]
    usage = usage_metadata(response)

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
      transport: transport_metadata(header_metadata),
      raw_provider_response: response,
      estimated_cost: usage && usage[:total_cost],
      cost_currency: "USD"
    }
    |> MessageParts.reject_nil_values()
  end

  @spec usage_metadata(map()) :: map() | nil
  def usage_metadata(%{"usage" => usage}) when is_map(usage) do
    input_tokens = usage["prompt_tokens"] || usage["input_tokens"] || 0
    output_tokens = usage["completion_tokens"] || usage["output_tokens"] || 0
    total_tokens = usage["total_tokens"] || input_tokens + output_tokens
    cached_tokens = cached_tokens(usage)
    uncached_input_tokens = max(input_tokens - cached_tokens, 0)
    input_cost = mtok_cost(uncached_input_tokens, @input_price_per_mtok)
    cached_input_cost = mtok_cost(cached_tokens, @cached_input_price_per_mtok)
    output_cost = mtok_cost(output_tokens, @output_price_per_mtok)

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: total_tokens,
      input_cost: input_cost + cached_input_cost,
      output_cost: output_cost,
      total_cost: input_cost + cached_input_cost + output_cost,
      input_cost_details: %{
        uncached: input_cost,
        cache_read: cached_input_cost
      },
      output_cost_details: %{
        text: output_cost
      },
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
       |> put_optional("reasoning_content", assistant_reasoning_content(message))}
    end
  end

  defp to_chat_message(%Message{} = message) when message.role in [:system, :user] do
    with {:ok, content} <- content_to_zai(message.content) do
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

  defp content_to_zai(content) when is_binary(content), do: {:ok, content}
  defp content_to_zai(content) when is_list(content), do: content_to_parts(content)
  defp content_to_zai(content), do: {:ok, to_string(content)}

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

  defp content_part(%ContentBlock.Reasoning{}, true), do: {:ok, nil}

  defp content_part(%ContentBlock.Reasoning{reasoning: text}, _skip_reasoning?),
    do: {:ok, %{"type" => "reasoning", "reasoning" => text}}

  defp content_part(%ContentBlock.Image{}, _skip_reasoning?), do: unsupported_content(:image)
  defp content_part(%ContentBlock.Video{}, _skip_reasoning?), do: unsupported_content(:video)

  defp content_part(%ContentBlock.Unknown{value: value}, _skip_reasoning?) when is_map(value),
    do: {:ok, BeamWeaver.MapShape.stringify_keys(value)}

  defp content_part(%{} = block, skip_reasoning?) do
    BeamWeaver.MapShape.assert_atom_keys!(block)

    case provider_type(Map.get(block, :type)) do
      "text" ->
        {:ok, %{"type" => "text", "text" => Map.get(block, :text) || Map.get(block, :content) || ""}}

      "reasoning" when skip_reasoning? ->
        {:ok, nil}

      "reasoning" ->
        {:ok, %{"type" => "reasoning", "reasoning" => Map.get(block, :reasoning) || Map.get(block, :text)}}

      "image" ->
        unsupported_content(:image)

      "image_url" ->
        unsupported_content(:image_url)

      "video" ->
        unsupported_content(:video)

      "video_url" ->
        unsupported_content(:video_url)

      _other ->
        {:ok, BeamWeaver.MapShape.stringify_keys(block)}
    end
  end

  defp content_part(text, _skip_reasoning?) when is_binary(text),
    do: {:ok, %{"type" => "text", "text" => text}}

  defp content_part(other, _skip_reasoning?),
    do: {:ok, %{"type" => "text", "text" => to_string(other)}}

  defp unsupported_content(feature) do
    {:error,
     Error.new(:unsupported_feature, "Z.ai GLM-5.2 adapter currently supports text input only", %{
       provider: :zai,
       feature: feature
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

  defp mtok_cost(tokens, price_per_mtok) when is_number(tokens) do
    tokens * price_per_mtok / 1_000_000
  end

  defp mtok_cost(_tokens, _price_per_mtok), do: 0

  defp positive(value) when is_number(value) and value > 0, do: value
  defp positive(_value), do: nil

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

  defp transport_metadata(%{request_id: request_id}) when is_binary(request_id) and request_id != "" do
    %{request_id: request_id}
  end

  defp transport_metadata(_metadata), do: nil

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

  defp metadata_value(_metadata, _key), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, []), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
