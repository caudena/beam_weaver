defmodule BeamWeaver.DeepSeek.SharedBoundariesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.DeepSeek.Error
  alias BeamWeaver.DeepSeek.ResponsesModel
  alias BeamWeaver.Provider.StructuredOutput

  test "Chat schema contracts validate locally without an explicit validator" do
    schema = %{
      type: :object,
      required: [:answer],
      properties: %{answer: %{type: :string}}
    }

    opts = [response_format: %{type: :json_schema, name: "Answer", schema: schema}]
    parse_opts = [error_module: Error, provider_name: "DeepSeek"]

    assert {:ok, message} =
             StructuredOutput.maybe_parse(Message.assistant(~s({"answer":"pong"})), opts, parse_opts)

    assert message.metadata.parsed == %{"answer" => "pong"}

    assert {:error, %Error{type: :structured_output_parse_error}} =
             StructuredOutput.maybe_parse(Message.assistant(~s({"answer":false})), opts, parse_opts)
  end

  test "Responses serializes typed and returned plain reasoning for full-history replay" do
    typed = Message.assistant([ContentBlock.reasoning("typed chain")])

    assert {:ok, typed_body} = ResponsesModel.request_body(ResponsesModel.new(), [typed])

    assert typed_body["input"] == [
             %{
               "type" => "reasoning",
               "content" => [%{"type" => "reasoning_text", "text" => "typed chain"}]
             }
           ]

    returned =
      Message.assistant([
        %{
          type: :reasoning,
          id: "rs_1",
          summary: [],
          reasoning: "plain chain",
          raw_provider_block: %{
            "type" => "reasoning",
            "id" => "rs_1",
            "summary" => [],
            "content" => [%{"type" => "reasoning_text", "text" => "plain chain"}]
          }
        }
      ])

    assert {:ok, replay_body} = ResponsesModel.request_body(ResponsesModel.new(), [returned])

    assert replay_body["input"] == [
             %{
               "type" => "reasoning",
               "id" => "rs_1",
               "summary" => [],
               "content" => [%{"type" => "reasoning_text", "text" => "plain chain"}]
             }
           ]
  end
end
