defmodule BeamWeaver.Provider.ChatCompletionsStreamReplyTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Response

  defmodule LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up an order by its id."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, _args, _opts), do: {:ok, "Order A-1001 shipped on Monday."}
  end

  # Answers each request with the next scripted SSE body and sends the
  # request's JSON to the test.
  defmodule ScriptedSSE do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:request, request.json})
      body = Agent.get_and_update(Keyword.fetch!(opts, :script), fn [next | rest] -> {next, rest} end)

      {:ok,
       Response.new(
         status: 200,
         headers: [
           {"content-type", "text/event-stream"},
           {"x-request-id", "req-1"},
           {"msh-request-id", "req-1"},
           {"x-log-id", "req-1"}
         ],
         body: body
       )}
    end
  end

  # Each provider keeps its own request-id header in the reply's metadata.
  for {provider, model, header} <- [{"moonshot", "kimi-k2.6", :msh_request_id}, {"zai", "glm-5.2", :x_log_id}] do
    test "#{provider}: a streaming agent sends the reply's reasoning back with the tool result" do
      tool_turn =
        sse([
          chunk("c1", %{"role" => "assistant", "reasoning_content" => "I should look "}),
          chunk("c1", %{"reasoning_content" => "the order up."}),
          chunk("c1", %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "lookup_order", "arguments" => ""}
              }
            ]
          }),
          chunk("c1", %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => ~s({"order_id":"A-1001"})}}]}),
          finish("c1", "tool_calls")
        ])

      answer_turn =
        sse([chunk("c2", %{"role" => "assistant", "content" => "It shipped on Monday."}), finish("c2", "stop")])

      {:ok, agent} =
        BeamWeaver.Agent.build(
          model: unquote("#{provider}:#{model}"),
          model_opts: [
            api_key: "k",
            stream: true,
            transport: ScriptedSSE,
            transport_opts: transport_opts([tool_turn, answer_turn])
          ],
          tools: [LookupOrder],
          name: "orders"
        )

      assert {:ok, %{messages: messages}} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is order A-1001?"]})

      assert_received {:request, _first}
      assert_received {:request, second}

      assert %{"reasoning_content" => "I should look the order up."} =
               Enum.find(second["messages"], &(&1["role"] == "assistant"))

      [tool_call_reply, answer] = Enum.filter(messages, &(&1.role == :assistant))
      assert [%ContentBlock.Reasoning{reasoning: "I should look the order up."}] = tool_call_reply.content
      assert tool_call_reply.usage_metadata.total_tokens == 12
      assert answer.usage_metadata.total_tokens == 12
      assert answer.response_metadata.model_provider == unquote(provider)
      assert answer.response_metadata.headers[unquote(header)] == "req-1"
    end

    test "#{provider}: a typed stream ends with the complete reply, then Done" do
      body =
        sse([
          chunk("c1", %{"role" => "assistant", "reasoning_content" => "think"}),
          chunk("c1", %{"content" => "ok"}),
          finish("c1", "stop")
        ])

      {:ok, model} =
        BeamWeaver.Models.init_chat_model(unquote("#{provider}:#{model}"),
          api_key: "k",
          transport: ScriptedSSE,
          transport_opts: transport_opts([body])
        )

      assert {:ok, stream} = ChatModel.stream_typed_events(model, [Message.user("hi")])

      assert [%Events.Message{message: reply}, %Events.Done{}] =
               for(%{event: %type{} = event} <- Enum.to_list(stream), type in [Events.Message, Events.Done], do: event)

      assert Message.text(reply) == "ok"
      assert reply.metadata.reasoning_content == "think"
      assert reply.usage_metadata.total_tokens == 12
      assert reply.status == "stop"
    end
  end

  test "xai chat completions: a typed stream ends with the reply decoded like an invoked one" do
    body =
      sse([
        chunk("x1", %{"role" => "assistant", "reasoning_content" => "think "}),
        chunk("x1", %{"reasoning_content" => "more"}),
        chunk("x1", %{"content" => "Hi"}),
        %{
          "id" => "x1",
          "model" => "grok-3-mini",
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
          "citations" => ["https://docs.x.ai"]
        },
        %{
          "id" => "x1",
          "model" => "grok-3-mini",
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 3,
            "completion_tokens" => 2,
            "total_tokens" => 15,
            "completion_tokens_details" => %{"reasoning_tokens" => 10}
          }
        }
      ])

    {:ok, model} =
      BeamWeaver.Models.init_chat_model("xai:grok-3-mini",
        api: :chat_completions,
        api_key: "k",
        transport: ScriptedSSE,
        transport_opts: transport_opts([body])
      )

    assert {:ok, stream} = ChatModel.stream_typed_events(model, [Message.user("hi")])
    events = for %{event: %type{} = event} <- Enum.to_list(stream), type in [Events.Message, Events.Done], do: event
    assert [%Events.Message{message: reply}, %Events.Done{}, %Events.Done{usage: %{"total_tokens" => 15}}] = events

    assert reply.content == "Hi"
    assert reply.id == "x1"
    assert reply.metadata.reasoning_content == "think more"
    assert reply.metadata.citations == ["https://docs.x.ai"]
    assert reply.response_metadata.model_provider == "xai"
    assert reply.response_metadata.api == :chat_completions
    assert reply.response_metadata.request_id == "req-1"

    assert reply.usage_metadata == %{
             input_tokens: 3,
             output_tokens: 12,
             total_tokens: 15,
             output_token_details: %{reasoning: 10}
           }
  end

  test "xai chat completions: a streaming agent keeps the reply's usage and metadata" do
    body =
      sse([
        %{
          "id" => "x1",
          "model" => "grok-4.3",
          "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => "Hi"}}]
        },
        %{
          "id" => "x1",
          "model" => "grok-4.3",
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
        },
        %{
          "id" => "x1",
          "model" => "grok-4.3",
          "choices" => [],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7}
        }
      ])

    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: "xai:grok-4.3",
        model_opts: [
          api: :chat_completions,
          api_key: "k",
          stream: true,
          transport: ScriptedSSE,
          transport_opts: transport_opts([body])
        ],
        name: "a"
      )

    assert {:ok, %{messages: messages}} = BeamWeaver.Agent.invoke(agent, %{messages: ["hello"]})
    reply = List.last(messages)
    assert Message.text(reply) == "Hi"
    assert reply.usage_metadata.total_tokens == 7
    assert reply.response_metadata.model_provider == "xai"
  end

  test "openai chat completions: a typed stream ends with the reply decoded like an invoked one" do
    events = [
      %{
        "id" => "chatcmpl_1",
        "model" => "gpt-4.1",
        "system_fingerprint" => "fp_1",
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => "Checking."}}]
      },
      %{
        "id" => "chatcmpl_1",
        "model" => "gpt-4.1",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "lookup_order", "arguments" => ~s({"order_id":)}
                }
              ]
            }
          }
        ]
      },
      %{
        "id" => "chatcmpl_1",
        "model" => "gpt-4.1",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => ~s("A-1001"})}}]}
          }
        ]
      },
      %{
        "id" => "chatcmpl_1",
        "model" => "gpt-4.1",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]
      },
      %{
        "id" => "chatcmpl_1",
        "model" => "gpt-4.1",
        "choices" => [],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7}
      }
    ]

    invoked =
      Map.merge(List.first(events), %{
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "content" => "Checking.",
              "tool_calls" => [
                %{
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "lookup_order", "arguments" => ~s({"order_id":"A-1001"})}
                }
              ]
            }
          }
        ],
        "usage" => List.last(events)["usage"]
      })

    {:ok, model} =
      BeamWeaver.Models.init_chat_model("openai:gpt-4.1",
        api: :chat_completions,
        api_key: "k",
        transport: ScriptedSSE,
        transport_opts: transport_opts([sse(events), BeamWeaver.JSON.encode!(invoked)])
      )

    assert {:ok, stream} = ChatModel.stream_typed_events(model, [Message.user("Where is order A-1001?")])
    events = for %{event: %type{} = event} <- Enum.to_list(stream), type in [Events.Message, Events.Done], do: event
    assert [%Events.Message{message: reply}, %Events.Done{}, %Events.Done{usage: %{"total_tokens" => 7}}] = events

    assert {:ok, expected} = model.__struct__.invoke(model, [Message.user("Where is order A-1001?")])
    assert reply.content == "Checking."
    assert reply.tool_calls == expected.tool_calls
    assert [%{id: "call_1", name: "lookup_order", args: %{"order_id" => "A-1001"}}] = reply.tool_calls
    assert reply.usage_metadata == expected.usage_metadata
    assert reply.usage_metadata == %{input_tokens: 5, output_tokens: 2, total_tokens: 7}
    assert reply.status == "tool_calls"
    assert reply.id == "chatcmpl_1"

    for key <- [:model_provider, :id, :model, :system_fingerprint, :finish_reason, :token_usage, :request_id] do
      assert Map.fetch!(reply.response_metadata, key) == Map.fetch!(expected.response_metadata, key)
    end
  end

  test "openai chat completions: a streaming agent keeps the reply's usage and metadata" do
    body =
      sse([
        %{"id" => "c1", "model" => "gpt-4.1", "choices" => [%{"index" => 0, "delta" => %{"content" => "Hi"}}]},
        %{
          "id" => "c1",
          "model" => "gpt-4.1",
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
        },
        %{
          "id" => "c1",
          "model" => "gpt-4.1",
          "choices" => [],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2, "total_tokens" => 7}
        }
      ])

    {:ok, agent} =
      BeamWeaver.Agent.build(
        model: "openai:gpt-4.1",
        model_opts: [
          api: :chat_completions,
          api_key: "k",
          stream: true,
          transport: ScriptedSSE,
          transport_opts: transport_opts([body])
        ],
        name: "a"
      )

    assert {:ok, %{messages: messages}} = BeamWeaver.Agent.invoke(agent, %{messages: ["hello"]})
    reply = List.last(messages)
    assert Message.text(reply) == "Hi"
    assert reply.id == "c1"
    assert reply.usage_metadata.total_tokens == 7
    assert reply.response_metadata.model_provider == "openai"
    assert reply.response_metadata.model_name == "gpt-4.1"
    assert reply.response_metadata.request_id == "req-1"
  end

  defp transport_opts(bodies) do
    {:ok, script} = Agent.start_link(fn -> bodies end)
    [parent: self(), script: script]
  end

  defp chunk(id, delta), do: %{"id" => id, "model" => "m", "choices" => [%{"index" => 0, "delta" => delta}]}

  defp finish(id, reason) do
    %{
      "id" => id,
      "model" => "m",
      "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => reason}],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7, "total_tokens" => 12}
    }
  end

  defp sse(events), do: Enum.map_join(events, &"data: #{BeamWeaver.JSON.encode!(&1)}\n\n") <> "data: [DONE]\n\n"
end
