defmodule BeamWeaver.Provider.FailedFinishReasonTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.ModelRetry
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.RetryPredicates
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Transport.Response

  # Answers a streamed request with a Chat Completions event stream that
  # starts the answer and ends with the scripted finish reason, and any other
  # request with the same reply as one JSON response.
  defmodule Scripted do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), :request)
      model = request.json["model"]
      reason = Keyword.fetch!(opts, :finish_reason)

      if request.json["stream"] == true do
        {:ok, Response.new(status: 200, headers: [{"content-type", "text/event-stream"}], body: stream(model, reason))}
      else
        {:ok,
         Response.new(
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: BeamWeaver.JSON.encode!(reply(model, reason))
         )}
      end
    end

    defp stream(model, reason) do
      [
        chunk(model, %{"index" => 0, "delta" => %{"role" => "assistant", "content" => "It shipped on"}}),
        Map.put(chunk(model, %{"index" => 0, "delta" => %{}, "finish_reason" => reason}), "usage", usage())
      ]
      |> Enum.map_join(&"data: #{BeamWeaver.JSON.encode!(&1)}\n\n")
      |> Kernel.<>("data: [DONE]\n\n")
    end

    defp chunk(model, choice),
      do: %{"id" => "chatcmpl_1", "object" => "chat.completion.chunk", "model" => model, "choices" => [choice]}

    defp reply(model, reason) do
      %{
        "id" => "chatcmpl_1",
        "object" => "chat.completion",
        "model" => model,
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "It shipped on"},
            "finish_reason" => reason
          }
        ],
        "usage" => usage()
      }
    end

    defp usage, do: %{"prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15}
  end

  # A finish reason with which the provider reports that it couldn't finish
  # the reply, and the error it stands for.
  @failures [
    {"Z.ai", "zai:glm-5.2", "network_error", :server_error, 500, true},
    {"Z.ai", "zai:glm-5.2", "sensitive", :content_filter, 400, false},
    {"DeepSeek", "deepseek:deepseek-v4-flash", "insufficient_system_resource", :server_error, 503, true},
    {"DeepSeek", "deepseek:deepseek-v4-flash", "aborted", :server_error, 500, true}
  ]

  for {provider, model, reason, type, status, retryable?} <- @failures do
    describe "a #{provider} reply that ends with finish reason #{reason}" do
      @describetag model: model, finish_reason: reason

      test "fails a streamed call with a #{if retryable?, do: "retryable", else: "permanent"} #{type}", context do
        model = model(context)
        user = [Message.user("Where is A-1001?")]

        assert {:error, %Error{} = error} = model.__struct__.stream_response(model, user)

        assert {error.type, error.details.status, error.details.retryable, error.details.code} ==
                 {unquote(type), unquote(status), unquote(retryable?), unquote(reason)}

        assert RetryPredicates.transient?(error) == unquote(retryable?)
        assert error.message =~ "finish_reason: #{unquote(reason)}"

        assert {:ok, events} = ChatModel.stream_typed_events(model, user)
        events = Enum.to_list(events)
        assert [^error] = for(%Envelope{event: %Events.Error{error: error}} <- events, do: error)
        assert ["It shipped on"] = for(%Envelope{event: %Events.Token{text: text}} <- events, do: text)
        refute Enum.any?(events, &match?(%Envelope{event: %Events.Message{}}, &1))
        refute Enum.any?(events, &match?(%Envelope{event: %Events.Done{}}, &1))

        assert {:ok, text} = ChatModel.stream(model, user)
        assert ["It shipped on", %Events.Error{error: ^error}] = Enum.to_list(text)
      end

      test "fails a call without streaming with the same error", context do
        model = model(context)
        user = [Message.user("Where is A-1001?")]

        assert {:error, %Error{} = invoked} = ChatModel.invoke(model, user)
        assert {:error, %Error{} = streamed} = model.__struct__.stream_response(model, user)

        assert {invoked.type, invoked.message, invoked.details.status, invoked.details.retryable} ==
                 {streamed.type, streamed.message, streamed.details.status, streamed.details.retryable}
      end

      test "is #{unless retryable?, do: "not "}retried by ModelRetry in a streaming agent", context do
        assert {{:error, %Error{type: unquote(type)}}, requests} = run_agent(context)
        assert requests == if(unquote(retryable?), do: 3, else: 1)
      end
    end
  end

  # Finish reasons that end a reply the provider documents as complete: a
  # limit was reached, or OpenAI's and DeepSeek's content filter left content
  # out. The reply is kept with its finish reason as `status`.
  @normal [
    {"Z.ai", "zai:glm-5.2", [], "length"},
    {"Z.ai", "zai:glm-5.2", [], "model_context_window_exceeded"},
    {"DeepSeek", "deepseek:deepseek-v4-flash", [], "content_filter"},
    {"OpenAI Chat Completions", "openai:gpt-4.1", [api: :chat_completions], "content_filter"}
  ]

  for {provider, model, opts, reason} <- @normal do
    @tag model: model, opts: opts, finish_reason: reason
    test "a #{provider} reply that ends with finish reason #{reason} is a reply, with or without streaming", context do
      model = model(context)
      user = [Message.user("Where is A-1001?")]

      assert {:ok, %Message{} = invoked} = ChatModel.invoke(model, user)
      assert {:ok, %Message{} = streamed} = model.__struct__.stream_response(model, user)

      for message <- [invoked, streamed] do
        assert Message.text(message) == "It shipped on"
        assert message.status == unquote(reason)
        assert message.response_metadata.finish_reason == unquote(reason)
      end

      assert {:ok, events} = ChatModel.stream_typed_events(model, user)
      events = Enum.to_list(events)
      refute Enum.any?(events, &match?(%Envelope{event: %Events.Error{}}, &1))
      assert [%Message{status: unquote(reason)}] = for(%Envelope{event: %Events.Message{message: m}} <- events, do: m)
    end
  end

  # Runs a streaming agent with `ModelRetry` (two retries) on the model, and
  # counts its requests.
  defp run_agent(context) do
    {:ok, agent} =
      BeamWeaver.Agent.build(
        name: "orders",
        model: context.model,
        model_opts: [stream: true] ++ model_opts(context),
        middleware: [{ModelRetry, max_retries: 2}]
      )

    result = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is A-1001?"]})
    {result, requests()}
  end

  defp model(context), do: BeamWeaver.Models.init_chat_model!(context.model, model_opts(context))

  defp model_opts(context) do
    [
      api_key: "k",
      transport: Scripted,
      transport_opts: [parent: self(), finish_reason: context.finish_reason]
    ] ++ Map.get(context, :opts, [])
  end

  defp requests(count \\ 0) do
    receive do
      :request -> requests(count + 1)
    after
      0 -> count
    end
  end
end
