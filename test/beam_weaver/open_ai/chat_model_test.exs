defmodule BeamWeaver.OpenAI.ChatModelTest do
  use ExUnit.Case

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.OpenAI.ChatModel
  alias BeamWeaver.OpenAI.Messages
  alias BeamWeaver.OpenAI.ModelPolicy
  alias BeamWeaver.OpenAI.Responses
  alias BeamWeaver.OpenAI.ToolCalling
  alias BeamWeaver.Runtime.Agent
  alias BeamWeaver.Tokenizer.Approximate
  alias BeamWeaver.Tracing

  setup do
    Tracing.reset()

    on_exit(fn ->
      Tracing.reset()
    end)

    :ok
  end

  def handle_param_warning(event, measurements, metadata, parent) do
    send(parent, {:param_warning, event, measurements, metadata})
  end

  test "constructor accepts native model options and streaming intent" do
    assert %ChatModel{model: "foo"} = model = ChatModel.new(model: "foo")
    assert ChatModel.model_name(model) == "foo"

    assert %ChatModel{max_tokens: 10, max_completion_tokens: 10} =
             ChatModel.new(max_completion_tokens: 10)

    assert %ChatModel{max_tokens: 7, max_completion_tokens: nil} = ChatModel.new(max_tokens: 7)

    assert %ChatModel{endpoint: "https://example.test/v1/responses"} =
             ChatModel.new(endpoint: "https://example.test/v1/responses")

    streaming = ChatModel.new(model: "foo", streaming: true)
    assert ChatModel.should_stream?(streaming, async_api: true)
    assert ChatModel.should_stream?(streaming, async_api: false)
    refute ChatModel.should_stream?(%ChatModel{}, async_api: true)
    assert ChatModel.should_stream?(%ChatModel{}, stream: true)
  end

  test "constructor resolves OpenAI model profiles without mutable global profile state" do
    gpt41 = ChatModel.new(model: "gpt-4.1")
    assert %Profile{provider: :openai, id: "gpt-4.1"} = gpt41.profile
    assert gpt41.profile.structured_output
    refute gpt41.profile.reasoning_output

    gpt5 = ChatModel.new(model: "gpt-5")
    assert %Profile{provider: :openai, id: "gpt-5"} = gpt5.profile
    assert gpt5.profile.structured_output
    assert gpt5.profile.tool_calling
    assert gpt5.profile.max_input_tokens == 272_000

    changed_copy = %{gpt5.profile | tool_calling: false}
    refute changed_copy.tool_calling
    assert ChatModel.new(model: "gpt-5").profile.tool_calling

    override = ChatModel.new(model: "gpt-5", profile: %{tool_calling: false})
    refute override.profile.tool_calling
    assert override.profile.extra == %{}

    assert_raise ArgumentError, ~r/OpenAI model is deprecated; use openai:gpt-4.1/, fn ->
      ChatModel.new(model: "gpt-4")
    end
  end

  test "token counting includes message structure, media, tools, and tokenizer fallback" do
    messages = [
      Message.user([
        %{"type" => "text", "text" => "look here"},
        %{"type" => "image_url", "image_url" => %{"url" => "https://example.test/a.png"}},
        %{"type" => "input_audio", "data" => "AAAA"}
      ]),
      Message.assistant("using tool",
        name: "assistant",
        tool_calls: [%ToolCall{id: "call-1", name: "lookup", args: %{"q" => "beam"}}]
      ),
      Message.tool("result", tool_call_id: "call-1")
    ]

    model = ChatModel.new(model: "gpt-5.4-mini", tokenizer: %Approximate{mode: :words})

    assert {:ok, tokenized} =
             ChatModel.count_tokens(model, messages,
               tokens_per_image: 85,
               tokens_per_audio: 120,
               tools: [%{"type" => "function", "function" => %{"name" => "lookup"}}]
             )

    assert tokenized > 220

    no_tokenizer = ChatModel.new(model: "local-test-model", profile: %{tokenizer: nil})
    assert {:ok, approximate} = ChatModel.count_tokens(no_tokenizer, messages, [])
    assert approximate > 100

    assert {:ok, 2} = ChatModel.count_tokens(model, "plain text", [])
  end

  test "OpenAI initializer rejects deprecated o-series and accepts frontier reasoning models" do
    assert %ChatModel{reasoning_effort: "minimal"} =
             ChatModel.new(model: "gpt-5", reasoning_effort: "minimal")

    assert {:error, error} =
             Models.init_chat_model("openai:o1-preview", reasoning_effort: "medium")

    assert error.type == :deprecated_model
    assert error.details.replacement == "gpt-5"

    assert {:ok, %ChatModel{reasoning_effort: "minimal"}} =
             Models.init_chat_model("openai:gpt-5", reasoning_effort: "minimal")
  end

  test "model policy records OpenAI Responses-preferred families" do
    for model <- [
          "gpt-5.4-pro",
          "gpt-5.5-pro"
        ] do
      assert ModelPolicy.prefers_responses_api?(model)
    end

    for model <- ["gpt-5", "gpt-5.5", "gpt-5.4", "o3-pro", "gpt-4.1", nil] do
      refute ModelPolicy.prefers_responses_api?(model)
    end
  end

  test "invokes the Responses API through a replay cassette and decodes assistant text" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "ping"}
      ],
      "stream" => false
    }

    response_body = %{
      "id" => "resp_replay",
      "model" => "gpt-5.4-mini",
      "output" => [
        %{
          "type" => "message",
          "content" => [
            %{"type" => "output_text", "text" => "pong from replay"}
          ]
        }
      ]
    }

    cassette_path = write_gzip_cassette(request_body, BeamWeaver.JSON.encode!(response_body))
    model = replay_model(cassette_path)

    assert {:ok, %Message{role: :assistant} = response} =
             CoreChatModel.invoke(model, [Message.user("ping")])

    assert Message.text(response) == "pong from replay"
    assert response.metadata.id == "resp_replay"
  end

  test "async invoke uses the same replay-backed Responses API request shape" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "async ping"}
      ],
      "stream" => false,
      "metadata" => %{"request_id" => "async_1"}
    }

    response_body = %{
      "id" => "resp_async",
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => "async pong"}]
        }
      ]
    }

    model =
      replay_model(write_gzip_cassette(request_body, BeamWeaver.JSON.encode!(response_body)))

    task =
      ChatModel.async_invoke(model, [Message.user("async ping")], metadata: %{request_id: "async_1"})

    assert {:ok, response} = Async.await(task)
    assert Message.text(response) == "async pong"
    assert response.metadata.id == "resp_async"
  end

  test "Responses API maps context-window provider errors to tagged overflow errors" do
    model = context_overflow_model()

    assert {:error, %BeamWeaver.OpenAI.Error{type: :context_overflow} = error} =
             CoreChatModel.invoke(model, [Message.user("test")])

    assert error.message =~ "Input tokens exceed the configured limit"
    assert error.details.code == "context_length_exceeded"
    assert error.details.error_type == "invalid_request_error"

    assert {:error, %BeamWeaver.OpenAI.Error{type: :context_overflow}} =
             model
             |> ChatModel.async_invoke([Message.user("test")])
             |> Async.await()

    assert {:ok, stream} = ChatModel.stream(context_overflow_model(), [Message.user("test")])

    assert [
             %BeamWeaver.Stream.Events.Error{
               error: %BeamWeaver.OpenAI.Error{type: :context_overflow}
             }
           ] = Enum.to_list(stream)

    prompt_too_long = context_overflow_model("prompt is too long: 300000 tokens > 200000 maximum")

    assert {:error, %BeamWeaver.OpenAI.Error{type: :context_overflow} = prompt_error} =
             CoreChatModel.invoke(prompt_too_long, [Message.user("test")])

    assert prompt_error.message =~ "prompt is too long"
  end

  test "replay matching catches tool and structured-output request shape regressions" do
    schema = %{
      type: "object",
      properties: %{city: %{type: "string"}, unit: %{type: "string"}},
      required: [:city]
    }

    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "weather in Paris"}
      ],
      "stream" => false,
      "tools" => [
        %{
          "type" => "function",
          "name" => "get_weather",
          "description" => "Get the current weather",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "city" => %{"type" => "string"},
              "unit" => %{"type" => "string"}
            },
            "required" => ["city"]
          }
        }
      ],
      "text" => %{
        "format" => Messages.structured_output_format("WeatherAnswer", schema)
      }
    }

    response_body = %{
      "output" => [
        %{
          "type" => "message",
          "content" => [
            %{"type" => "output_text", "text" => ~s({"city":"Paris","unit":"c"})}
          ]
        }
      ]
    }

    cassette_path = write_gzip_cassette(request_body, BeamWeaver.JSON.encode!(response_body))
    model = replay_model(cassette_path)
    tool = weather_tool(schema)

    assert {:ok, response} =
             CoreChatModel.invoke(model, [Message.user("weather in Paris")],
               tools: [tool],
               response_format: %{name: "WeatherAnswer", schema: schema}
             )

    assert Message.text(response) == ~s({"city":"Paris","unit":"c"})
  end

  test "structured output stores parsed JSON and reports validator failures with response" do
    schema = %{
      type: "object",
      properties: %{response: %{type: "string"}},
      required: [:response]
    }

    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "respond with good"}
      ],
      "stream" => false,
      "text" => %{
        "format" => Messages.structured_output_format("BadModel", schema)
      }
    }

    response_body = %{
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => ~s({"response":"good"})}]
        }
      ]
    }

    cassette_path =
      write_gzip_cassette([
        {request_body, response_body},
        {request_body, response_body},
        {request_body, response_body}
      ])

    model = replay_model(cassette_path)

    assert {:ok, response} =
             CoreChatModel.invoke(model, [Message.user("respond with good")],
               response_format: %{name: "BadModel", schema: schema}
             )

    assert response.metadata.parsed == %{"response" => "good"}

    validator = fn
      %{"response" => "bad"} -> :ok
      parsed -> {:error, {:unexpected_response, parsed}}
    end

    assert {:error, error} =
             CoreChatModel.invoke(model, [Message.user("respond with good")],
               response_format: %{name: "BadModel", schema: schema, validator: validator}
             )

    assert error.type == :structured_output_parse_error
    assert error.details.parsed == %{"response" => "good"}
    assert error.details.response.role == :assistant
    assert error.details.response.content_preview == ~s({"response":"good"})

    task =
      ChatModel.async_invoke(model, [Message.user("respond with good")],
        response_format: %{name: "BadModel", schema: schema, validator: validator}
      )

    assert {:error, async_error} = Async.await(task)
    assert async_error.type == :structured_output_parse_error
    assert async_error.details.parsed == %{"response" => "good"}
  end

  test "structured output preserves valid falsy parsed values" do
    schema = %{
      type: "object",
      properties: %{sandwiches: %{type: "array", items: %{type: "string"}}},
      required: [:sandwiches]
    }

    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [%{"type" => "message", "role" => "user", "content" => "empty lunchbox"}],
      "stream" => false,
      "text" => %{
        "format" => Messages.structured_output_format("LunchBox", schema)
      }
    }

    response_body = %{
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => ~s({"sandwiches":[]})}]
        }
      ]
    }

    model = replay_model(write_gzip_cassette(request_body, response_body))

    assert {:ok, response} =
             CoreChatModel.invoke(model, [Message.user("empty lunchbox")],
               response_format: %{name: "LunchBox", schema: schema}
             )

    assert response.metadata.parsed == %{"sandwiches" => []}
  end

  test "structured output refusal returns a tagged provider error" do
    schema = %{type: "object", properties: %{answer: %{type: "string"}}, required: [:answer]}

    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [%{"type" => "message", "role" => "user", "content" => "refuse"}],
      "stream" => false,
      "text" => %{
        "format" => Messages.structured_output_format("Answer", schema)
      }
    }

    response_body = %{
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "refusal", "refusal" => "I cannot comply."}]
        }
      ]
    }

    model = replay_model(write_gzip_cassette(request_body, response_body))

    assert {:error, %BeamWeaver.OpenAI.Error{type: :openai_refusal} = error} =
             CoreChatModel.invoke(model, [Message.user("refuse")], response_format: %{name: "Answer", schema: schema})

    assert %{type: :refusal, refusal: "I cannot comply."} = error.details.refusal
    assert error.details.response.role == :assistant
    assert error.details.response.content_preview == ""
  end

  test "include_response_headers attaches transport headers to chat metadata" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "headers"}
      ],
      "stream" => false
    }

    response_body = %{
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => "header pong"}]
        }
      ]
    }

    cassette_path =
      write_gzip_cassette([
        {request_body, response_body},
        {request_body, response_body}
      ])

    model = %{replay_model(cassette_path) | include_response_headers: true}

    assert {:ok, response} = CoreChatModel.invoke(model, [Message.user("headers")])

    assert Message.text(response) == "header pong"
    assert response.metadata.headers["content-type"] == "application/json"

    task = ChatModel.async_invoke(model, [Message.user("headers")])

    assert {:ok, async_response} = Async.await(task)
    assert async_response.metadata.headers["content-type"] == "application/json"
  end

  test "audio input and output modality shape round-trips through replay" do
    request_body = %{
      "model" => "gpt-5.4",
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{"type" => "input_text", "text" => "What is happening in this audio clip?"},
            %{
              "type" => "input_audio",
              "input_audio" => %{"data" => "base64-audio", "format" => "wav"}
            }
          ]
        }
      ],
      "stream" => false,
      "modalities" => ["text", "audio"],
      "audio" => %{"voice" => "alloy", "format" => "wav"}
    }

    response_body = %{
      "id" => "resp_audio",
      "output" => [
        %{
          "type" => "message",
          "id" => "msg_audio",
          "role" => "assistant",
          "content" => [
            %{"type" => "output_text", "text" => "Someone is speaking."},
            %{
              "type" => "output_audio",
              "audio" => %{
                "data" => "base64-output-audio",
                "format" => "wav",
                "transcript" => "Someone is speaking."
              }
            }
          ]
        }
      ]
    }

    cassette_path = write_gzip_cassette(request_body, BeamWeaver.JSON.encode!(response_body))
    model = replay_model(cassette_path)

    assert {:ok, response} =
             CoreChatModel.invoke(
               model,
               [
                 Message.user([
                   %{"type" => "text", "text" => "What is happening in this audio clip?"},
                   %{"type" => "audio", "base64" => "base64-audio", "mime_type" => "audio/wav"}
                 ])
               ],
               model: "gpt-5.4",
               modalities: ["text", "audio"],
               audio: %{voice: "alloy", format: "wav"}
             )

    assert Message.text(response) == "Someone is speaking."

    assert [
             %{type: :text, text: "Someone is speaking."},
             %{
               type: :audio,
               audio: %{
                 "data" => "base64-output-audio",
                 "format" => "wav",
                 "transcript" => "Someone is speaking."
               }
             }
           ] = response.content

    assert %{"audio" => %{"data" => "base64-output-audio"}} = response.metadata.audio
  end

  test "Responses API option surface preserves provider request controls" do
    request_body = %{
      "model" => "gpt-5.5",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "option check"}
      ],
      "stream" => false,
      "custom_non_openai_param" => "kept",
      "text" => %{"verbosity" => "high"},
      "reasoning" => %{"effort" => "none"},
      "temperature" => 0.4,
      "max_output_tokens" => 100,
      "top_p" => 0.9,
      "frequency_penalty" => 0.1,
      "presence_penalty" => 0.2,
      "seed" => 42,
      "parallel_tool_calls" => true,
      "metadata" => %{"trace_id" => "trace_123"},
      "user" => "user_123",
      "service_tier" => "auto",
      "store" => false
    }

    response_body = %{
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => "options accepted"}]
        }
      ]
    }

    cassette_path = write_gzip_cassette(request_body, BeamWeaver.JSON.encode!(response_body))
    model = replay_model(cassette_path)

    assert {:ok, response} =
             CoreChatModel.invoke(model, [Message.user("option check")],
               model: "gpt-5.5",
               model_kwargs: %{custom_non_openai_param: "kept"},
               verbosity: :high,
               reasoning_effort: :none,
               temperature: 0.4,
               max_tokens: 100,
               top_p: 0.9,
               frequency_penalty: 0.1,
               presence_penalty: 0.2,
               seed: 42,
               parallel_tool_calls: true,
               metadata: %{trace_id: "trace_123"},
               user: "user_123",
               service_tier: :auto,
               store: false
             )

    assert Message.text(response) == "options accepted"
  end

  test "profile param policy rejects unsupported request params before transport" do
    profile =
      Profile.new(%{
        provider: :openai,
        id: "strict-model",
        supported_params: [:max_output_tokens]
      })

    model = %ChatModel{
      model: "strict-model",
      profile: profile,
      param_policy: %ParamPolicy{mode: :strict}
    }

    assert {:error, error} =
             ChatModel.request_body(model, [Message.user("hello")], temperature: 0.3)

    assert error.type == :unsupported_model_param
    assert error.details.params == [:temperature]
  end

  test "warn param policy emits telemetry and still builds provider request body" do
    profile =
      Profile.new(%{
        provider: :openai,
        id: "warn-model",
        supported_params: [:max_output_tokens]
      })

    handler_id = "openai-param-warning-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:beam_weaver, :models, :param_warning],
      &__MODULE__.handle_param_warning/4,
      self()
    )

    try do
      assert {:ok, body} =
               ChatModel.request_body(
                 %ChatModel{model: "warn-model", profile: profile},
                 [Message.user("hello")],
                 temperature: 0.3,
                 param_policy: :warn
               )

      assert body["temperature"] == 0.3

      assert_received {:param_warning, [:beam_weaver, :models, :param_warning], %{count: 1},
                       %{provider: :openai, model: "warn-model", params: [:temperature]}}
    after
      :telemetry.detach(handler_id)
    end
  end

  test "unknown profiles are permissive by default while escape hatches stay explicit" do
    unknown = Profile.new(provider: :openai, id: "future-model", extra: %{unknown: true})

    assert {:ok, body} =
             ChatModel.request_body(
               %ChatModel{model: "future-model", profile: unknown},
               [Message.user("hello")],
               temperature: 0.3,
               model_kwargs: %{custom_vendor_param: true},
               extra_body: %{another_vendor_param: "ok"},
               provider_opts: %{trace: true}
             )

    assert body["temperature"] == 0.3
    assert body["custom_vendor_param"] == true
    assert body["another_vendor_param"] == "ok"
  end

  test "GPT-5 request builder drops unsupported temperature unless reasoning effort is none" do
    for model <- ["GPT-5-NANO", "GPT-5-2025-01-01", "Gpt-5-Turbo", "gPt-5-mini"] do
      assert {:ok, restricted} =
               ChatModel.request_body(
                 %ChatModel{model: model, temperature: 0.5},
                 [Message.user("hello")]
               )

      refute Map.has_key?(restricted, "temperature")
    end

    assert {:ok, allowed} =
             ChatModel.request_body(
               %ChatModel{model: "gpt-5.5", temperature: 0.5, reasoning_effort: :none},
               [Message.user("hello")]
             )

    assert allowed["temperature"] == 0.5
    assert allowed["reasoning"] == %{"effort" => "none"}

    assert {:ok, deprecated_chat} =
             ChatModel.request_body(
               %ChatModel{model: "gpt-5-chat", temperature: 0.7},
               [Message.user("hello")]
             )

    refute Map.has_key?(deprecated_chat, "temperature")
  end

  test "structured output verbosity is merged into the Responses API text options" do
    schema = %{
      type: "object",
      properties: %{answer: %{type: "string"}},
      required: [:answer]
    }

    assert {:ok, body} =
             ChatModel.request_body(
               %ChatModel{model: "gpt-5", verbosity: :high},
               [
                 Message.user("hello")
               ],
               response_format: %{name: "Answer", schema: schema}
             )

    assert body["text"]["verbosity"] == "high"
    assert body["text"]["format"]["type"] == "json_schema"
    assert body["text"]["format"]["schema"]["properties"]["answer"]["type"] == "string"
  end

  test "streams Responses API text deltas from a replay cassette" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "tell a tiny story"}
      ],
      "stream" => true
    }

    response_body = """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":"Once"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":" upon"}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","delta":" a time"}

    data: [DONE]
    """

    cassette_path =
      write_gzip_cassette(request_body, response_body, content_type: "text/event-stream")

    model = replay_model(cassette_path)

    assert {:ok, chunks} = ChatModel.stream(model, [Message.user("tell a tiny story")])
    assert Enum.to_list(chunks) == ["Once", " upon", " a time"]
  end

  test "streams Responses API lifecycle events" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "tell a tiny story"}
      ],
      "stream" => true,
      "metadata" => %{"trace_id" => "responses-meta"}
    }

    response_body = """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","item_id":"msg_1","delta":"Once"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_stream","usage":{"total_tokens":5}}}
    """

    cassette_path =
      write_gzip_cassette(request_body, response_body, content_type: "text/event-stream")

    model = replay_model(cassette_path)

    assert {:ok, events} =
             ChatModel.stream_events(model, [Message.user("tell a tiny story")],
               metadata: %{trace_id: "responses-meta"}
             )

    assert Enum.any?(
             events,
             &match?(
               %{
                 "event" => "content-block-delta",
                 "delta" => %{"type" => "text-delta", "text" => "Once"}
               },
               &1
             )
           )

    assert Enum.any?(events, &match?(%{"event" => "message-finish"}, &1))
  end

  test "reconstructs streamed Responses API tool calls into an assistant message" do
    schema = %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"]
    }

    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "weather in San Francisco"}
      ],
      "stream" => true,
      "tools" => [
        %{
          "type" => "function",
          "name" => "get_weather",
          "description" => "Get the current weather",
          "parameters" => schema
        }
      ]
    }

    response_body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_stream_tool","model":"gpt-5.4-mini","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","namespace":"weather","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\\\"city\\\":"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"\\\"San Francisco\\\"}"}

    event: response.function_call_arguments.done
    data: {"type":"response.function_call_arguments.done","output_index":0,"item_id":"fc_1","name":"get_weather","arguments":"{\\\"city\\\":\\\"San Francisco\\\"}"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_stream_tool","model":"gpt-5.4-mini","usage":{"total_tokens":32},"output":[]}}

    data: [DONE]
    """

    cassette_path =
      write_gzip_cassette(request_body, response_body, content_type: "text/event-stream")

    model = replay_model(cassette_path)
    tool = weather_tool(schema)

    assert {:ok, response} =
             ChatModel.stream_response(model, [Message.user("weather in San Francisco")], tools: [tool])

    assert [
             %ToolCall{
               id: "call_1",
               provider_id: "fc_1",
               call_id: "call_1",
               name: "get_weather",
               args: %{"city" => "San Francisco"}
             }
           ] = response.tool_calls

    assert [
             %{
               "type" => "function_call",
               "namespace" => "weather",
               "arguments" => ~s({"city":"San Francisco"})
             }
           ] = response.metadata.output
  end

  test "streamed image generation requests and preserves partial image frames" do
    image_tool = ToolCalling.image_generation(quality: "low", output_format: "jpeg")

    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "draw a tiny green word"}
      ],
      "stream" => true,
      "tools" => [
        %{
          "type" => "image_generation",
          "quality" => "low",
          "output_format" => "jpeg",
          "partial_images" => 1
        }
      ]
    }

    response_body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_img_stream","model":"gpt-5.4-mini","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"image_generation_call","id":"ig_1","status":"in_progress"}}

    event: response.image_generation_call.partial_image
    data: {"type":"response.image_generation_call.partial_image","output_index":0,"item_id":"ig_1","partial_image_index":0,"partial_image_b64":"first-frame"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"image_generation_call","id":"ig_1","status":"completed","result":"final-image","output_format":"jpeg"}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_img_stream","model":"gpt-5.4-mini","output":[]}}

    data: [DONE]
    """

    cassette_path =
      write_gzip_cassette(request_body, response_body, content_type: "text/event-stream")

    model = replay_model(cassette_path)

    assert {:ok, response} =
             ChatModel.stream_response(model, [Message.user("draw a tiny green word")], tools: [image_tool])

    assert %{
             "type" => "image_generation_call",
             "id" => "ig_1",
             "status" => "completed",
             "result" => "final-image",
             "partial_images" => [
               %{"partial_image_index" => 0, "partial_image_b64" => "first-frame"}
             ]
           } = Responses.first_output_item(response, "image_generation_call")
  end

  test "streams content-block lifecycle events from a replay cassette" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "think then answer"}
      ],
      "stream" => true
    }

    response_body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_events","model":"gpt-5.4-mini","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}}

    event: response.reasoning_summary_part.added
    data: {"type":"response.reasoning_summary_part.added","output_index":0,"item_id":"rs_1","summary_index":0,"part":{"type":"summary_text","text":""}}

    event: response.reasoning_summary_text.delta
    data: {"type":"response.reasoning_summary_text.delta","output_index":0,"item_id":"rs_1","summary_index":0,"delta":"checked"}

    event: response.reasoning_summary_text.done
    data: {"type":"response.reasoning_summary_text.done","output_index":0,"item_id":"rs_1","summary_index":0,"text":"checked"}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":1,"item":{"type":"message","id":"msg_1","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":1,"item_id":"msg_1","content_index":0,"part":{"type":"output_text","text":""}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":1,"item_id":"msg_1","content_index":0,"delta":"done"}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":1,"item_id":"msg_1","content_index":0,"text":"done"}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_events","model":"gpt-5.4-mini","usage":{"total_tokens":10},"output":[]}}

    data: [DONE]
    """

    cassette_path =
      write_gzip_cassette(request_body, response_body, content_type: "text/event-stream")

    model = replay_model(cassette_path)

    assert {:ok, events} = ChatModel.stream_events(model, [Message.user("think then answer")])
    events = Enum.to_list(events)

    assert [
             %{"event" => "message-start", "message" => %{"id" => "resp_events"}},
             %{"event" => "content-block-start", "index" => 0},
             %{
               "event" => "content-block-delta",
               "index" => 0,
               "delta" => %{"type" => "reasoning-delta", "reasoning" => "checked"}
             },
             %{
               "event" => "content-block-finish",
               "index" => 0,
               "content" => %{"type" => "reasoning", "reasoning" => "checked"}
             },
             %{"event" => "content-block-start", "index" => 1},
             %{
               "event" => "content-block-delta",
               "index" => 1,
               "delta" => %{"type" => "text-delta", "text" => "done"}
             },
             %{
               "event" => "content-block-finish",
               "index" => 1,
               "content" => %{"type" => "text", "text" => "done"}
             },
             %{
               "event" => "message-finish",
               "message" => %{"id" => "resp_events", "usage" => %{"total_tokens" => 10}}
             }
           ] = events
  end

  test "async stream_response and stream_events reconstruct streamed Responses output" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "async stream"}
      ],
      "stream" => true
    }

    response_body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_async_stream","model":"gpt-5.4-mini","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","id":"msg_async","role":"assistant","content":[]}}

    event: response.content_part.added
    data: {"type":"response.content_part.added","output_index":0,"item_id":"msg_async","content_index":0,"part":{"type":"output_text","text":""}}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_async","content_index":0,"delta":"async "}

    event: response.output_text.delta
    data: {"type":"response.output_text.delta","output_index":0,"item_id":"msg_async","content_index":0,"delta":"done"}

    event: response.output_text.done
    data: {"type":"response.output_text.done","output_index":0,"item_id":"msg_async","content_index":0,"text":"async done"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"message","id":"msg_async","role":"assistant","status":"completed","content":[{"type":"output_text","text":"async done"}]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_async_stream","model":"gpt-5.4-mini","usage":{"total_tokens":9},"output":[]}}

    data: [DONE]
    """

    model =
      replay_model(write_gzip_cassette(request_body, response_body, content_type: "text/event-stream"))

    stream_task = ChatModel.async_stream(model, [Message.user("async stream")])
    assert {:ok, stream} = Async.await(stream_task)
    assert Enum.to_list(stream) == ["async ", "done"]

    response_task = ChatModel.async_stream_response(model, [Message.user("async stream")])
    assert {:ok, response} = Async.await(response_task)
    assert Message.text(response) == "async done"
    assert response.metadata.usage == %{"total_tokens" => 9}

    events_task = ChatModel.async_stream_events(model, [Message.user("async stream")])
    assert {:ok, events} = Async.await(events_task)

    assert Enum.any?(
             events,
             &match?(
               %{
                 "event" => "content-block-finish",
                 "content" => %{"type" => "text", "text" => "async done"}
               },
               &1
             )
           )
  end

  test "streams function-call lifecycle events from a replay cassette" do
    schema = %{
      "type" => "object",
      "properties" => %{"city" => %{"type" => "string"}},
      "required" => ["city"]
    }

    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "weather in San Francisco"}
      ],
      "stream" => true,
      "tools" => [
        %{
          "type" => "function",
          "name" => "get_weather",
          "description" => "Get the current weather",
          "parameters" => schema
        }
      ]
    }

    response_body = """
    event: response.created
    data: {"type":"response.created","response":{"id":"resp_tool_events","model":"gpt-5.4-mini","output":[]}}

    event: response.output_item.added
    data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":""}}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"{\\\"city\\\":"}

    event: response.function_call_arguments.delta
    data: {"type":"response.function_call_arguments.delta","output_index":0,"item_id":"fc_1","delta":"\\\"San Francisco\\\"}"}

    event: response.function_call_arguments.done
    data: {"type":"response.function_call_arguments.done","output_index":0,"item_id":"fc_1","name":"get_weather","arguments":"{\\\"city\\\":\\\"San Francisco\\\"}"}

    event: response.output_item.done
    data: {"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_1","name":"get_weather","arguments":"{\\\"city\\\":\\\"San Francisco\\\"}","status":"completed"}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_tool_events","model":"gpt-5.4-mini","usage":{"total_tokens":18},"output":[]}}

    data: [DONE]
    """

    cassette_path =
      write_gzip_cassette(request_body, response_body, content_type: "text/event-stream")

    model = replay_model(cassette_path)
    tool = weather_tool(schema)

    assert {:ok, events} =
             ChatModel.stream_events(model, [Message.user("weather in San Francisco")], tools: [tool])

    events = Enum.to_list(events)

    assert [
             %{"event" => "message-start", "message" => %{"id" => "resp_tool_events"}},
             %{
               "event" => "content-block-start",
               "index" => 0,
               "content" => %{"type" => "tool_call_chunk", "id" => "call_1"}
             },
             %{
               "event" => "content-block-delta",
               "index" => 0,
               "delta" => %{
                 "type" => "block-delta",
                 "fields" => %{"type" => "tool_call_chunk", "args" => ~s({"city":)}
               }
             },
             %{
               "event" => "content-block-delta",
               "index" => 0,
               "delta" => %{
                 "type" => "block-delta",
                 "fields" => %{"type" => "tool_call_chunk", "args" => ~s("San Francisco"})}
               }
             },
             %{
               "event" => "content-block-finish",
               "index" => 0,
               "content" => %{
                 "type" => "tool_call",
                 "id" => "call_1",
                 "name" => "get_weather",
                 "args" => %{"city" => "San Francisco"}
               }
             },
             %{
               "event" => "message-finish",
               "message" => %{"id" => "resp_tool_events", "usage" => %{"total_tokens" => 18}}
             }
           ] = events
  end

  test "async batch preserves input order while matching each replay request body" do
    interactions = [
      {
        %{
          "model" => "gpt-5.4-mini",
          "input" => [%{"type" => "message", "role" => "user", "content" => "first"}],
          "stream" => false
        },
        %{
          "output" => [
            %{
              "type" => "message",
              "content" => [%{"type" => "output_text", "text" => "first response"}]
            }
          ]
        }
      },
      {
        %{
          "model" => "gpt-5.4-mini",
          "input" => [%{"type" => "message", "role" => "user", "content" => "second"}],
          "stream" => false
        },
        %{
          "output" => [
            %{
              "type" => "message",
              "content" => [%{"type" => "output_text", "text" => "second response"}]
            }
          ]
        }
      }
    ]

    model = replay_model(write_gzip_cassette(interactions))

    tasks =
      ChatModel.async_batch(model, [
        [Message.user("first")],
        [Message.user("second")]
      ])

    assert [
             {:ok, first},
             {:ok, second}
           ] = Async.await_batch(tasks)

    assert Message.text(first) == "first response"
    assert Message.text(second) == "second response"
  end

  test "replay-backed OpenAI calls can run inside the supervised agent runtime" do
    request_body = %{
      "model" => "gpt-5.4-mini",
      "input" => [
        %{"type" => "message", "role" => "user", "content" => "agent ping"}
      ],
      "stream" => false
    }

    response_body = %{
      "output" => [
        %{
          "type" => "message",
          "content" => [
            %{"type" => "output_text", "text" => "agent pong"}
          ]
        }
      ]
    }

    cassette_path = write_gzip_cassette(request_body, BeamWeaver.JSON.encode!(response_body))
    model = replay_model(cassette_path)
    agent = start_supervised!({Agent, id: "openai_agent_#{System.unique_integer([:positive])}"})
    :ok = Agent.subscribe(agent)
    {:ok, parent_run} = Tracing.start_run("request")

    assert {:ok, work} =
             Agent.start_model_call(agent, [Message.user("agent ping")], fn messages ->
               CoreChatModel.invoke(model, messages)
             end)

    assert_receive {:beam_weaver_agent, _agent_id, {:completed, work_id, %Message{role: :assistant} = response}}

    assert work_id == work.id
    assert Message.text(response) == "agent pong"

    assert {:ok, %{children: [%{run: child_run}]}} = Tracing.get_tree(parent_run.id)
    assert child_run.id == work.trace_run_id
    assert child_run.parent_id == parent_run.id
  end

  defp replay_model(cassette_path) do
    %ChatModel{
      model: "gpt-5.4-mini",
      api_key: "sk-replay-test",
      transport: BeamWeaver.Transport.Replay,
      transport_opts: [cassette_path: cassette_path]
    }
  end

  defp context_overflow_model(message \\ nil) do
    %ChatModel{
      model: "gpt-5.4-mini",
      api_key: "sk-fake-test",
      transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
      transport_opts: [
        status: 400,
        body: context_overflow_body(message),
        expect: %{method: :post, path: "/responses"}
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
          if(String.contains?(message, "prompt is too long"),
            do: "invalid_request_error",
            else: "context_length_exceeded"
          )
      }
    }
  end

  defp weather_tool(schema) do
    Tool.from_function!(
      name: "get_weather",
      description: "Get the current weather",
      input_schema: schema,
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
        "beam_weaver_openai_#{System.unique_integer([:positive])}.yaml.gz"
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
          uri: https://api.openai.com/v1/responses
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
  defp response_body(response_body), do: BeamWeaver.JSON.encode!(response_body)
end
