defmodule BeamWeaver.Provider.ChatCompletionsWire do
  @moduledoc false

  # Chat Completions wire helpers shared by the OpenAI-compatible providers;
  # most also cover the `reasoning_content` extension (Moonshot/Kimi and
  # Z.ai/GLM).

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.OpenAI.MessageParts

  @doc false
  # `:auto`, `:none` and `:required` (or Anthropic's `:any`) pass through; a
  # bare tool name forces that function.
  def tool_choice(nil), do: nil
  def tool_choice(choice) when choice in [:auto, :none, :required, "auto", "none", "required"], do: to_string(choice)
  def tool_choice(choice) when choice in [:any, "any"], do: "required"

  def tool_choice(name) when is_binary(name) or (is_atom(name) and not is_boolean(name)),
    do: function_tool_choice(to_string(name))

  def tool_choice(%{} = choice) do
    case MessageParts.stringify_keys(choice) do
      %{"function" => %{"name" => _name}} = choice -> choice
      %{"type" => "function", "name" => name} -> function_tool_choice(name)
      %{"name" => name} = choice when not is_map_key(choice, "type") -> function_tool_choice(name)
      choice -> choice
    end
  end

  def tool_choice(choice), do: choice

  defp function_tool_choice(name), do: %{"type" => "function", "function" => %{"name" => name}}

  def put_stream_usage(body, model, opts) do
    if Keyword.get(opts, :stream, false) and Keyword.get(opts, :stream_usage, model.stream_usage),
      do: Map.put_new(body, "stream_options", %{"include_usage" => true}),
      else: body
  end

  # Invalid calls, whose arguments came back malformed, go back too: the agent
  # answers each with an error tool message, which needs its call.
  def assistant_tool_calls(%Message{} = message) do
    case (message.tool_calls || []) ++ invalid_tool_calls(message) do
      [] -> nil
      calls -> Enum.map(calls, &assistant_tool_call/1)
    end
  end

  defp invalid_tool_calls(%Message{metadata: %{invalid_tool_calls: calls}}) when is_list(calls), do: calls
  defp invalid_tool_calls(_message), do: []

  @tool_call_types [:function_call, "function_call", :tool_call, "tool_call", :tool_use, "tool_use"]

  def content_has_tool_call?(content) when is_list(content),
    do: Enum.any?(content, &match?(%{type: type} when type in @tool_call_types, &1))

  def content_has_tool_call?(_content), do: false

  def assistant_reasoning_content(%Message{} = message) do
    metadata_value(message.metadata, :reasoning_content) ||
      content_reasoning(message.content)
  end

  def response_content(message) do
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

  def tool_calls(%{"tool_calls" => tool_calls}) when is_list(tool_calls) do
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

  def tool_calls(_message), do: []

  def first_choice(%{"choices" => [choice | _rest]}) when is_map(choice), do: choice
  def first_choice(_data), do: nil

  def tool_message(%Message{} = message) do
    call_id = message.tool_call_id || message.id

    if is_binary(call_id) and call_id != "" do
      {:ok,
       %{
         "role" => "tool",
         "tool_call_id" => call_id,
         "content" => tool_content(message)
       }
       |> BeamWeaver.MapShape.put_optional("name", message.name)}
    else
      {:error, BeamWeaver.Core.Error.new(:invalid_tool_message, "tool messages require a tool_call_id or id")}
    end
  end

  defp tool_content(%Message{content: content} = message) when is_list(content) do
    if Enum.all?(content, &text_block?/1), do: Message.text(message), else: tool_output(content)
  end

  defp tool_content(%Message{content: content}), do: tool_output(content)

  defp text_block?(block),
    do: is_binary(block) or is_struct(block, ContentBlock.Text) or is_struct(block, ContentBlock.PlainText)

  @media_blocks [ContentBlock.Image, ContentBlock.File, ContentBlock.Audio, ContentBlock.Video]

  @doc false
  # A Chat Completions tool message takes text only. The images and files of
  # a run of tool results go in a user message right after the run, each
  # under a line naming its call, so every result still follows its call.
  def move_tool_media(messages) when is_list(messages) do
    {messages, media} =
      Enum.flat_map_reduce(messages, [], fn
        %Message{role: :tool} = message, media ->
          {message, attached} = split_tool_media(message)
          {[message], media ++ attached}

        message, media ->
          {media_message(media) ++ [message], []}
      end)

    messages ++ media_message(media)
  end

  defp split_tool_media(%Message{content: content} = message) when is_list(content) do
    case Enum.split_with(content, &media_block?/1) do
      {[], _content} ->
        {message, []}

      {media, rest} ->
        label = "Attached to the #{message.name || "tool"} result for #{message.tool_call_id || message.id}:"
        rest = if rest == [], do: [ContentBlock.text("The result is attached in the next message.")], else: rest
        {%{message | content: rest}, [ContentBlock.text(label) | media]}
    end
  end

  defp split_tool_media(message), do: {message, []}

  defp media_block?(%module{}), do: module in @media_blocks
  defp media_block?(_block), do: false

  defp media_message([]), do: []
  defp media_message(media), do: [Message.user(media)]

  def tool_output(content) when is_binary(content), do: content

  def tool_output(content) when is_map(content) or is_list(content) do
    case BeamWeaver.JSON.encode(content) do
      {:ok, json} -> json
      {:error, _error} -> inspect(content)
    end
  end

  def tool_output(content), do: to_string(content)

  def provider_type(type) when is_atom(type), do: Atom.to_string(type)

  def provider_type(type), do: type

  def metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

  def metadata_value(_metadata, _key), do: nil

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

  def content_reasoning(content) when is_list(content) do
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
    |> BeamWeaver.MapShape.empty_to_nil()
  end

  def content_reasoning(_content), do: nil

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

  defp encode_arguments(arguments) when is_binary(arguments), do: arguments

  defp encode_arguments(arguments), do: BeamWeaver.JSON.encode!(arguments || %{})

  def decode_arguments(arguments) when is_binary(arguments) do
    case BeamWeaver.JSON.decode(arguments) do
      {:ok, decoded} -> decoded
      {:error, _error} -> arguments
    end
  end

  def decode_arguments(arguments), do: arguments
end
