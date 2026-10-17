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

  defp empty_to_nil(""), do: nil

  defp empty_to_nil(value), do: value
end
