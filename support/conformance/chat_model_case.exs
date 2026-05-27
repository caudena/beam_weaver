defmodule BeamWeaver.TestSupport.Conformance.ChatModelCase do
  @moduledoc """
  Shared ExUnit checks for `BeamWeaver.Core.ChatModel` implementations.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Core.Async
      alias BeamWeaver.Core.ChatModel
      alias BeamWeaver.Core.ContentBlock
      alias BeamWeaver.Core.LanguageModel
      alias BeamWeaver.Core.Message
      alias BeamWeaver.Core.Messages.InvalidToolCall
      alias BeamWeaver.Core.Tool
      alias BeamWeaver.Models
      alias BeamWeaver.TestSupport.Conformance.Subject
      alias BeamWeaver.Stream.Envelope
      alias BeamWeaver.Stream.Events

      @beamweaver_subject Subject.new(opts, :chat_model)

      test "chat model accepts BeamWeaver messages and returns an assistant message" do
        model = build_subject()
        messages = fixture(:messages)

        assert {:ok, %Message{role: :assistant} = response} = ChatModel.invoke(model, messages)
        assert Message.text(response) != ""
      end

      test "chat model rejects invalid message input before provider code runs" do
        model = build_subject()

        assert {:error, error} =
                 ChatModel.invoke(model, [%{role: :user, content: "not a struct"}])

        assert error.type == :invalid_message
      end

      test "chat model normalizes scalar user input" do
        model = build_subject()

        assert {:ok, %Message{role: :assistant} = response} = ChatModel.invoke(model, "hello")
        assert Message.text(response) != ""
      end

      test "chat model async invoke and batch preserve behavior and order" do
        model = build_subject()
        messages = fixture(:messages)

        assert {:ok, %Message{} = async_response} =
                 model
                 |> ChatModel.async_invoke(messages)
                 |> Async.await()

        assert Message.text(async_response) != ""

        handles =
          ChatModel.async_batch(model, [
            [Message.user("first")],
            [Message.user("second")]
          ])

        assert [{:ok, first}, {:ok, second}] = Async.await_batch(handles)
        assert Message.text(first) =~ "first"
        assert Message.text(second) =~ "second"
      end

      test "chat model sync batch preserves behavior and order" do
        model = build_subject()

        assert [{:ok, first}, {:ok, second}] =
                 ChatModel.batch(model, [
                   [Message.user("first")],
                   [Message.user("second")]
                 ])

        assert Message.text(first) =~ "first"
        assert Message.text(second) =~ "second"
      end

      if Subject.capability?(@beamweaver_subject, :streaming) do
        test "chat model streaming returns enumerable chunks" do
          model = build_subject()

          assert {:ok, stream} = ChatModel.stream(model, fixture(:messages), [])
          assert Enum.to_list(stream) != []
        end

        test "chat model streaming facade normalizes scalar input" do
          model = build_subject()

          assert {:ok, stream} = ChatModel.stream(model, "hello")
          assert Enum.to_list(stream) != []
        end
      end

      if Subject.capability?(@beamweaver_subject, :stream_events) do
        test "chat model event streaming returns typed envelopes" do
          model = build_subject()

          assert {:ok, stream} =
                   ChatModel.stream_events(model, fixture(:messages))

          events = Enum.to_list(stream)
          assert events != []
          assert Enum.all?(events, &match?(%Envelope{}, &1))
        end
      end

      if Subject.capability?(@beamweaver_subject, :stream_lifecycle) do
        test "chat model event streaming preserves token, chunk, and terminal lifecycle events" do
          model = build_subject()

          assert {:ok, stream} =
                   ChatModel.stream_events(model, fixture(:messages))

          events = Enum.to_list(stream)
          assert Enum.any?(events, &match?(%Envelope{event: %Events.Token{}}, &1))
          assert Enum.any?(events, &match?(%Envelope{event: %Events.MessageChunk{}}, &1))
          assert Enum.any?(events, &match?(%Envelope{event: %Events.Done{}}, &1))
        end
      end

      if Subject.capability?(@beamweaver_subject, :usage_metadata) do
        test "chat model exposes usage metadata when supported" do
          model = build_subject()

          assert {:ok, %Message{usage_metadata: usage}} =
                   ChatModel.invoke(model, fixture(:messages))

          assert is_map(usage)
          assert usage != %{}
        end
      end

      if Subject.capability?(@beamweaver_subject, :usage_details) do
        test "chat model usage metadata preserves provider token details and model identity" do
          model = build_subject()

          assert {:ok, %Message{usage_metadata: usage, response_metadata: response_metadata}} =
                   ChatModel.invoke(model, fixture(:messages))

          assert is_integer(usage.input_tokens)
          assert is_integer(usage.output_tokens)
          assert is_integer(usage.total_tokens)

          input_details = Map.get(usage, :input_token_details, %{})
          output_details = Map.get(usage, :output_token_details, %{})

          assert is_map(input_details)
          assert is_map(output_details)

          assert Enum.all?(Map.values(input_details), &is_integer/1)
          assert Enum.all?(Map.values(output_details), &is_integer/1)
          assert usage.input_tokens >= Enum.sum(Map.values(input_details))
          assert usage.output_tokens >= Enum.sum(Map.values(output_details))
          assert is_binary(response_metadata["model_name"])
        end
      end

      if Subject.capability?(@beamweaver_subject, :tool_calling) do
        test "chat model can return tool calls when tools are supplied" do
          model = build_subject()
          tool = fixture(:tool, lookup_tool())

          assert {:ok, %Message{tool_calls: [tool_call | _rest]}} =
                   ChatModel.invoke(model, fixture(:messages), tools: [tool])

          assert (tool_call[:id] || tool_call["id"]) != nil
          assert (tool_call[:name] || tool_call["name"]) == Tool.name(tool)
        end
      end

      if Subject.capability?(@beamweaver_subject, :parallel_tool_calls) do
        test "chat model can return parallel tool calls deterministically" do
          model = build_subject()

          assert {:ok, %Message{tool_calls: calls}} =
                   ChatModel.invoke(model, fixture(:messages),
                     tools: [lookup_tool(), time_tool()]
                   )

          assert Enum.map(calls, &(Map.get(&1, :name) || Map.get(&1, "name"))) == [
                   "lookup",
                   "time"
                 ]
        end
      end

      if Subject.capability?(@beamweaver_subject, :tool_choice) do
        test "chat model forwards native tool choice and supports no-argument tools" do
          model = build_subject()
          tool = no_args_tool()

          assert {:ok, %Message{tool_calls: [call]}} =
                   ChatModel.invoke(model, fixture(:messages),
                     tools: [lookup_tool(), tool],
                     tool_choice: Tool.name(tool)
                   )

          assert (call[:name] || call["name"]) == Tool.name(tool)
          assert (call[:args] || call["args"] || call[:arguments] || call["arguments"]) == %{}

          if fixture(:assert_forwarded_opts?, false) do
            assert_received {:fake_chat_model_call, _messages, opts}
            assert Keyword.fetch!(opts, :tool_choice) == Tool.name(tool)
          end
        end
      end

      if Subject.capability?(@beamweaver_subject, :structured_output) do
        test "chat model supports structured output wrapper" do
          schema =
            fixture(:structured_schema, %{
              "title" => "answer",
              "type" => "object",
              "required" => ["value"],
              "properties" => %{"value" => %{"type" => "string"}}
            })

          model = build_subject() |> Models.with_structured_output(schema)

          assert {:ok, %Message{metadata: metadata}} =
                   ChatModel.invoke(model, fixture(:messages), [])

          assert metadata[:structured_response] || metadata["structured_response"] ||
                   metadata["parsed"]
        end
      end

      if Subject.capability?(@beamweaver_subject, :exact_tokenizer) do
        test "chat model token counting can use an explicit tokenizer adapter" do
          model = build_subject()
          expected = fixture(:expected_token_count, 2)

          assert {:ok, ^expected} =
                   LanguageModel.count_tokens({:model, model}, [Message.user("hello world")])
        end
      end

      if Subject.capability?(@beamweaver_subject, :param_validation) do
        test "chat model validates unsupported standard params before invocation" do
          model = build_subject()
          invalid_opts = fixture(:invalid_param_opts, temperature: 0.2)

          assert {:error, error} = ChatModel.invoke(model, fixture(:messages), invalid_opts)
          assert error.type == :unsupported_model_param
          assert error.details.params != []
        end
      end

      if Subject.capability?(@beamweaver_subject, :standard_params) do
        test "chat model accepts declared standard params and forwards them to provider boundary" do
          model = build_subject()
          opts = fixture(:standard_param_opts, tools: [lookup_tool()])

          assert {:ok, %Message{}} = ChatModel.invoke(model, fixture(:messages), opts)

          if fixture(:assert_forwarded_opts?, false) do
            assert_received {:fake_chat_model_call, _messages, forwarded_opts}

            for {key, value} <- opts do
              assert Keyword.get(forwarded_opts, key) == value
            end
          end
        end
      end

      if Subject.capability?(@beamweaver_subject, :message_histories) do
        test "chat model accepts multi-turn histories, names, tool calls, and tool status" do
          model = build_subject()

          messages = [
            Message.system("system one"),
            Message.system("system two"),
            Message.user("hello", name: "example_user"),
            Message.assistant("",
              tool_calls: [
                %{
                  "type" => "tool_call",
                  "id" => "call_add",
                  "name" => "adder",
                  "args" => %{"a" => 1, "b" => 2}
                }
              ]
            ),
            Message.tool(~s({"result":3}),
              name: "adder",
              tool_call_id: "call_add",
              status: :success
            ),
            Message.tool("Error: Missing required argument 'b'.",
              name: "adder",
              tool_call_id: "call_bad",
              status: :error
            ),
            Message.user([%{"type" => "text", "text" => "next question"}])
          ]

          assert {:ok, %Message{role: :assistant}} = ChatModel.invoke(model, messages)

          if fixture(:assert_forwarded_opts?, false) do
            assert_received {:fake_chat_model_call, ^messages, _opts}
          end
        end
      end

      if Subject.capability?(@beamweaver_subject, :multimodal_inputs) do
        test "chat model accepts native and provider-shaped multimodal content blocks" do
          model = build_subject()

          messages = [
            Message.user([
              ContentBlock.text("summarize these inputs"),
              ContentBlock.image(%{url: "https://example.test/image.png"}),
              ContentBlock.image(%{data: "image-bytes", mime_type: "image/png"}),
              ContentBlock.audio(%{data: "audio-bytes", mime_type: "audio/wav"}),
              ContentBlock.file(%{
                data: "pdf-bytes",
                mime_type: "application/pdf",
                filename: "report.pdf"
              }),
              %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAAA"}},
              %{"type" => "input_audio", "input_audio" => %{"data" => "AAAA", "format" => "wav"}},
              %{
                "type" => "file",
                "file" => %{
                  "filename" => "report.pdf",
                  "file_data" => "data:application/pdf;base64,PDF"
                }
              }
            ]),
            Message.assistant([
              %{"type" => "text", "text" => "checking"},
              %{
                "type" => "tool_use",
                "id" => "call_color",
                "name" => "color_picker",
                "input" => %{"fav_color" => "purple"}
              },
              %{
                "type" => "thinking",
                "thinking" => "checking the user-provided media",
                "signature" => "sig"
              }
            ]),
            Message.tool(
              [
                ContentBlock.image(%{data: "tool-image", mime_type: "image/png"}),
                ContentBlock.file(%{data: "tool-pdf", mime_type: "application/pdf"})
              ],
              tool_call_id: "call_color",
              name: "color_picker"
            )
          ]

          assert {:ok, %Message{role: :assistant}} = ChatModel.invoke(model, messages)
        end
      end

      if Subject.capability?(@beamweaver_subject, :env_config_init) do
        test "chat model can be initialized from explicit env/config helper when supported" do
          {group, key, config_value} =
            fixture(:config, {:test_support, :fake_chat_reply, "env configured"})

          BeamWeaver.TestSupport.ConfigHelper.merge_config(group, [{key, config_value}])

          env_builder = fixture(:env_builder)
          model = env_builder.()

          assert {:ok, %Message{} = response} = ChatModel.invoke(model, fixture(:messages))
          assert Message.text(response) =~ config_value
        end
      end

      if Subject.capability?(@beamweaver_subject, :model_override) do
        test "chat model receives model override as explicit runtime config" do
          model = build_subject()
          parent = fixture(:parent, self())

          assert {:ok, %Message{}} =
                   ChatModel.invoke(model, fixture(:messages), model: "override-model")

          assert_received {:fake_chat_model_call, _messages, opts}
          assert Keyword.fetch!(opts, :model) == "override-model"
          assert parent == self()
        end
      end

      if Subject.capability?(@beamweaver_subject, :invalid_streamed_tool_call) do
        test "malformed streamed tool-call args survive as invalid tool calls" do
          model = build_subject()

          assert {:ok, stream} = ChatModel.stream(model, fixture(:messages), [])

          message =
            stream
            |> Enum.to_list()
            |> BeamWeaver.Core.Messages.MessageChunk.merge_many()
            |> BeamWeaver.Core.Messages.MessageChunk.to_message()

          assert [%InvalidToolCall{}] = message.metadata[:invalid_tool_calls]
        end
      end

      defp build_subject, do: Subject.build(@beamweaver_subject)
      defp fixture(key, default \\ nil), do: Subject.fixture(@beamweaver_subject, key, default)

      defp lookup_tool do
        Tool.from_function!(
          name: "lookup",
          description: "Lookup a value",
          input_schema: %{required: [:query]},
          handler: fn input, _opts -> input.query end
        )
      end

      defp time_tool do
        Tool.from_function!(
          name: "time",
          description: "Get time",
          input_schema: %{required: [:zone]},
          handler: fn input, _opts -> input.zone end
        )
      end

      defp no_args_tool do
        Tool.from_function!(
          name: "magic_function_no_args",
          description: "Calculate a magic function",
          input_schema: %{"type" => "object", "properties" => %{}, "required" => []},
          handler: fn _input, _opts -> 5 end
        )
      end
    end
  end
end
