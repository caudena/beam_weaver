defmodule BeamWeaver.Provider.TypedStreamTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Response

  # Answers every request with the same complete 200 event stream.
  defmodule SSE do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(_request, opts),
      do: {:ok, Response.new(status: 200, headers: [{"content-type", "text/event-stream"}], body: opts[:body])}
  end

  @providers [
    {"OpenAI Responses", "openai:gpt-4.1", [], :responses},
    {"OpenAI Chat Completions", "openai:gpt-4.1", [api: :chat_completions], :chat_completions},
    {"xAI Responses", "xai:grok-4.3", [], :responses},
    {"xAI Chat Completions", "xai:grok-4.3", [api: :chat_completions], :chat_completions},
    {"Anthropic", "anthropic:claude-haiku-4-5", [], :anthropic},
    {"Gemini", "google:gemini-2.5-flash", [], :gemini},
    {"Kimi", "moonshot:kimi-k2.6", [], :chat_completions},
    {"Z.ai", "zai:glm-5.2", [], :chat_completions},
    {"DeepSeek Chat Completions", "deepseek:deepseek-v4-flash", [], :chat_completions},
    {"DeepSeek Responses", "deepseek:deepseek-v4-flash", [api: :responses], :responses}
  ]

  for {provider, model, opts, format} <- @providers do
    describe provider do
      @describetag model: model, opts: opts, format: format

      test "the typed stream is the reply's events, without the events of the process that reads it", context do
        assert {:ok, events} = ChatModel.stream_typed_events(model(context), [Message.user("Where is A-1001?")])
        events = Enum.to_list(events)

        assert "It shipped." == for(%Envelope{event: %Events.Token{text: text}} <- events, into: "", do: text)
        assert [%Message{}] = for(%Envelope{event: %Events.Message{message: message}} <- events, do: message)
        assert debug_types(events) == []
      end

      test "an agent's stream has only the run's own producer events", context do
        {:ok, agent} =
          BeamWeaver.Agent.build(
            name: "orders",
            model: context.model,
            model_opts: [stream: true] ++ model_opts(context)
          )

        assert {:ok, events} = BeamWeaver.Agent.stream_events(agent, %{messages: ["Where is A-1001?"]}, live: true)
        events = Enum.to_list(events)

        assert debug_types(events) == [{:producer_start, nil}, {:producer_stop, nil}]
        assert %Envelope{event: %Events.Debug{payload: %{type: :producer_start}}} = List.first(events)
        assert %Envelope{event: %Events.Debug{payload: %{type: :producer_stop}}} = List.last(events)
      end
    end
  end

  defp debug_types(events),
    do: for(%Envelope{event: %Events.Debug{payload: %{type: type}}, node: node} <- events, do: {type, node})

  defp model(context), do: BeamWeaver.Models.init_chat_model!(context.model, model_opts(context))

  defp model_opts(context),
    do: [api_key: "k", transport: SSE, transport_opts: [body: reply(context.format)]] ++ context.opts

  defp reply(:chat_completions) do
    encode([
      %{
        "id" => "chatcmpl_1",
        "model" => "m",
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => "It shipped."}}]
      },
      %{
        "id" => "chatcmpl_1",
        "model" => "m",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
      }
    ]) <> "data: [DONE]\n\n"
  end

  defp reply(:responses) do
    item = %{"id" => "msg_1", "type" => "message", "role" => "assistant"}

    done =
      Map.merge(item, %{
        "status" => "completed",
        "content" => [%{"type" => "output_text", "text" => "It shipped.", "annotations" => []}]
      })

    response = %{"id" => "resp_1", "object" => "response", "model" => "m", "output" => []}

    encode([
      %{"type" => "response.created", "response" => Map.put(response, "status", "in_progress")},
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.merge(item, %{"status" => "in_progress", "content" => []})
      },
      %{
        "type" => "response.output_text.delta",
        "item_id" => "msg_1",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => "It shipped."
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => done},
      %{
        "type" => "response.completed",
        "response" =>
          Map.merge(response, %{
            "status" => "completed",
            "output" => [done],
            "usage" => %{"input_tokens" => 5, "output_tokens" => 3, "total_tokens" => 8}
          })
      }
    ])
  end

  defp reply(:anthropic) do
    message = %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5",
      "content" => [],
      "stop_reason" => nil,
      "usage" => %{"input_tokens" => 5, "output_tokens" => 1}
    }

    encode([
      %{"type" => "message_start", "message" => message},
      %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
      %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "It shipped."}},
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => 3}},
      %{"type" => "message_stop"}
    ])
  end

  defp reply(:gemini) do
    encode([
      %{
        "candidates" => [
          %{
            "index" => 0,
            "content" => %{"role" => "model", "parts" => [%{"text" => "It shipped."}]},
            "finishReason" => "STOP"
          }
        ],
        "usageMetadata" => %{"promptTokenCount" => 5, "candidatesTokenCount" => 3, "totalTokenCount" => 8},
        "modelVersion" => "gemini-2.5-flash"
      }
    ])
  end

  defp encode(events) do
    Enum.map_join(events, fn
      %{"type" => type} = data -> "event: #{type}\ndata: #{BeamWeaver.JSON.encode!(data)}\n\n"
      data -> "data: #{BeamWeaver.JSON.encode!(data)}\n\n"
    end)
  end
end
