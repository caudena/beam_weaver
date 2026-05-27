defmodule BeamWeaver.Core.ErrorTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error

  test "creates LangChain-style troubleshooting messages from native error codes" do
    assert Error.error_codes().output_parsing_failure == "OUTPUT_PARSING_FAILURE"

    assert Error.create_message("Failed to parse output", :output_parsing_failure) ==
             "Failed to parse output\nFor troubleshooting, visit: https://docs.langchain.com/oss/python/langchain/errors/OUTPUT_PARSING_FAILURE "
  end

  test "output parser errors preserve remediation metadata and validation" do
    assert %Error{
             type: :output_parser,
             message: message,
             details: %{
               observation: "bad JSON",
               llm_output: "{",
               send_to_llm: true
             }
           } =
             Error.output_parser("Failed to parse",
               observation: "bad JSON",
               llm_output: "{",
               send_to_llm: true
             )

    assert message =~ "OUTPUT_PARSING_FAILURE"

    assert {:error, %Error{type: :invalid_output_parser_error}} =
             Error.output_parser("Failed", send_to_llm: true)
  end

  test "context and tracer exceptions map to typed recoverable errors" do
    assert %Error{type: :context_overflow, message: "too many tokens"} =
             Error.context_overflow("too many tokens")

    assert %Error{type: :tracer, details: %{exporter: :test}} =
             Error.tracer("export failed", %{exporter: :test})
  end
end
