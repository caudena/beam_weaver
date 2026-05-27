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
end
