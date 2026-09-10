defmodule BeamWeaver.DeepSeek.V41Test do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.DeepSeek.ChatModel
  alias BeamWeaver.DeepSeek.ResponsesModel
  alias BeamWeaver.Models
  alias BeamWeaver.Models.ProfileRegistry
  alias BeamWeaver.Models.UsageCost
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defmodule StreamTransport do
    @behaviour BeamWeaver.Transport
    def request(_request, _opts), do: raise("expected native streaming")

    def stream_reduce(request, opts, acc, reducer) do
      chunks = Keyword.fetch!(opts, :handler).(request.json)
      acc = Enum.reduce(chunks, acc, fn chunk, acc -> reducer.(acc, chunk) end)
      {:ok, BeamWeaver.Transport.Response.new(status: 200, body: ""), acc}
    end
  end

  @flash_ids ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"]

  test "V4.1 Flash and compatibility names work through both actual adapters" do
    assert ChatModel.new().model == "deepseek-flash"
    assert ResponsesModel.new().model == "deepseek-flash"

    for id <- @flash_ids, api <- [:chat_completions, :responses] do
      assert {:ok, model} = Models.init_chat_model("deepseek:" <> id, api: api)
      assert {:ok, body} = model.__struct__.request_body(model, [Message.user("hello")])
      assert body["model"] == id
      assert model.profile.image_inputs
      assert model.profile.extra.model_version == "DeepSeek-V4.1-Flash"
      assert model.profile.max_input_tokens == 1_048_576
      assert model.profile.max_output_tokens == 393_216
    end
  end

  test "image URLs and uploaded image IDs retain native wire shapes" do
    for id <- @flash_ids do
      image = ContentBlock.image(url: "https://example.test/red.png", metadata: %{detail: "original"})
      message = Message.user([ContentBlock.text("Describe"), image])
      assert {:ok, chat} = ChatModel.request_body(ChatModel.new(model: id), [message])

      assert hd(chat["messages"])["content"] == [
               %{"type" => "text", "text" => "Describe"},
               %{
                 "type" => "image_url",
                 "image_url" => %{"url" => "https://example.test/red.png", "detail" => "original"}
               }
             ]

      assert {:ok, responses} = ResponsesModel.request_body(ResponsesModel.new(model: id), [message])
      assert List.last(hd(responses["input"])["content"])["image_url"] == "https://example.test/red.png"

      file_message = Message.user([ContentBlock.image(file_id: "file-api-example")])
      assert {:ok, chat} = ChatModel.request_body(ChatModel.new(model: id), [file_message])
      assert hd(chat["messages"])["content"] == [%{"type" => "file", "file_id" => "file-api-example"}]
      assert {:ok, responses} = ResponsesModel.request_body(ResponsesModel.new(model: id), [file_message])
      assert hd(responses["input"])["content"] == [%{"type" => "input_image", "file_id" => "file-api-example"}]
    end
  end

  test "Responses allows developer and tool-output images and rejects unsupported roles and sources" do
    image = %{"type" => "input_image", "image_url" => "https://example.test/red.png"}
    model = ResponsesModel.new()

    for role <- ["user", "developer"] do
      assert {:ok, _body} =
               ResponsesModel.request_body(model, [],
                 input_items: [%{"type" => "message", "role" => role, "content" => [image]}]
               )
    end

    for role <- ["system", "assistant", %{}, 42, nil] do
      assert {:error, %{type: :invalid_request}} =
               ResponsesModel.request_body(model, [],
                 input_items: [%{"type" => "message", "role" => role, "content" => [image]}]
               )
    end

    call = %{
      "type" => "function_call",
      "id" => "fc_image",
      "call_id" => "call_image",
      "name" => "image",
      "arguments" => "{}"
    }

    output = %{"type" => "function_call_output", "call_id" => "call_image", "output" => [image]}
    assert {:ok, body} = ResponsesModel.request_body(model, [], input_items: [call, output])
    assert body["input"] == [call, output]

    for bad <- [Map.put(image, "file_id", "file-api-example"), Map.put(image, "detail", "invalid")] do
      assert {:error, %{type: :invalid_request}} =
               ResponsesModel.request_body(model, [],
                 input_items: [%{"type" => "message", "role" => "user", "content" => [bad]}]
               )
    end

    assert {:error, %{type: :invalid_request}} =
             ResponsesModel.request_body(model, [],
               input_items: [%{"type" => "message", "role" => "user", "content" => List.duplicate(image, 601)}]
             )

    assert {:error, %{type: :unsupported_feature}} =
             ResponsesModel.request_body(
               ResponsesModel.new(model: "deepseek-v4-pro"),
               [],
               input_items: [call, output]
             )
  end

  test "native image tool results keep correlation and media on both APIs" do
    for {model, provider_id} <- [{ChatModel.new(), "call_image"}, {ResponsesModel.new(), "fc_image"}] do
      call =
        BeamWeaver.Core.Messages.tool_call(
          id: "call_image",
          provider_id: provider_id,
          call_id: "call_image",
          name: "screenshot",
          args: %{}
        )

      image = ContentBlock.image(url: "https://example.test/red.png")

      messages = [
        Message.user("Describe the screenshot"),
        Message.assistant("", tool_calls: [call]),
        Message.tool([image], tool_call_id: "call_image")
      ]

      assert {:ok, body} = model.__struct__.request_body(model, messages)

      if match?(%ChatModel{}, model) do
        assert List.last(body["messages"])["tool_call_id"] == "call_image"

        assert List.last(body["messages"])["content"] == [
                 %{"type" => "image_url", "image_url" => %{"url" => "https://example.test/red.png"}}
               ]
      else
        assert List.last(body["input"])["call_id"] == "call_image"

        assert List.last(body["input"])["output"] == [
                 %{"type" => "input_image", "image_url" => "https://example.test/red.png"}
               ]
      end
    end
  end

  test "Chat supports automatic choices while thinking and accepts documented effort aliases" do
    for effort <- [:none, :minimal, :low, :medium, :high, :xhigh, :max, :ultra], choice <- [:none, :auto] do
      assert {:ok, body} =
               ChatModel.request_body(ChatModel.new(), [Message.user("hello")],
                 reasoning_effort: effort,
                 tool_choice: choice
               )

      assert body["reasoning_effort"] == Atom.to_string(effort)
    end

    name = String.duplicate("a", 128)
    tool = %{"type" => "function", "function" => %{"name" => name, "parameters" => %{"type" => "object"}}}

    assert {:ok, _body} =
             ChatModel.request_body(ChatModel.new(), [Message.user("hello")],
               reasoning_effort: :none,
               tools: [tool],
               tool_choice: :required
             )

    native_tool =
      Tool.from_function!(
        name: name,
        description: "Native tool",
        input_schema: %{"type" => "object"},
        handler: fn _, _ -> "ok" end
      )

    for model <- [ChatModel.new(), ResponsesModel.new()] do
      assert {:ok, _body} = model.__struct__.request_body(model, [Message.user("hello")], tools: [native_tool])
    end
  end

  test "Responses preserves returned opaque reasoning handles with or without plain content" do
    for content <- [nil, [%{"type" => "reasoning_text", "text" => "Need the tool result"}]] do
      reasoning = %{
        "type" => "reasoning",
        "id" => "rs_returned",
        "summary" => [],
        "encrypted_content" => "provider-opaque-handle"
      }

      reasoning = if content, do: Map.put(reasoning, "content", content), else: reasoning

      response = %{
        "id" => "response_returned",
        "model" => "deepseek-flash",
        "output" => [reasoning],
        "status" => "completed"
      }

      assert {:ok, message} = BeamWeaver.DeepSeek.Messages.responses_to_message(response)
      assert {:ok, body} = ResponsesModel.request_body(ResponsesModel.new(), [message])
      assert [replayed] = body["input"]
      assert replayed["encrypted_content"] == "provider-opaque-handle"
      assert replayed["content"] == content
      assert replayed["id"] == "rs_returned"
    end
  end

  test "cost estimation handles weekdays, historical Flash rates, and the scheduled Pro redirect" do
    usage = %{input_tokens: 1_000, cached_tokens: 400, output_tokens: 2_000}

    for id <- @flash_ids do
      {:ok, profile} = ProfileRegistry.fetch(:deepseek, id)
      assert_in_delta UsageCost.calculate(profile, usage, at: ~U[2026-09-10 06:00:00Z]).total_cost, 0.0025824, 1.0e-12
      assert_in_delta UsageCost.calculate(profile, usage, at: ~U[2026-09-12 06:00:00Z]).total_cost, 0.0012912, 1.0e-12
    end

    {:ok, flash} = ProfileRegistry.fetch(:deepseek, "deepseek-v4-flash")
    assert_in_delta UsageCost.calculate(flash, usage, at: ~U[2026-09-10 03:59:59Z]).total_cost, 0.0029096, 1.0e-12
    assert_in_delta UsageCost.calculate(flash, usage, at: ~U[2026-09-10 04:00:00Z]).total_cost, 0.0012912, 1.0e-12
    {:ok, pro} = ProfileRegistry.fetch(:deepseek, "deepseek-v4-pro")
    assert_in_delta UsageCost.calculate(pro, usage, at: ~U[2026-09-14 03:59:59Z]).total_cost, 0.0087296, 1.0e-12
    assert_in_delta UsageCost.calculate(pro, usage, at: ~U[2026-09-14 04:00:00Z]).total_cost, 0.0012912, 1.0e-12
  end

  for api <- [:chat_completions, :responses] do
    @api api
    test "#{api} agent streams, executes a local tool, and replays full reasoning to its next request" do
      parent = self()

      handler = fn body ->
        send(parent, {:wire, body})
        history = body["messages"] || body["input"]
        followup? = Enum.any?(history, &(&1["role"] == "tool" or &1["type"] == "function_call_output"))
        stream_chunks(@api, followup?)
      end

      {:ok, model} =
        Models.init_chat_model("deepseek:deepseek-flash",
          api: @api,
          api_key: "fixture",
          transport: StreamTransport,
          transport_opts: [handler: handler]
        )

      tool =
        Tool.from_function!(
          name: "probe",
          description: "Return a value",
          input_schema: %{"type" => "object", "properties" => %{}},
          handler: fn _, _ ->
            send(parent, :tool_executed)
            "pong"
          end
        )

      {:ok, agent} = BeamWeaver.Agent.build(model: model, tools: [tool], model_opts: [stream: true])

      {:ok, stream} =
        BeamWeaver.Agent.stream_events(agent, %{messages: [Message.user("Use probe")]},
          live: true,
          stream_mode: :events
        )

      events = Enum.map(stream, fn %Envelope{event: event} -> event end)
      assert_received :tool_executed
      refute_received :tool_executed
      assert_received {:wire, first}
      assert_received {:wire, second}
      assert first["stream"]
      assert second["stream"]
      refute_received {:wire, _}

      if @api == :chat_completions do
        assistant = Enum.find(second["messages"], &(&1["role"] == "assistant"))
        assert assistant["reasoning_content"] == "think fully"
        assert hd(assistant["tool_calls"])["id"] == "call_probe"
      else
        reasoning = Enum.find(second["input"], &(&1["type"] == "reasoning"))
        assert reasoning["content"] == [%{"type" => "reasoning_text", "text" => "think fully"}]
        assert reasoning["encrypted_content"] == "opaque-reasoning-handle"
        call = Enum.find(second["input"], &(&1["type"] == "function_call"))
        assert call["id"] == "fc_probe"
        assert call["call_id"] == "call_probe"
      end

      messages =
        Enum.flat_map(events, fn
          %Events.Message{message: %Message{role: :assistant} = message} -> [message]
          _ -> []
        end)

      assert Enum.map(messages, &Message.text/1) == ["Checking.", "Done."]
      assert Enum.all?(messages, &(&1.response_metadata.provider == :deepseek))
      assert Enum.all?(messages, &(&1.usage_metadata.total_tokens == 12))

      assert Enum.flat_map(events, fn
               %Events.Token{text: text} -> [text]
               _ -> []
             end) == ["Checking.", "Done."]

      refute Enum.any?(events, &match?(%Events.Error{}, &1))
    end
  end

  defp stream_chunks(:chat_completions, followup?) do
    deltas =
      if followup?,
        do: [%{"content" => "Done."}],
        else: [
          %{"role" => "assistant", "reasoning_content" => "think "},
          %{"reasoning_content" => "fully"},
          %{"content" => "Checking."},
          %{
            "tool_calls" => [
              %{
                "index" => 0,
                "id" => "call_probe",
                "type" => "function",
                "function" => %{"name" => "probe", "arguments" => "{"}
              }
            ]
          },
          %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "}"}}]}
        ]

    events =
      Enum.map(deltas, &%{"choices" => [%{"index" => 0, "delta" => &1}]}) ++
        [
          %{
            "choices" => [
              %{"index" => 0, "delta" => %{}, "finish_reason" => if(followup?, do: "stop", else: "tool_calls")}
            ],
            "usage" => %{
              "prompt_tokens" => 8,
              "completion_tokens" => 4,
              "total_tokens" => 12,
              "prompt_cache_hit_tokens" => 2
            }
          }
        ]

    Enum.map(events, fn event ->
      "data: " <>
        BeamWeaver.JSON.encode!(
          Map.merge(event, %{"id" => if(followup?, do: "chat_2", else: "chat_1"), "model" => "deepseek-flash"})
        ) <> "\n\n"
    end) ++ ["data: [DONE]\n\n"]
  end

  defp stream_chunks(:responses, followup?) do
    text = if followup?, do: "Done.", else: "Checking."

    message = %{
      "type" => "message",
      "id" => "msg_1",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }

    output =
      if followup?,
        do: [message],
        else: [
          %{
            "type" => "reasoning",
            "id" => "rs_1",
            "encrypted_content" => "opaque-reasoning-handle",
            "content" => [%{"type" => "reasoning_text", "text" => "think fully"}]
          },
          message,
          %{
            "type" => "function_call",
            "id" => "fc_probe",
            "call_id" => "call_probe",
            "name" => "probe",
            "arguments" => "{}"
          }
        ]

    events = [
      %{"type" => "response.output_text.delta", "item_id" => "msg_1", "delta" => text},
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => if(followup?, do: "resp_2", else: "resp_1"),
          "model" => "deepseek-flash",
          "status" => "completed",
          "output" => output,
          "usage" => %{"input_tokens" => 8, "output_tokens" => 4, "total_tokens" => 12}
        }
      }
    ]

    Enum.map(events, &"event: #{&1["type"]}\ndata: #{BeamWeaver.JSON.encode!(&1)}\n\n")
  end
end
