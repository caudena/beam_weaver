defmodule BeamWeaver.Provider.OutcomeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Provider.Outcome
  alias BeamWeaver.Transport.Response

  # Answers every request with the same 200 body.
  defmodule Reply do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(_request, opts) do
      {content_type, body} =
        case Keyword.fetch!(opts, :reply) do
          {:sse, body} -> {"text/event-stream", body}
          json -> {"application/json", BeamWeaver.JSON.encode!(json)}
        end

      {:ok, Response.new(status: 200, headers: [{"content-type", content_type}], body: body)}
    end
  end

  @filtered "To get around the refund checks, first"

  # OpenAI's content filter can cut a reply short. Chat Completions ends it
  # with the `content_filter` finish reason, the Responses API as
  # `incomplete`, with the filter as the reason.
  describe "a reply the content filter cut off" do
    test "is filtered on both OpenAI APIs" do
      assert %Outcome{remote_status: :incomplete, turn_disposition: :filtered, result_completeness: :partial} =
               :responses |> invoke(responses_reply("content_filter")) |> Outcome.classify()

      chat_completion = %{
        "id" => "chatcmpl_1",
        "object" => "chat.completion",
        "model" => "gpt-4.1",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => @filtered},
            "finish_reason" => "content_filter"
          }
        ]
      }

      assert %Outcome{remote_status: :completed, turn_disposition: :filtered, result_completeness: :partial} =
               :chat_completions |> invoke(chat_completion) |> Outcome.classify()
    end

    test "is filtered when the Responses API streamed it" do
      reply =
        "openai:gpt-4.1" |> model(:responses, {:sse, incomplete_stream(responses_reply("content_filter"))}) |> stream()

      assert %Outcome{turn_disposition: :filtered} = Outcome.classify(reply)
    end

    test "a Responses API reply cut off at its output cap is an output limit" do
      assert %Outcome{remote_status: :incomplete, turn_disposition: :output_limit} =
               :responses |> invoke(responses_reply("max_output_tokens")) |> Outcome.classify()
    end
  end

  # xAI's Responses API ends a reply it cut short as `incomplete`, with the
  # limit the reply reached: the output cap, the prompt limit or the time
  # limit.
  describe "an xAI reply cut off at a limit" do
    for {reason, disposition} <- [
          max_output_tokens: :output_limit,
          max_prompt_tokens: :context_limit,
          max_time_limit: :budget_exhausted
        ] do
      test "#{reason} is #{inspect(disposition)}, streamed or not" do
        response = xai_reply(unquote(Atom.to_string(reason)))
        streamed = {:sse, incomplete_stream(response)}

        outcome = %Outcome{
          remote_status: :incomplete,
          turn_disposition: unquote(disposition),
          result_completeness: :partial
        }

        assert "xai:grok-4.6" |> model(:responses, response) |> invoke() |> Outcome.classify() == outcome
        assert "xai:grok-4.6" |> model(:responses, streamed) |> stream() |> Outcome.classify() == outcome
      end
    end
  end

  # Stop reasons providers document for a reply they ended early, in a
  # normal response.
  describe "a documented stop reason" do
    test "Anthropic's refusal is a refusal" do
      assert %Outcome{remote_status: :completed, turn_disposition: :refusal, result_completeness: :partial} =
               "anthropic:claude-haiku-4-5" |> model(anthropic_reply("refusal")) |> invoke() |> Outcome.classify()
    end

    test "Anthropic's and Z.ai's model_context_window_exceeded is a context limit" do
      outcome = %Outcome{remote_status: :incomplete, turn_disposition: :context_limit, result_completeness: :partial}

      for {id, reply} <- [
            {"anthropic:claude-haiku-4-5", anthropic_reply("model_context_window_exceeded")},
            {"zai:glm-5.2", chat_completions_reply("model_context_window_exceeded")}
          ] do
        assert id |> model(reply) |> invoke() |> Outcome.classify() == outcome
      end
    end

    for reason <-
          ~w(SAFETY RECITATION BLOCKLIST PROHIBITED_CONTENT SPII IMAGE_SAFETY IMAGE_PROHIBITED_CONTENT IMAGE_RECITATION) do
      test "Gemini's #{reason} is filtered" do
        assert %Outcome{turn_disposition: :filtered, result_completeness: :partial} =
                 "google:gemini-3.5-flash" |> model(gemini_reply(unquote(reason))) |> invoke() |> Outcome.classify()
      end
    end

    test "Gemini's STOP is a final output" do
      assert %Outcome{turn_disposition: :final_output} =
               "google:gemini-3.5-flash" |> model(gemini_reply("STOP")) |> invoke() |> Outcome.classify()
    end
  end

  defp invoke(api, reply), do: "openai:gpt-4.1" |> model(api, reply) |> invoke()

  defp invoke(model) do
    assert {:ok, %Message{} = message} = ChatModel.invoke(model, "How do I skip the refund checks?")
    message
  end

  defp stream(model) do
    assert {:ok, %Message{} = message} = model.__struct__.stream_response(model, [Message.user("Skip the checks?")])
    message
  end

  defp model(id, api, reply),
    do: BeamWeaver.Models.init_chat_model!(id, api: api, api_key: "k", transport: Reply, transport_opts: [reply: reply])

  defp model(id, reply),
    do: BeamWeaver.Models.init_chat_model!(id, api_key: "k", transport: Reply, transport_opts: [reply: reply])

  defp anthropic_reply(stop_reason) do
    %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5",
      "content" => [%{"type" => "text", "text" => @filtered}],
      "stop_reason" => stop_reason,
      "stop_sequence" => nil,
      "usage" => %{"input_tokens" => 12, "output_tokens" => 8}
    }
  end

  defp chat_completions_reply(finish_reason) do
    %{
      "id" => "chatcmpl-1",
      "object" => "chat.completion",
      "created" => 1_760_000_000,
      "model" => "glm-5.2",
      "choices" => [
        %{"index" => 0, "message" => %{"role" => "assistant", "content" => @filtered}, "finish_reason" => finish_reason}
      ],
      "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 8, "total_tokens" => 20}
    }
  end

  defp gemini_reply(finish_reason) do
    %{
      "candidates" => [
        %{
          "content" => %{"role" => "model", "parts" => [%{"text" => @filtered}]},
          "finishReason" => finish_reason,
          "index" => 0
        }
      ],
      "usageMetadata" => %{"promptTokenCount" => 12, "candidatesTokenCount" => 8, "totalTokenCount" => 20},
      "modelVersion" => "gemini-3.5-flash"
    }
  end

  # The events of a Responses stream that ends with `response`, an
  # incomplete reply.
  defp incomplete_stream(response) do
    started = %{response | "status" => "in_progress", "output" => []} |> Map.delete("incomplete_details")

    deltas =
      for %{"id" => item_id, "content" => content} <- response["output"], %{"text" => text} <- content do
        %{"type" => "response.output_text.delta", "item_id" => item_id, "output_index" => 0, "delta" => text}
      end

    Enum.map_join(
      [%{"type" => "response.created", "response" => started}] ++
        deltas ++ [%{"type" => "response.incomplete", "response" => response}],
      &"event: #{&1["type"]}\ndata: #{BeamWeaver.JSON.encode!(&1)}\n\n"
    )
  end

  defp responses_reply(reason) do
    %{
      "id" => "resp_1",
      "object" => "response",
      "model" => "gpt-4.1",
      "status" => "incomplete",
      "incomplete_details" => %{"reason" => reason},
      "output" => [
        %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "status" => "incomplete",
          "content" => [%{"type" => "output_text", "text" => @filtered, "annotations" => []}]
        }
      ]
    }
  end

  # xAI's response ids are UUIDs.
  defp xai_reply(reason) do
    %{
      responses_reply(reason)
      | "id" => "94fa5e70-e18c-9f53-9368-d77dabd2b8a7",
        "model" => "grok-4.6"
    }
  end

  test "classifies final, refusal, filtering, and provider limits" do
    assert %Outcome{remote_status: :completed, turn_disposition: :final_output, result_completeness: :complete} =
             Outcome.classify(Message.assistant("done", status: :completed))

    assert %Outcome{turn_disposition: :refusal, result_completeness: :complete} =
             Outcome.classify(Message.assistant([%{type: :refusal, refusal: "no"}], status: :completed))

    assert %Outcome{turn_disposition: :filtered} =
             Outcome.classify(Message.assistant("", status: :content_filter))

    assert %Outcome{remote_status: :incomplete, turn_disposition: :output_limit, result_completeness: :partial} =
             Outcome.classify(Message.assistant("partial", status: :max_tokens))

    assert %Outcome{remote_status: :incomplete, turn_disposition: :context_limit, result_completeness: :partial} =
             Outcome.classify(
               Message.assistant("",
                 status: :incomplete,
                 response_metadata: %{incomplete_details: %{reason: :context_limit}}
               )
             )

    assert %Outcome{remote_status: :paused, turn_disposition: :provider_pause} =
             Outcome.classify(Message.assistant("partial", status: :pause_turn))
  end

  test "classifies a complete valid tool batch as executable" do
    message =
      Message.assistant("",
        status: :completed,
        tool_calls: [%ToolCall{id: "call-1", name: "search", args: %{"query" => "beam"}}]
      )

    assert %Outcome{
             remote_status: :requires_action,
             turn_disposition: :awaiting_client_tools,
             result_completeness: :complete
           } = Outcome.classify(message)
  end

  test "does not promote queued or in-progress response text to final output" do
    for status <- [:queued, :in_progress] do
      assert %Outcome{
               remote_status: ^status,
               turn_disposition: :no_usable_output,
               result_completeness: :partial
             } = Outcome.classify(Message.assistant("partial", status: status))
    end
  end

  test "empty prompt feedback is not mistaken for a content filter" do
    assert %Outcome{turn_disposition: :final_output} =
             Outcome.classify(Message.assistant("done", response_metadata: %{prompt_feedback: %{}}))

    assert %Outcome{turn_disposition: :final_output} =
             Outcome.classify(
               Message.assistant("done",
                 response_metadata: %{
                   prompt_feedback: %{"blockReason" => "BLOCK_REASON_UNSPECIFIED"}
                 }
               )
             )

    assert %Outcome{turn_disposition: :final_output} =
             Outcome.classify(
               Message.assistant("done",
                 response_metadata: %{prompt_feedback: "BLOCK_REASON_UNSPECIFIED"}
               )
             )

    assert %Outcome{turn_disposition: :filtered} =
             Outcome.classify(Message.assistant("", response_metadata: %{prompt_feedback: %{blockReason: "SAFETY"}}))
  end

  test "one malformed call makes the complete mixed batch non-executable" do
    message =
      Message.assistant("",
        status: :completed,
        tool_calls: [%ToolCall{id: "call-1", name: "search", args: %{"query" => "beam"}}],
        metadata: %{
          invalid_tool_calls: [
            %InvalidToolCall{id: "call-2", name: "read_file", args: "{", error: "invalid JSON"}
          ]
        }
      )

    assert %Outcome{
             remote_status: :completed,
             turn_disposition: :awaiting_client_tools,
             result_completeness: :partial
           } = Outcome.classify(message)
  end
end
