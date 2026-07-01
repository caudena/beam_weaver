defmodule BeamWeaver.Provider.ResponseTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Google
  alias BeamWeaver.Provider.Response

  test "separates user tool calls from hosted provider tools" do
    message =
      Message.assistant(
        [
          %{type: :image_generation_call, id: "ig_1", status: "completed", result: "base64-image"},
          %{type: :web_search_call, id: "web_1", status: "completed", action: %{"query" => "beam"}}
        ],
        tool_calls: [
          Messages.tool_call(id: "call_user", name: "lookup", args: %{"q" => "beam"})
        ],
        server_tool_calls: [
          %{
            type: :server_tool_call,
            id: "srv_1",
            name: "code_execution",
            args: %{code: "print(1)"},
            raw_provider_block: %{"large" => "raw"}
          }
        ],
        server_tool_results: [
          %{
            type: :server_tool_result,
            tool_call_id: "srv_1",
            status: "completed",
            output: %{"stdout" => "1"}
          }
        ]
      )

    message = Response.normalize_message(%{model: "gpt-5.5"}, message, provider: :openai)

    tooling = message.response_metadata.tooling

    assert tooling.user.call_count == 1
    assert [%{name: "lookup"}] = tooling.user.calls
    assert tooling.hosted.call_count == 3
    assert tooling.hosted.result_count == 1

    assert %{type: :server_tool_call, id: "srv_1", name: "code_execution"} in tooling.hosted.calls
    assert %{type: :image_generation_call, id: "ig_1", status: "completed"} in tooling.hosted.calls
    assert %{type: :web_search_call, id: "web_1", status: "completed"} in tooling.hosted.calls
    assert %{type: :server_tool_result, tool_call_id: "srv_1", status: "completed"} in tooling.hosted.results

    refute Enum.any?(tooling.hosted.calls, &Map.has_key?(&1, :result))
    refute Enum.any?(tooling.hosted.results, &Map.has_key?(&1, :output))
    assert tooling.tool_call_count == 1
    assert tooling.server_tool_call_count == 1
    assert tooling.server_tool_result_count == 1
  end

  test "normalizes OpenAI hosted tool usage from raw provider response" do
    message =
      Message.assistant("done",
        response_metadata: %{
          raw_provider_response: %{
            "tool_usage" => %{
              "image_gen" => %{
                "input_tokens" => 10,
                "output_tokens" => 20,
                "total_tokens" => 30,
                "input_tokens_details" => %{"image_tokens" => 7, "text_tokens" => 3},
                "output_tokens_details" => %{"image_tokens" => 20}
              },
              "web_search" => %{"num_requests" => 2}
            }
          }
        }
      )

    message = Response.normalize_message(%{model: "gpt-5.5"}, message, provider: :openai)

    assert message.response_metadata.tooling.hosted.usage == %{
             image_gen: %{
               input_tokens: 10,
               output_tokens: 20,
               total_tokens: 30,
               input_token_details: %{image_tokens: 7, text_tokens: 3},
               output_token_details: %{image_tokens: 20}
             },
             web_search: %{num_requests: 2}
           }
  end

  test "preserves Google thought signatures on text and reasoning parts" do
    response = %{
      "responseId" => "resp_google",
      "modelVersion" => "gemini-3.5-flash",
      "candidates" => [
        %{
          "finishReason" => "STOP",
          "content" => %{
            "parts" => [
              %{"text" => "reasoning", "thought" => true, "thoughtSignature" => "sig-reasoning"},
              %{"text" => "answer", "thoughtSignature" => "sig-text"}
            ]
          }
        }
      ],
      "usageMetadata" => %{"promptTokenCount" => 1, "thoughtsTokenCount" => 2}
    }

    assert {:ok, message} = Google.Messages.response_to_message(response)

    assert [
             %{type: :reasoning, metadata: %{thought_signature: "sig-reasoning"}},
             %{type: :text, thought_signature: "sig-text"}
           ] = message.content

    message = Response.normalize_message(%{model: "gemini-3.5-flash"}, message, provider: :google)

    assert message.response_metadata.reasoning.thought_signatures == ["sig-reasoning", "sig-text"]
  end
end
