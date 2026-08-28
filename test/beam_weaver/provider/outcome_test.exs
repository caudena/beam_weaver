defmodule BeamWeaver.Provider.OutcomeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Provider.Outcome

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
