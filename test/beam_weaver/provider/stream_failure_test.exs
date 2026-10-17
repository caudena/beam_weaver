defmodule BeamWeaver.Provider.StreamFailureTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Provider.StreamFailure
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Response

  # Answers every request with the same 200 event stream.
  defmodule SSE do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(_request, opts) do
      {:ok,
       Response.new(
         status: 200,
         headers: [{"content-type", "text/event-stream"}, {"x-request-id", "req-1"}],
         body: Keyword.fetch!(opts, :body)
       )}
    end
  end

  # A provider that fails partway through a reply reports it in the stream:
  # OpenAI's Responses API (and xAI's) with an `error` event, Chat Completions
  # APIs and Gemini with an `error` object. Each case breaks off after the
  # start of the answer.
  for {model, opts, format, status} <- [
        {"openai:gpt-4.1", [], :responses, 500},
        {"openai:gpt-4.1", [api: :chat_completions], :chat_completions, 500},
        {"xai:grok-4.3", [], :responses, 500},
        {"xai:grok-4.3", [api: :chat_completions], :chat_completions, 500},
        {"google:gemini-2.5-flash", [], :gemini, 503},
        {"moonshot:kimi-k2.6", [], :chat_completions, 500},
        {"zai:glm-5.2", [], :chat_completions, 500},
        {"deepseek:deepseek-v4-flash", [], :chat_completions, 500}
      ] do
    describe "#{model} #{inspect(opts)}" do
      setup do
        opts = [api_key: "k", transport: SSE, transport_opts: [body: cut_off(unquote(format))]] ++ unquote(opts)
        {:ok, model} = BeamWeaver.Models.init_chat_model(unquote(model), opts)
        %{model: model, opts: opts}
      end

      test "a typed stream ends with the error, without a reply", %{model: model} do
        assert {:ok, stream} = ChatModel.stream_typed_events(model, [Message.user("Where is order A-1001?")])
        envelopes = Enum.to_list(stream)
        assert Enum.all?(envelopes, &is_struct(&1, Envelope))
        events = Enum.map(envelopes, & &1.event)

        assert [%Events.Error{error: error}] = Enum.filter(events, &is_struct(&1, Events.Error))
        assert_failure(error, unquote(status))
        refute Enum.any?(events, &(is_struct(&1, Events.Message) or is_struct(&1, Events.Done)))
      end

      test "stream_response/3 and a text stream return the error", %{model: model} do
        assert {:error, error} = model.__struct__.stream_response(model, [Message.user("Where is order A-1001?")])
        assert_failure(error, unquote(status))

        assert {:ok, stream} = ChatModel.stream(model, [Message.user("Where is order A-1001?")])
        assert ["It shipped on", %Events.Error{error: error}] = Enum.to_list(stream)
        assert_failure(error, unquote(status))
      end

      test "a streaming agent returns the error", %{opts: opts} do
        {:ok, agent} = BeamWeaver.Agent.build(name: "orders", model: unquote(model), model_opts: [stream: true] ++ opts)

        assert {:error, error} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is order A-1001?"]})
        assert_failure(error, unquote(status))
      end
    end
  end

  # OpenAI's and xAI's Responses APIs end a response that fails while it is
  # generated with a `response.failed` event, and one cut short (by
  # `max_output_tokens`, say) with `response.incomplete`.
  for {model, client} <- [{"openai:gpt-4.1", BeamWeaver.OpenAI.Client}, {"xai:grok-4.3", BeamWeaver.XAI.Client}] do
    describe "#{model} Responses API" do
      setup do
        failed = [api_key: "k", transport: SSE, transport_opts: [body: responses(:failed)]]
        incomplete = [api_key: "k", transport: SSE, transport_opts: [body: responses(:incomplete)]]

        %{
          failed: BeamWeaver.Models.init_chat_model!(unquote(model), failed),
          incomplete: BeamWeaver.Models.init_chat_model!(unquote(model), incomplete),
          client: fn opts -> unquote(client).new(opts) end,
          client_opts: %{failed: failed, incomplete: incomplete}
        }
      end

      test "every stream of a failed response ends with its error", context do
        messages = [Message.user("Where is order A-1001?")]

        assert {:ok, text} = ChatModel.stream(context.failed, messages)
        assert ["It shipped on", %Events.Error{error: text_error}] = Enum.to_list(text)

        client = context.client.(context.client_opts.failed)
        assert {:ok, lifecycle} = unquote(client).responses_stream_events(client, %{"input" => "hi", "stream" => true})
        assert %Events.Error{error: lifecycle_error} = lifecycle |> Enum.to_list() |> List.last()

        assert {:ok, typed} = ChatModel.stream_typed_events(context.failed, messages)
        typed = Enum.to_list(typed)
        assert Enum.all?(typed, &is_struct(&1, Envelope))
        assert [typed_error] = for(%Envelope{event: %Events.Error{error: error}} <- typed, do: error)
        refute Enum.any?(typed, &match?(%Envelope{event: %type{}} when type in [Events.Message, Events.Done], &1))

        assert {:error, collected_error} = context.failed.__struct__.stream_response(context.failed, messages)

        for error <- [text_error, lifecycle_error, typed_error, collected_error] do
          assert %Error{type: :server_error, message: "The model failed to generate a response."} = error
          assert error.details.status == 500
          assert error.details.code == "server_error"
          assert error.details.retryable
        end
      end

      test "an incomplete response ends every stream as a reply, as it does without streaming", context do
        messages = [Message.user("Where is order A-1001?")]

        assert {:ok, text} = ChatModel.stream(context.incomplete, messages)
        assert ["It shipped on"] = Enum.to_list(text)

        client = context.client.(context.client_opts.incomplete)
        assert {:ok, lifecycle} = unquote(client).responses_stream_events(client, %{"input" => "hi", "stream" => true})
        refute Enum.any?(lifecycle, &is_struct(&1, Events.Error))

        assert {:ok, typed} = ChatModel.stream_typed_events(context.incomplete, messages)

        assert [%Events.Message{message: %Message{status: "incomplete"}}, %Events.Done{}] =
                 for(
                   %Envelope{event: %type{} = event} <- typed,
                   type in [Events.Message, Events.Done, Events.Error],
                   do: event
                 )

        assert {:ok, %Message{status: "incomplete"} = reply} =
                 context.incomplete.__struct__.stream_response(context.incomplete, messages)

        assert Message.text(reply) == "It shipped on"
      end
    end
  end

  test "a wrapped model's typed stream ends with the error, not a custom event and Done" do
    {:ok, model} =
      BeamWeaver.Models.init_chat_model("openai:gpt-4.1",
        api: :chat_completions,
        api_key: "k",
        transport: SSE,
        transport_opts: [body: cut_off(:chat_completions)]
      )

    bound = BeamWeaver.Models.bind_tools(model, [])

    assert {:ok, stream} = ChatModel.stream_typed_events(bound, [Message.user("Where is order A-1001?")])

    assert [
             %Envelope{event: %Events.Token{text: "It shipped on"}},
             %Envelope{event: %Events.Error{error: error}}
           ] = Enum.to_list(stream)

    assert_failure(error, 500)
  end

  # A failure whose code no provider documents is a retryable server error,
  # and a warning names the provider and the code the first time it comes in
  # this VM. Each test uses codes (or providers) of its own, so the warnings
  # of other tests never count.
  describe "an error no provider documents" do
    setup do
      %{code: "brand_new_#{System.unique_integer([:positive])}", messages: [Message.user("Where is order A-1001?")]}
    end

    test "is logged once per provider and code, without the error's message", %{code: code, messages: messages} do
      model = chat_completions_model(undocumented(code))

      log =
        capture_log(fn ->
          assert {:ok, stream} = ChatModel.stream(model, messages)
          assert ["It shipped on", %Events.Error{error: error}] = Enum.to_list(stream)
          assert %Error{type: :server_error, message: "Try again, Ada."} = error
          assert error.details.status == 500
          assert error.details.retryable
        end)

      assert log =~ ~s(OpenAI reported a stream error with type "#{code}")
      assert log =~ "treated as a retryable server error (HTTP 500)"
      refute log =~ "Ada"

      log =
        capture_log(fn ->
          assert {:error, %Error{details: %{status: 500}}} = model.__struct__.stream_response(model, messages)
          assert {:ok, stream} = ChatModel.stream(model, messages)
          assert ["It shipped on", %Events.Error{}] = Enum.to_list(stream)
        end)

      refute log =~ code
    end

    test "a collected stream logs it too", %{code: code, messages: messages} do
      model = chat_completions_model(undocumented(code))

      log =
        capture_log(fn ->
          assert {:error, %Error{details: %{status: 500, retryable: true}}} =
                   model.__struct__.stream_response(model, messages)
        end)

      assert log =~ ~s(OpenAI reported a stream error with type "#{code}")
    end

    test "a documented error is not logged", %{messages: messages} do
      model = chat_completions_model(cut_off(:chat_completions))

      log =
        capture_log(fn ->
          assert {:error, %Error{details: %{status: 500}}} = model.__struct__.stream_response(model, messages)
        end)

      refute log =~ ~s(type "server_error")
    end

    test "each provider's first error without a code is logged" do
      provider = :"provider_#{System.unique_integer([:positive])}"
      events = [%{"data" => %{"error" => %{"message" => "Boom"}}}]

      log = capture_log(fn -> assert {[], {500, _body}} = StreamFailure.split(events, provider) end)
      assert log =~ "#{provider} reported a stream error without a code, so it was treated as a retryable server error"

      log = capture_log(fn -> assert {[], {500, _body}} = StreamFailure.split(events, provider) end)
      refute log =~ "#{provider} reported"
    end

    test "a code that looks like a secret is redacted" do
      provider = :"provider_#{System.unique_integer([:positive])}"
      secret = "sk-proj-abcdefghijklmnopqrstuvwxyz0123456789"
      events = [%{"data" => %{"error" => %{"code" => secret, "message" => "Boom"}}}]

      log = capture_log(fn -> assert {[], {500, _body}} = StreamFailure.split(events, provider) end)
      assert log =~ ~s(#{provider} reported a stream error with code "**REDACTED**")
      refute log =~ secret
    end

    test "a code is remembered after the process that streamed it exits" do
      provider = :"provider_#{System.unique_integer([:positive])}"
      events = [%{"data" => %{"error" => %{"code" => "brand_new", "message" => "Boom"}}}]

      log = capture_log(fn -> fn -> StreamFailure.split(events, provider) end |> Task.async() |> Task.await() end)
      assert log =~ ~s(#{provider} reported a stream error with code "brand_new")

      log = capture_log(fn -> StreamFailure.split(events, provider) end)
      refute log =~ "#{provider} reported"
    end

    test "the table stops growing when it is full" do
      table = :ets.new(:warned, [:set, :public])

      assert StreamFailure.remember(table, {:openai, {"code", "a"}}, 2)
      refute StreamFailure.remember(table, {:openai, {"code", "a"}}, 2)
      assert StreamFailure.remember(table, {:anthropic, {"code", "a"}}, 2)
      refute StreamFailure.remember(table, {:openai, {"code", "b"}}, 2)
      assert :ets.info(table, :size) == 2
    end
  end

  defp chat_completions_model(body) do
    BeamWeaver.Models.init_chat_model!("openai:gpt-4.1",
      api: :chat_completions,
      api_key: "k",
      transport: SSE,
      transport_opts: [body: body]
    )
  end

  defp undocumented(code) do
    encode([
      %{
        "id" => "chatcmpl_1",
        "model" => "m",
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => "It shipped on"}}]
      },
      %{"error" => %{"message" => "Try again, Ada.", "type" => code, "param" => nil, "code" => nil}}
    ])
  end

  # The error the same failure gets without streaming: the provider's HTTP
  # error with the status the error names, which can be retried.
  defp assert_failure(error, status) do
    assert %Error{type: :server_error, message: "The model is overloaded."} = error
    assert error.details.status == status
    assert error.details.retryable
  end

  defp responses(terminal) do
    item = %{"id" => "msg_1", "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}
    text = %{"type" => "output_text", "text" => "It shipped on", "annotations" => []}

    response = %{
      "id" => "resp_1",
      "object" => "response",
      "model" => "gpt-4.1",
      "status" => "in_progress",
      "output" => [],
      "usage" => %{"input_tokens" => 9, "output_tokens" => 3, "total_tokens" => 12}
    }

    last =
      case terminal do
        :failed ->
          %{
            "type" => "response.failed",
            "response" =>
              %{
                response
                | "status" => "failed",
                  "output" => []
              }
              |> Map.put("error", %{"code" => "server_error", "message" => "The model failed to generate a response."})
          }

        :incomplete ->
          %{
            "type" => "response.incomplete",
            "response" =>
              %{
                response
                | "status" => "incomplete",
                  "output" => [%{item | "status" => "incomplete", "content" => [text]}]
              }
              |> Map.put("incomplete_details", %{"reason" => "max_output_tokens"})
          }
      end

    encode([
      %{"type" => "response.created", "response" => response},
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => item},
      %{
        "type" => "response.content_part.added",
        "item_id" => "msg_1",
        "output_index" => 0,
        "content_index" => 0,
        "part" => %{"type" => "output_text", "text" => ""}
      },
      %{
        "type" => "response.output_text.delta",
        "item_id" => "msg_1",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => "It shipped on"
      },
      last
    ])
  end

  defp cut_off(:responses) do
    item = %{"id" => "msg_1", "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}

    encode([
      %{"type" => "response.created", "response" => %{"id" => "resp_1", "status" => "in_progress", "output" => []}},
      %{"type" => "response.output_item.added", "output_index" => 0, "item" => item},
      %{
        "type" => "response.content_part.added",
        "item_id" => "msg_1",
        "output_index" => 0,
        "content_index" => 0,
        "part" => %{"type" => "output_text", "text" => ""}
      },
      %{
        "type" => "response.output_text.delta",
        "item_id" => "msg_1",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => "It shipped on"
      },
      %{"type" => "error", "code" => "server_error", "message" => "The model is overloaded.", "param" => nil}
    ])
  end

  defp cut_off(:chat_completions) do
    encode([
      %{
        "id" => "chatcmpl_1",
        "model" => "m",
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => "It shipped on"}}]
      },
      %{"error" => %{"message" => "The model is overloaded.", "type" => "server_error", "param" => nil, "code" => nil}}
    ])
  end

  defp cut_off(:gemini) do
    encode([
      %{
        "candidates" => [%{"index" => 0, "content" => %{"role" => "model", "parts" => [%{"text" => "It shipped on"}]}}]
      },
      %{"error" => %{"code" => 503, "message" => "The model is overloaded.", "status" => "UNAVAILABLE"}}
    ])
  end

  defp encode(events) do
    Enum.map_join(events, fn
      %{"type" => type} = data -> "event: #{type}\ndata: #{BeamWeaver.JSON.encode!(data)}\n\n"
      data -> "data: #{BeamWeaver.JSON.encode!(data)}\n\n"
    end)
  end
end
