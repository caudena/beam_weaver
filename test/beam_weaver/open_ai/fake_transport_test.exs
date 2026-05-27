defmodule BeamWeaver.OpenAI.FakeTransportTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.OpenAI.ChatModel, as: ResponsesModel

  test "fake transport records and matches OpenAI request shape without live calls" do
    model = %ResponsesModel{
      model: "gpt-5.4-mini",
      api_key: "sk-secret-test",
      transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
      transport_opts: [
        parent: self(),
        expect: %{
          method: :post,
          path: "/responses",
          json: %{
            "model" => "gpt-5.4-mini",
            "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
            "stream" => false
          }
        },
        body: %{
          "id" => "resp_fake",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "world"}]
            }
          ],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
        }
      ]
    }

    assert {:ok, %Message{usage_metadata: usage} = response} =
             ChatModel.invoke(model, [Message.user("hello")])

    assert Message.text(response) == "world"
    assert usage == %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
    assert_received {:fake_transport_request, request}
    assert request.url =~ "/responses"
    assert {"authorization", "Bearer sk-secret-test"} in request.headers
  end

  test "fake transport reports redacted request mismatches" do
    model = %ResponsesModel{
      model: "gpt-5.4-mini",
      api_key: "sk-secret-test",
      transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
      transport_opts: [
        expect: %{
          method: :post,
          path: "/responses",
          json: %{"model" => "different", "secret" => "sk-leaked"}
        },
        body: %{"id" => "unused", "output" => []}
      ]
    }

    assert {:error, error} = ChatModel.invoke(model, [Message.user("hello")])
    assert error.type == :transport_error
    assert error.details.reason =~ "fake_transport_mismatch"
    refute error.details.reason =~ "sk-secret-test"
    refute error.details.reason =~ "sk-leaked"
    assert error.details.reason =~ BeamWeaver.Transport.Redactor.redacted()
  end

  test "fake transport supports ordered expectations for repeated calls" do
    {:ok, expectations} =
      Agent.start_link(fn ->
        [
          %{
            method: :post,
            path: "/responses",
            json: %{
              "model" => "gpt-5.4-mini",
              "input" => [%{"type" => "message", "role" => "user", "content" => "first"}],
              "stream" => false
            }
          },
          %{
            method: :post,
            path: "/responses",
            json: %{
              "model" => "gpt-5.4-mini",
              "input" => [%{"type" => "message", "role" => "user", "content" => "second"}],
              "stream" => false
            }
          }
        ]
      end)

    model = %ResponsesModel{
      model: "gpt-5.4-mini",
      api_key: "sk-secret-test",
      transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
      transport_opts: [
        expect: {:ordered, expectations},
        body: %{
          "id" => "resp_fake",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "ok"}]
            }
          ]
        }
      ]
    }

    assert {:ok, first} = ChatModel.invoke(model, [Message.user("first")])
    assert {:ok, second} = ChatModel.invoke(model, [Message.user("second")])
    assert Message.text(first) == "ok"
    assert Message.text(second) == "ok"
    assert Agent.get(expectations, & &1) == []
  end

  test "fake transport mismatch details include missing and extra JSON keys without secrets" do
    model = %ResponsesModel{
      model: "gpt-5.4-mini",
      api_key: "sk-secret-test",
      transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
      transport_opts: [
        expect: %{
          method: :post,
          path: "/responses",
          json: %{
            "model" => "gpt-5.4-mini",
            "stream" => false,
            "required_but_missing" => true
          }
        },
        body: %{"id" => "unused", "output" => []}
      ]
    }

    assert {:error, error} = ChatModel.invoke(model, [Message.user("hello")])
    assert error.type == :transport_error
    assert error.details.reason =~ "required_but_missing"
    assert error.details.reason =~ "input"
    refute error.details.reason =~ "sk-secret-test"
  end

  test "strict profile validation fails before fake transport is called" do
    model = %ResponsesModel{
      model: "gpt-5.4-mini",
      api_key: "sk-secret-test",
      profile: Profile.new(provider: :openai, id: "strict-empty", supported_params: []),
      transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
      transport_opts: [
        parent: self(),
        expect: %{method: :post, path: "/responses"},
        body: %{"id" => "unused", "output" => []}
      ]
    }

    assert {:error, error} =
             ChatModel.invoke(model, [Message.user("hello")], temperature: 0.2)

    assert error.type == :unsupported_model_param
    refute_received {:fake_transport_request, _request}
  end

  test "fake transport can return SSE fixtures as raw bodies" do
    model = %ResponsesModel{
      model: "gpt-5.4-mini",
      api_key: "sk-secret-test",
      transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
      transport_opts: [
        expect: %{
          method: :post,
          path: "/responses",
          json: %{
            "model" => "gpt-5.4-mini",
            "input" => [%{"type" => "message", "role" => "user", "content" => "stream"}],
            "stream" => true
          }
        },
        headers: [{"content-type", "text/event-stream"}],
        body: """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"hi"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_fake","output":[]}}
        """
      ]
    }

    assert {:ok, stream} = ResponsesModel.stream(model, [Message.user("stream")])
    assert Enum.join(stream) == "hi"
  end
end
