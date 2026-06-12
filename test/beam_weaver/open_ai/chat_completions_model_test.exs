defmodule BeamWeaver.OpenAI.ChatCompletionsModelTest do
  use ExUnit.Case

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.ChatCompletionsModel
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  test "builds Chat Completions requests with tools, structured output, multimodal options, and escape hatches" do
    # Upstream reference:
    schema = %{type: "object", properties: %{answer: %{type: "string"}}, required: [:answer]}
    tool = weather_tool()

    assert {:ok, model} =
             Models.init_chat_model("openai:gpt-5.4-mini",
               api: :chat_completions,
               temperature: 0.2,
               reasoning_effort: :none,
               max_completion_tokens: 42,
               parallel_tool_calls: true,
               metadata: %{trace_id: "chat-1"}
             )

    assert {:ok, body} =
             ChatCompletionsModel.request_body(
               model,
               [
                 Message.system("be terse", metadata: %{openai_role: "developer"}),
                 Message.user([
                   %{type: :text, text: "weather?"},
                   %{type: :image, url: "https://example.test/cloud.png"},
                   %{type: :audio, data: "AAAA", format: "wav"},
                   %{
                     type: :file,
                     data: "PDF",
                     mime_type: "application/pdf",
                     filename: "report.pdf"
                   },
                   %{type: :file, file_id: "file_123"}
                 ])
               ],
               tools: [tool],
               tool_choice: :auto,
               response_format: %{name: "Answer", schema: schema},
               modalities: ["text", "audio"],
               audio: %{voice: "alloy", format: "wav"},
               prediction: %{type: "content", content: "sunny"},
               stream_options: %{include_usage: true},
               logit_bias: %{"123" => -1},
               prompt_cache_key: "cache-key",
               prompt_cache_retention: :in_memory,
               safety_identifier: "safe-user",
               verbosity: :low,
               web_search_options: %{search_context_size: :low},
               functions: [%{name: "legacy_lookup", parameters: %{type: :object}}],
               function_call: %{name: "legacy_lookup"},
               store: true,
               extra_body: %{vendor_extension: true}
             )

    assert body["model"] == "gpt-5.4-mini"
    assert body["stream"] == false
    assert body["temperature"] == 0.2
    assert body["reasoning_effort"] == "none"
    assert body["max_completion_tokens"] == 42
    assert body["parallel_tool_calls"] == true
    assert body["metadata"] == %{"trace_id" => "chat-1"}
    assert body["tool_choice"] == "auto"
    assert body["logit_bias"] == %{"123" => -1}
    assert body["prompt_cache_key"] == "cache-key"
    assert body["prompt_cache_retention"] == "in_memory"
    assert body["safety_identifier"] == "safe-user"
    assert body["verbosity"] == "low"
    assert body["web_search_options"] == %{"search_context_size" => "low"}

    assert body["functions"] == [
             %{"name" => "legacy_lookup", "parameters" => %{"type" => "object"}}
           ]

    assert body["function_call"] == %{"name" => "legacy_lookup"}
    assert body["vendor_extension"] == true

    assert [
             %{"role" => "developer", "content" => "be terse"},
             %{"role" => "user", "content" => content}
           ] = body["messages"]

    assert %{"type" => "text", "text" => "weather?"} in content

    assert %{"type" => "image_url", "image_url" => %{"url" => "https://example.test/cloud.png"}} in content

    assert %{"type" => "input_audio", "input_audio" => %{"data" => "AAAA", "format" => "wav"}} in content

    assert %{
             "type" => "file",
             "file" => %{
               "file_data" => "data:application/pdf;base64,PDF",
               "filename" => "report.pdf"
             }
           } in content

    assert %{"type" => "file", "file" => %{"file_id" => "file_123"}} in content

    assert [
             %{
               "type" => "function",
               "function" => %{
                 "name" => "get_weather",
                 "description" => "Get weather",
                 "parameters" => %{"required" => ["city"]}
               }
             }
           ] = body["tools"]

    assert body["response_format"] == %{
             "type" => "json_schema",
             "json_schema" => %{
               "name" => "Answer",
               "schema" => %{
                 "type" => "object",
                 "properties" => %{"answer" => %{"type" => "string"}},
                 "required" => ["answer"],
                 "additionalProperties" => false
               },
               "strict" => true
             }
           }
  end

  test "o-series Chat Completions requests coerce system role to developer" do
    # Upstream reference:
    assert {:ok, body} =
             ChatCompletionsModel.request_body(
               %ChatCompletionsModel{model: "o3-mini"},
               [
                 Message.system("system text"),
                 Message.system([%{type: :text, text: "system block"}]),
                 Message.user("hello")
               ]
             )

    assert body["messages"] == [
             %{"role" => "developer", "content" => "system text"},
             %{
               "role" => "developer",
               "content" => [%{"type" => "text", "text" => "system block"}]
             },
             %{"role" => "user", "content" => "hello"}
           ]
  end

  test "Chat Completions applies GPT-5 and o-series request policies" do
    for model <- ["GPT-5-NANO", "GPT-5-2025-01-01", "Gpt-5-Turbo", "gPt-5-mini"] do
      assert {:ok, restricted} =
               ChatCompletionsModel.request_body(
                 %ChatCompletionsModel{model: model, temperature: 0.5, max_tokens: 100},
                 [Message.user("hello")]
               )

      refute Map.has_key?(restricted, "temperature")
      refute Map.has_key?(restricted, "max_tokens")
      assert restricted["max_completion_tokens"] == 100
    end

    assert {:ok, allowed} =
             ChatCompletionsModel.request_body(
               %ChatCompletionsModel{
                 model: "gpt-5.5",
                 temperature: 0.5,
                 reasoning_effort: :none
               },
               [Message.user("hello")]
             )

    assert allowed["temperature"] == 0.5
    assert allowed["reasoning_effort"] == "none"

    assert {:ok, minimal_reasoning} =
             ChatCompletionsModel.request_body(
               %ChatCompletionsModel{
                 model: "gpt-5",
                 reasoning_effort: "minimal",
                 max_tokens: 100
               },
               [Message.user("hello")]
             )

    assert minimal_reasoning["reasoning_effort"] == "minimal"
    assert minimal_reasoning["max_completion_tokens"] == 100
    refute Map.has_key?(minimal_reasoning, "max_tokens")

    assert {:ok, deprecated_chat} =
             ChatCompletionsModel.request_body(
               %ChatCompletionsModel{model: "gpt-5-chat", temperature: 0.7},
               [Message.user("hello")]
             )

    refute Map.has_key?(deprecated_chat, "temperature")

    assert {:error, error} = Models.init_chat_model("openai:o1-mini", api: :chat_completions)
    assert error.type == :deprecated_model
    assert error.details.replacement == "gpt-5-mini"
  end

  test "invokes Chat Completions through replay and decodes message metadata, usage, and tool calls" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "messages" => [%{"role" => "user", "content" => "call the tool"}],
      "stream" => false,
      "tools" => [
        %{
          "type" => "function",
          "function" => %{
            "name" => "get_weather",
            "description" => "Get weather",
            "parameters" => %{"required" => ["city"]}
          }
        }
      ]
    }

    response_body = %{
      "id" => "chatcmpl_replay",
      "model" => "gpt-5.4-mini",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{
                "id" => "call_weather",
                "type" => "function",
                "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Paris"})}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 3, "total_tokens" => 10}
    }

    model = replay_model(write_gzip_cassette(request_body, response_body))

    assert {:ok, response} =
             CoreChatModel.invoke(model, [Message.user("call the tool")], tools: [weather_tool()])

    assert response.id == "chatcmpl_replay"
    assert response.status == "tool_calls"
    assert response.usage_metadata == %{input_tokens: 7, output_tokens: 3, total_tokens: 10}

    assert [
             %ToolCall{
               id: "call_weather",
               call_id: "call_weather",
               name: "get_weather",
               args: %{"city" => "Paris"}
             }
           ] = response.tool_calls
  end

  test "decodes Chat Completions refusal, audio, finish reason, and provider metadata" do
    response_body = %{
      "id" => "chatcmpl_meta",
      "model" => "gpt-5.4",
      "system_fingerprint" => "fp_123",
      "service_tier" => "default",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{"type" => "refusal", "refusal" => "I cannot help with that."},
              %{"type" => "text", "text" => "Safe alternative."}
            ],
            "audio" => %{"id" => "audio_1", "expires_at" => 1_725_000_000}
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 4, "total_tokens" => 7}
    }

    assert {:ok, message} = ChatCompletions.Messages.response_to_message(response_body)

    assert message.id == "chatcmpl_meta"
    assert message.status == "stop"

    assert message.content == [
             %{type: :refusal, refusal: "I cannot help with that."},
             %{type: :text, text: "Safe alternative."}
           ]

    assert message.response_metadata.system_fingerprint == "fp_123"
    assert message.response_metadata.service_tier == "default"
    assert message.response_metadata.finish_reason == "stop"

    assert message.response_metadata.audio == %{
             "id" => "audio_1",
             "expires_at" => 1_725_000_000
           }

    assert message.usage_metadata == %{input_tokens: 3, output_tokens: 4, total_tokens: 7}
  end

  test "decodes Chat Completions message-level refusal payloads" do
    # Upstream reference:
    response_body = %{
      "id" => "chatcmpl_refusal",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "refusal" => "I cannot comply."
          },
          "finish_reason" => "stop"
        }
      ]
    }

    assert {:ok, message} = ChatCompletions.Messages.response_to_message(response_body)
    assert message.content == [%{type: :refusal, refusal: "I cannot comply."}]
    assert message.response_metadata.finish_reason == "stop"
  end

  test "maps Chat Completions usage token details without dropping explicit zero totals" do
    response_body = %{
      "id" => "chatcmpl_usage",
      "choices" => [%{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}],
      "usage" => %{
        "prompt_tokens" => 10,
        "prompt_tokens_details" => %{"cached_tokens" => 4, "flex" => 10},
        "completion_tokens" => 5,
        "completion_tokens_details" => %{
          "reasoning_tokens" => 2,
          "accepted_prediction_tokens" => 3,
          "rejected_prediction_tokens" => 1,
          "flex" => 3,
          "flex_reasoning" => 2
        },
        "total_tokens" => 0
      }
    }

    assert {:ok, message} = ChatCompletions.Messages.response_to_message(response_body)

    assert message.usage_metadata == %{
             input_tokens: 10,
             output_tokens: 5,
             total_tokens: 0,
             input_token_details: %{cache_read: 4, flex: 10},
             output_token_details: %{
               reasoning: 2,
               accepted_prediction: 3,
               rejected_prediction: 1,
               flex: 3,
               flex_reasoning: 2
             }
           }
  end

  test "decodes Chat Completions metadata aliases, logprobs, and prediction token details" do
    usage = %{
      "prompt_tokens" => 4,
      "completion_tokens" => 6,
      "completion_tokens_details" => %{
        "accepted_prediction_tokens" => 2,
        "rejected_prediction_tokens" => 1
      },
      "total_tokens" => 10
    }

    assert {:ok, message} =
             ChatCompletions.Messages.response_to_message(%{
               "id" => "chatcmpl_prediction",
               "model" => "gpt-4.1-nano",
               "system_fingerprint" => "fp_prediction",
               "service_tier" => "default",
               "choices" => [
                 %{
                   "message" => %{"content" => "ok"},
                   "finish_reason" => "stop",
                   "logprobs" => %{"content" => [%{"token" => "ok"}]}
                 }
               ],
               "usage" => usage
             })

    assert message.response_metadata.model_name == "gpt-4.1-nano"
    assert message.response_metadata.token_usage == usage
    assert message.response_metadata.logprobs == %{"content" => [%{"token" => "ok"}]}
    assert message.response_metadata.system_fingerprint == "fp_prediction"
    assert message.response_metadata.service_tier == "default"
    assert message.response_metadata.finish_reason == "stop"

    assert message.usage_metadata.output_token_details == %{
             accepted_prediction: 2,
             rejected_prediction: 1
           }
  end

  test "streamed Chat Completions metadata preserves logprobs and raw token usage" do
    body = """
    data: {"id":"chatcmpl_meta_stream","model":"gpt-4.1-mini","service_tier":"default","system_fingerprint":"fp_stream","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null,"logprobs":{"content":[{"token":"hi"}]}}]}

    data: {"id":"chatcmpl_meta_stream","model":"gpt-4.1-mini","service_tier":"default","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5,"completion_tokens_details":{"accepted_prediction_tokens":1}}}

    data: [DONE]
    """

    assert {:ok, message} = ChatCompletions.Messages.stream_body_to_message(body)

    assert Message.text(message) == "hi"
    assert message.response_metadata.model_name == "gpt-4.1-mini"
    assert message.response_metadata.token_usage["completion_tokens"] == 2
    assert message.response_metadata.logprobs == %{"content" => [%{"token" => "hi"}]}
    assert message.response_metadata.system_fingerprint == "fp_stream"
    assert message.response_metadata.service_tier == "default"
    assert message.response_metadata.finish_reason == "stop"
    assert message.usage_metadata.output_token_details == %{accepted_prediction: 1}
  end

  test "stream response decoder reads atom-key message metadata" do
    body = """
    data: {"id":"chatcmpl_decoder_stream","model":"gpt-4.1-mini","service_tier":"default","system_fingerprint":"fp_decoder","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}

    data: {"id":"chatcmpl_decoder_stream","model":"gpt-4.1-mini","service_tier":"default","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}

    data: [DONE]
    """

    response = %BeamWeaver.Transport.Response{status: 200, body: body, headers: []}

    assert {:ok, decoded} =
             BeamWeaver.OpenAI.Client.ResponseDecoder.chat_completions_stream_response(
               {:ok, response},
               []
             )

    assert decoded["id"] == "chatcmpl_decoder_stream"
    assert decoded["model"] == "gpt-4.1-mini"
    assert decoded["system_fingerprint"] == "fp_decoder"
    assert decoded["service_tier"] == "default"
    assert decoded["usage"]["completion_tokens"] == 2
  end

  test "returns provider response errors for Chat Completions error payloads" do
    assert {:error, error} =
             ChatCompletions.Messages.response_to_message(%{
               "error" => %{"message" => "bad request", "type" => "invalid_request_error"}
             })

    assert error.type == :response_error
    assert error.message == "bad request"
    assert error.details.error["type"] == "invalid_request_error"
  end

  test "maps Chat Completions context-window errors across sync async and stream calls" do
    model = context_overflow_model()

    assert {:error, %BeamWeaver.OpenAI.Error{type: :context_overflow} = error} =
             CoreChatModel.invoke(model, [Message.user("test")])

    assert error.message =~ "Input tokens exceed the configured limit"
    assert error.details.code == "context_length_exceeded"

    assert {:error, %BeamWeaver.OpenAI.Error{type: :context_overflow}} =
             model
             |> ChatCompletionsModel.async_invoke([Message.user("test")])
             |> Async.await()

    assert {:ok, stream} =
             ChatCompletionsModel.stream(context_overflow_model(), [Message.user("test")])

    assert [
             %BeamWeaver.Stream.Events.Error{
               error: %BeamWeaver.OpenAI.Error{type: :context_overflow}
             }
           ] = Enum.to_list(stream)

    context_window =
      context_overflow_model("Your input exceeds the context window of this model.")

    assert {:error, %BeamWeaver.OpenAI.Error{type: :context_overflow} = stream_error} =
             ChatCompletionsModel.stream_response(context_window, [Message.user("test")])

    assert stream_error.message =~ "context window"
  end

  test "streams Chat Completions text and parallel tool-call chunks into one final assistant message" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "messages" => [%{"role" => "user", "content" => "stream tools"}],
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    }

    response_body = """
    data: {"id":"chatcmpl_stream","choices":[{"index":0,"delta":{"content":"checking "},"finish_reason":null}]}

    data: {"id":"chatcmpl_stream","choices":[{"index":0,"delta":{"content":"tools"},"finish_reason":null}]}

    data: {"id":"chatcmpl_stream","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_weather","function":{"name":"get_weather","arguments":"{\\"city\\""}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl_stream","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_time","function":{"name":"get_time","arguments":"{\\"zone\\""}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl_stream","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\"Paris\\"}"}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl_stream","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":":\\"UTC\\"}"}}]},"finish_reason":null}]}

    data: {"id":"chatcmpl_stream","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":6,"total_tokens":11}}

    data: [DONE]
    """

    model =
      replay_model(write_gzip_cassette(request_body, response_body, content_type: "text/event-stream"))

    assert {:ok, response} =
             ChatCompletionsModel.stream_response(model, [Message.user("stream tools")],
               stream_options: %{include_usage: true}
             )

    assert Message.text(response) == "checking tools"
    assert response.status == "tool_calls"
    assert response.usage_metadata == %{input_tokens: 5, output_tokens: 6, total_tokens: 11}

    assert [
             %ToolCall{
               id: "call_weather",
               name: "get_weather",
               args: %{"city" => "Paris"}
             },
             %ToolCall{id: "call_time", name: "get_time", args: %{"zone" => "UTC"}}
           ] = response.tool_calls
  end

  test "malformed streamed tool-call JSON becomes invalid tool-call metadata instead of crashing" do
    # Upstream reference:
    # - malformed streamed tool-call chunks are retained as invalid tool calls.
    body = """
    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_bad","function":{"name":"bad_tool","arguments":"{\\"broken\\""}}]},"finish_reason":null}]}

    data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

    data: [DONE]
    """

    assert {:ok, response} = ChatCompletions.Messages.stream_body_to_message(body)
    assert response.tool_calls == []

    assert [%InvalidToolCall{id: "call_bad", name: "bad_tool", args: invalid}] =
             response.metadata[:invalid_tool_calls]

    assert invalid == ~s({"broken")
  end

  test "event stream mode returns typed envelopes for tokens, chunks, tool-call chunks, and done" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "messages" => [%{"role" => "user", "content" => "events"}],
      "stream" => true
    }

    response_body = """
    data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}

    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"lookup","arguments":"{}"}}]},"finish_reason":null}]}

    data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

    data: [DONE]
    """

    model =
      replay_model(write_gzip_cassette(request_body, response_body, content_type: "text/event-stream"))

    assert {:ok, stream} = ChatCompletionsModel.stream_events(model, [Message.user("events")])

    events = Enum.to_list(stream)
    assert Enum.all?(events, &match?(%Envelope{}, &1))
    assert Enum.any?(events, &match?(%Envelope{event: %Events.Token{text: "hi"}}, &1))
    assert Enum.any?(events, &match?(%Envelope{event: %Events.ToolCallChunk{}}, &1))
    assert Enum.any?(events, &match?(%Envelope{event: %Events.MessageChunk{}}, &1))
    assert Enum.any?(events, &match?(%Envelope{event: %Events.Done{}}, &1))
  end

  test "event streams carry model metadata for telemetry and native tracing" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "messages" => [%{"role" => "user", "content" => "metadata"}],
      "stream" => true,
      "metadata" => %{"trace_id" => "meta-1"},
      "tool_choice" => "auto",
      "tools" => [
        %{
          "type" => "function",
          "function" => %{
            "name" => "get_weather",
            "description" => "Get weather",
            "parameters" => %{"required" => ["city"]}
          }
        }
      ]
    }

    response_body = """
    data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}

    data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5,"prompt_tokens_details":{"cached_tokens":1}}}
    """

    model =
      replay_model(write_gzip_cassette(request_body, response_body, content_type: "text/event-stream"))

    assert {:ok, stream} =
             ChatCompletionsModel.stream_events(model, [Message.user("metadata")],
               tools: [weather_tool()],
               tool_choice: :auto,
               metadata: %{trace_id: "meta-1"}
             )

    events = Enum.to_list(stream)

    assert %Envelope{metadata: metadata} =
             Enum.find(events, &(&1.metadata[:model_provider] == :openai))

    assert metadata.model_provider == :openai
    assert metadata.model_name == "gpt-5.4-mini"
    assert metadata.api == :chat_completions
    assert metadata.tool_choice == "auto"
    assert metadata.bound_tools == ["get_weather"]
    assert metadata.request_metadata == %{"trace_id" => "meta-1"}
    refute Map.has_key?(metadata.invocation_params, "messages")
    refute Map.has_key?(metadata.invocation_params, "metadata")
    refute Map.has_key?(metadata.invocation_params, "tools")

    assert %InvocationMetadata{} = metadata.invocation_metadata
    assert metadata.invocation_metadata.provider == :openai
    assert metadata.invocation_metadata.model == "gpt-5.4-mini"
    assert metadata.invocation_metadata.api == :chat_completions

    assert %Envelope{event: %Events.Done{usage: %{"prompt_tokens_details" => %{"cached_tokens" => 1}}}} =
             Enum.find(events, &match?(%Envelope{event: %Events.Done{}}, &1))
  end

  test "strict Chat Completions profiles reject Responses-only params before transport" do
    assert {:ok, model} =
             Models.init_chat_model("openai:gpt-5.4-mini", api: :chat_completions)

    assert {:error, error} =
             ChatCompletionsModel.request_body(model, [Message.user("x")],
               reasoning: %{effort: "low"},
               param_policy: %ParamPolicy{mode: :strict}
             )

    assert error.type == :unsupported_model_param
    assert error.details.params == [:reasoning]
  end

  defp replay_model(cassette_path) do
    %ChatCompletionsModel{
      model: "gpt-5.4-mini",
      api_key: "sk-replay-test",
      transport: BeamWeaver.Transport.Replay,
      transport_opts: [cassette_path: cassette_path]
    }
  end

  defp context_overflow_model(message \\ nil) do
    %ChatCompletionsModel{
      model: "gpt-5.4-mini",
      api_key: "sk-fake-test",
      transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
      transport_opts: [
        status: 400,
        body: context_overflow_body(message),
        expect: %{method: :post, path: "/chat/completions"}
      ]
    }
  end

  defp context_overflow_body(message) do
    message =
      message ||
        "Input tokens exceed the configured limit of 272000 tokens. Your messages resulted in 300007 tokens. Please reduce the length of the messages."

    %{
      "error" => %{
        "message" => message,
        "type" => "invalid_request_error",
        "param" => "messages",
        "code" =>
          if(String.contains?(message, "context window"),
            do: "invalid_request_error",
            else: "context_length_exceeded"
          )
      }
    }
  end

  defp weather_tool do
    Tool.from_function!(
      name: "get_weather",
      description: "Get weather",
      input_schema: %{required: [:city]},
      handler: fn input, _opts -> input end
    )
  end

  defp write_gzip_cassette(request_body, response_body, opts \\ []) when is_map(request_body) do
    write_gzip_cassette([{request_body, response_body, opts}])
  end

  defp write_gzip_cassette(interactions) when is_list(interactions) do
    path =
      Path.join([
        System.tmp_dir!(),
        "beam_weaver_openai_chat_completions_#{System.unique_integer([:positive])}.yaml.gz"
      ])

    File.write!(path, :zlib.gzip(cassette_yaml(interactions)))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cassette_yaml(interactions) do
    requests =
      Enum.map_join(interactions, "\n", fn interaction ->
        {request_body, _response_body, _opts} = normalize_interaction(interaction)

        """
        - body: !!binary |
            #{Base.encode64(BeamWeaver.JSON.encode!(request_body))}
          headers:
            authorization:
            - '**REDACTED**'
          method: POST
          uri: https://api.openai.com/v1/chat/completions
        """
      end)

    responses =
      Enum.map_join(interactions, "\n", fn interaction ->
        {_request_body, response_body, opts} = normalize_interaction(interaction)
        content_type = Keyword.get(opts, :content_type, "application/json")

        """
        - body:
            string: !!binary |
              #{Base.encode64(response_body(response_body))}
          headers:
            content-type:
            - #{content_type}
          status:
            code: 200
            message: OK
        """
      end)

    """
    requests:
    #{requests}
    responses:
    #{responses}
    """
  end

  defp normalize_interaction({request_body, response_body}), do: {request_body, response_body, []}

  defp normalize_interaction({request_body, response_body, opts}),
    do: {request_body, response_body, opts}

  defp response_body(response_body) when is_binary(response_body), do: response_body

  defp response_body(response_body) when is_map(response_body),
    do: BeamWeaver.JSON.encode!(response_body)
end
