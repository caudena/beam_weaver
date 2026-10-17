defmodule BeamWeaver.OpenAI.ModerationMiddlewareTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Core.Message
  alias BeamWeaver.OpenAI
  alias BeamWeaver.OpenAI.ModerationMiddleware

  @ok_result %{
    "flagged" => false,
    "categories" => %{"self-harm" => false},
    "category_scores" => %{"self-harm" => 0.0}
  }

  @flagged_result %{
    "flagged" => true,
    "categories" => %{"self-harm" => true},
    "category_scores" => %{"self-harm" => 0.9}
  }

  test "before_model allows clean input" do
    middleware = middleware_for("hello", @ok_result)

    assert Middleware.call_hook(
             middleware,
             :before_model,
             %{messages: [Message.user("hello")]},
             runtime()
           ) ==
             nil
  end

  test "before_model returns tagged error for flagged input when configured" do
    middleware = middleware_for("bad", @flagged_result, exit_behavior: :error)

    assert {:error, error} =
             Middleware.call_hook(
               middleware,
               :before_model,
               %{messages: [Message.user("bad")]},
               runtime()
             )

    assert error.type == :openai_moderation_violation
    assert error.details.stage == :input
    assert error.details.result["flagged"] == true
  end

  test "before_model jumps to end for flagged input" do
    middleware = middleware_for("bad", @flagged_result, exit_behavior: :end)

    assert {:jump, :end, %{messages: [%Message{role: :assistant} = message]}} =
             Middleware.call_hook(
               middleware,
               :before_model,
               %{messages: [Message.user("bad")]},
               runtime()
             )

    assert message.content =~ "flagged"
    assert message.content =~ "self harm"
  end

  test "custom violation template supports categories" do
    middleware =
      middleware_for("bad", @flagged_result,
        exit_behavior: :end,
        violation_message: "Policy block: {categories}"
      )

    assert {:jump, :end, %{messages: [%Message{content: "Policy block: self harm"}]}} =
             Middleware.call_hook(
               middleware,
               :before_model,
               %{messages: [Message.user("bad")]},
               runtime()
             )
  end

  test "after_model replaces flagged assistant message without dropping metadata" do
    middleware = middleware_for("unsafe", @flagged_result, exit_behavior: :replace)
    message = Message.assistant("unsafe", id: "ai-1", metadata: %{trace: "kept"})

    assert %{messages: [%Message{} = updated]} =
             Middleware.call_hook(middleware, :after_model, %{messages: [message]}, runtime())

    assert updated.id == "ai-1"
    assert updated.metadata == %{trace: "kept"}
    assert updated.content =~ "flagged"
  end

  test "tool messages are moderated after the last assistant message when enabled" do
    middleware =
      middleware_for("dangerous", @flagged_result,
        check_input: false,
        check_tool_results: true,
        exit_behavior: :replace
      )

    messages = [
      Message.user("question"),
      Message.assistant("call tool"),
      Message.tool("dangerous", tool_call_id: "tool-1")
    ]

    assert %{messages: updated_messages} =
             Middleware.call_hook(middleware, :before_model, %{messages: messages}, runtime())

    assert %Message{role: :tool, tool_call_id: "tool-1"} = List.last(updated_messages)
    assert List.last(updated_messages).content =~ "flagged"
  end

  test "before_model callback jumps to end when invoked directly" do
    middleware = middleware_for("async", @flagged_result, exit_behavior: :end)

    assert {:jump, :end, %{messages: [%Message{role: :assistant}]}} =
             ModerationMiddleware.before_model(middleware, %{messages: [Message.user("async")]}, runtime())
  end

  test "OpenAI namespace builds moderation middleware with provider options" do
    middleware =
      OpenAI.moderation_middleware(
        model: "test",
        api_key: "sk-test",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{
            method: :post,
            path: "/moderations",
            json: %{"model" => "test", "input" => "hello"}
          },
          body: %{"results" => [@ok_result]}
        ]
      )

    assert middleware.model == "test"

    assert nil ==
             ModerationMiddleware.before_model(
               middleware,
               %{messages: [Message.user("hello")]},
               runtime()
             )
  end

  test "a failed moderation request returns the client's error" do
    missing_key =
      ModerationMiddleware.new(
        api_key: nil,
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [parent: self()]
      )

    assert {:error, %BeamWeaver.Core.Error{type: :missing_api_key}} =
             ModerationMiddleware.moderate(missing_key, "hello")

    refute_received {:fake_transport_request, _request}

    rate_limited =
      middleware_for("hello", @ok_result,
        transport_opts: [status: 429, body: %{"error" => %{"message" => "Rate limit reached", "type" => "requests"}}]
      )

    assert {:error, %BeamWeaver.Core.Error{type: :rate_limit, message: "Rate limit reached", details: %{status: 429}}} =
             ModerationMiddleware.moderate(rate_limited, "hello")

    # The middleware passes the error on.
    assert {:error, %BeamWeaver.Core.Error{type: :missing_api_key}} =
             Middleware.call_hook(missing_key, :before_model, %{messages: [Message.user("hello")]}, runtime())
  end

  defp middleware_for(text, result, opts \\ []) do
    ModerationMiddleware.new(
      Keyword.merge(
        [
          model: "test",
          api_key: "sk-test",
          transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
          transport_opts: [
            expect: %{
              method: :post,
              path: "/moderations",
              json: %{"model" => "test", "input" => text}
            },
            body: %{"results" => [result]}
          ]
        ],
        opts
      )
    )
  end

  defp runtime, do: %BeamWeaver.Graph.Runtime{}
end
