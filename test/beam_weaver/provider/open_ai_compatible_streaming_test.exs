defmodule BeamWeaver.Provider.OpenAICompatibleStreamingTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Provider.OpenAICompatibleStreaming, as: Streaming
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Core.Error

  test "one reducer reconstructs reasoning, text, tools, finish reason, usage, and unknown deltas" do
    body = """
    data: {"id":"chatcmpl_1","model":"test-model","choices":[{"index":0,"delta":{"reasoning_content":"think "},"finish_reason":null}]}

    data: {"id":"chatcmpl_1","choices":[{"index":0,"delta":{"content":"do","tool_calls":[{"index":0,"id":"call_1","function":{"name":"lookup","arguments":"{\\"id\\":"}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl_1","choices":[{"index":0,"delta":{"content":"ne","tool_calls":[{"index":0,"function":{"arguments":"1}"}}],"provider_field":"kept"},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}

    data: [DONE]
    """

    assert Streaming.text_deltas(body) == ["do", "ne"]
    assert {:ok, message} = Streaming.stream_body_to_message(body, config())
    assert message.id == "chatcmpl_1"
    assert Message.text(message) == "done"
    assert message.status == "tool_calls"
    assert message.metadata.reasoning_content == "think "
    assert message.metadata.test_delta == %{"provider_field" => "kept"}
    assert message.usage_metadata == %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
    assert [%ToolCall{name: "lookup", args: %{"id" => 1}}] = message.tool_calls

    events = Streaming.typed_events(body, config())
    assert Enum.any?(events, &match?(%{event: %Events.Token{text: "do"}}, &1))
    assert Enum.any?(events, &match?(%{event: %Events.ToolCallChunk{}}, &1))
    assert Enum.any?(events, &match?(%{event: %Events.Done{usage: %{"total_tokens" => 5}}}, &1))
    assert Enum.all?(events, &(&1.metadata.provider == :test_provider))
  end

  test "a live stream ends with one Done that carries the usage sent after the finish reason" do
    usage = %{"prompt_tokens" => 2, "completion_tokens" => 1, "total_tokens" => 3}
    usage_chunk = %{"id" => "chatcmpl_1", "choices" => [], "usage" => usage}

    batches = [
      [%{"data" => %{"id" => "chatcmpl_1", "choices" => [%{"index" => 0, "delta" => %{"content" => "Hi"}}]}}],
      [%{"data" => %{"id" => "chatcmpl_1", "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]}}],
      [%{"data" => usage_chunk}]
    ]

    {typed, state} = Enum.flat_map_reduce(batches, nil, &Streaming.typed_events(&1, &2, config()))
    reply = &Streaming.events_to_message(&1, config(), [])
    assert {:ok, final} = Streaming.finish_typed_events(state, :test_provider, reply)

    assert [%Events.Token{}, %Events.MessageChunk{}, %Events.Message{message: message}, %Events.Done{} = done] =
             Enum.map(typed ++ final, & &1.event)

    assert message.usage_metadata == %{input_tokens: 2, output_tokens: 1, total_tokens: 3}
    assert done.usage == usage
    assert done.result == usage_chunk

    whole = batches |> Enum.concat() |> Streaming.typed_events(config())
    assert [%Events.Done{usage: ^usage}] = for(%{event: %Events.Done{} = done} <- whole, do: done)
    assert %{event: %Events.Done{}} = List.last(whole)
  end

  test "invalid collected streams return the configured provider error" do
    assert {:error, %Error{} = error} = Streaming.stream_body_to_message(:not_a_body, config())
    assert error.type == :invalid_response
    assert error.message == "Test provider stream body must be binary"
  end

  defp config do
    %{
      provider: :test_provider,
      provider_name: "Test provider",
      usage_metadata: fn %{"usage" => usage} ->
        %{
          input_tokens: usage["prompt_tokens"],
          output_tokens: usage["completion_tokens"],
          total_tokens: usage["total_tokens"]
        }
      end,
      stream_metadata: fn events, message, _opts ->
        id = Enum.find_value(events, &get_in(&1, ["data", "id"]))
        reasoning = message.metadata[:reasoning_content]

        %{provider: :test_provider, id: id, reasoning_content: reasoning}
      end,
      choice_usage: false,
      include_chunk_id: true,
      reasoning_index: 0,
      unknown_delta_key: :test_delta
    }
  end
end
