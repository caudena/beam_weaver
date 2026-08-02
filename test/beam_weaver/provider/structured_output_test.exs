defmodule BeamWeaver.Provider.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Google
  alias BeamWeaver.Moonshot
  alias BeamWeaver.OpenAI
  alias BeamWeaver.Provider.StructuredOutput
  alias BeamWeaver.XAI

  test "strict providers return structured output parse errors for invalid JSON" do
    message = Message.assistant("not json")
    opts = [response_format: %{type: :json_object}]

    assert {:error, %OpenAI.Error{type: :structured_output_parse_error}} =
             StructuredOutput.maybe_parse(message, opts,
               error_module: OpenAI.Error,
               provider_name: "OpenAI"
             )

    assert {:error, %XAI.Error{type: :structured_output_parse_error}} =
             StructuredOutput.maybe_parse(message, opts,
               error_module: XAI.Error,
               provider_name: "xAI"
             )

    assert {:error, %Moonshot.Error{type: :structured_output_parse_error}} =
             StructuredOutput.maybe_parse(message, opts,
               error_module: Moonshot.Error,
               provider_name: "Moonshot"
             )
  end

  test "tolerant providers keep the original message on invalid JSON" do
    message = Message.assistant("not json")
    opts = [response_format: %{schema: %{type: :object}}]

    assert {:ok, ^message} =
             StructuredOutput.maybe_parse(message, opts,
               error_module: Anthropic.Error,
               provider_name: "Anthropic",
               on_decode_error: :ok
             )

    assert {:ok, ^message} =
             StructuredOutput.parse(message, StructuredOutput.parser(opts),
               error_module: Google.Error,
               provider_name: "Google",
               on_decode_error: :ok
             )
  end

  test "derives local validation from schema-shaped response formats" do
    schema = %{
      type: :object,
      required: [:answer],
      properties: %{
        answer: %{type: :string, enum: [:pong]}
      }
    }

    formats = [
      %{name: "Answer", schema: schema},
      %{"type" => "json_schema", "json_schema" => %{"name" => "Answer", "schema" => schema}},
      {"Answer", schema},
      schema
    ]

    for format <- formats do
      assert {:ok, parsed_message} =
               StructuredOutput.maybe_parse(
                 Message.assistant(~s({"answer":"pong"})),
                 [response_format: format],
                 error_module: OpenAI.Error,
                 provider_name: "OpenAI"
               )

      assert parsed_message.metadata.parsed == %{"answer" => "pong"}
    end

    for invalid_json_object <- [~s({"answer":42}), ~s({}), ~s([])] do
      assert {:error, %OpenAI.Error{type: :structured_output_parse_error}} =
               StructuredOutput.maybe_parse(
                 Message.assistant(invalid_json_object),
                 [response_format: %{name: "Answer", schema: schema}],
                 error_module: OpenAI.Error,
                 provider_name: "OpenAI"
               )
    end
  end

  test "truncated structured output reports finish reason without storing the full response" do
    message =
      Message.assistant(String.duplicate("{", 10_000),
        status: "MAX_TOKENS",
        metadata: %{finish_reason: "MAX_TOKENS"}
      )

    assert {:error, %Google.Error{} = error} =
             StructuredOutput.parse(message, nil,
               error_module: Google.Error,
               provider_name: "Google"
             )

    assert error.type == :structured_output_parse_error
    assert error.message == "Google structured output was truncated before valid JSON"
    assert error.details.finish_reason == "max_tokens"
    assert error.details.response.content_length == 10_000
    assert byte_size(error.details.response.content_preview) < 5_000
  end

  test "truncated structured output detects OpenAI incomplete details with string keys" do
    message =
      Message.assistant("",
        status: "incomplete",
        response_metadata: %{
          "status" => "incomplete",
          "incomplete_details" => %{"reason" => "max_output_tokens"},
          "raw_provider_response" => %{
            "output" => List.duplicate(%{"text" => String.duplicate("x", 500)}, 50)
          }
        }
      )

    assert {:error, %Google.Error{} = error} =
             StructuredOutput.parse(message, nil,
               error_module: Google.Error,
               provider_name: "OpenAI"
             )

    assert error.type == :structured_output_parse_error
    assert error.details.finish_reason == "incomplete"
    assert error.details.response.response_metadata["raw_provider_response"]["output"] |> length() == 20 + 1
  end
end
