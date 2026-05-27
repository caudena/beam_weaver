defmodule BeamWeaver.Agent.LangChainV1CassetteReplayTest do
  use ExUnit.Case, async: true

  # Upstream references:
  # - langchain/libs/langchain_v1/tests/cassettes/test_inference_to_native_output[False].yaml.gz
  # - langchain/libs/langchain_v1/tests/cassettes/test_inference_to_native_output[True].yaml.gz
  # - langchain/libs/langchain_v1/tests/cassettes/test_inference_to_tool_output[False].yaml.gz
  # - langchain/libs/langchain_v1/tests/cassettes/test_inference_to_tool_output[True].yaml.gz
  # - langchain/libs/langchain_v1/tests/cassettes/test_strict_mode[False].yaml.gz
  # - langchain/libs/langchain_v1/tests/cassettes/test_strict_mode[True].yaml.gz

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.OpenAI.ChatCompletions.Messages, as: ChatCompletionsMessages
  alias BeamWeaver.OpenAI.Client
  alias BeamWeaver.OpenAI.Messages, as: ResponsesMessages
  alias BeamWeaver.Transport.Cassette

  @cassette_dir Path.expand("../../../../langchain/libs/langchain_v1/tests/cassettes", __DIR__)

  @chat_completions_cassettes [
    "test_inference_to_native_output[False].yaml.gz",
    "test_inference_to_tool_output[False].yaml.gz",
    "test_strict_mode[False].yaml.gz"
  ]

  @responses_cassettes [
    "test_inference_to_native_output[True].yaml.gz",
    "test_inference_to_tool_output[True].yaml.gz",
    "test_strict_mode[True].yaml.gz"
  ]

  test "replays LangChain v1 chat-completions structured-output cassettes" do
    for cassette_name <- @chat_completions_cassettes do
      path = cassette_path(cassette_name)
      assert {:ok, cassette} = Cassette.load(path)
      assert [first, second] = cassette.interactions

      client = replay_client(path)

      assert {:ok, first_response} =
               Client.chat_completions(client, request_body(first), include_response_headers: false)

      assert {:ok, first_message} = ChatCompletionsMessages.response_to_message(first_response)
      assert [%ToolCall{name: "get_weather"}] = first_message.tool_calls

      assert {:ok, second_response} =
               Client.chat_completions(client, request_body(second), include_response_headers: false)

      assert {:ok, second_message} = ChatCompletionsMessages.response_to_message(second_response)
      assert_structured_weather_result(cassette_name, second_message)
    end
  end

  test "replays LangChain v1 responses structured-output cassettes" do
    for cassette_name <- @responses_cassettes do
      path = cassette_path(cassette_name)
      assert {:ok, cassette} = Cassette.load(path)
      assert [first, second] = cassette.interactions

      client = replay_client(path)

      assert {:ok, first_response} =
               Client.responses(client, request_body(first), include_response_headers: false)

      assert {:ok, first_message} = ResponsesMessages.response_to_message(first_response)
      assert [%ToolCall{name: "get_weather"}] = first_message.tool_calls

      assert {:ok, second_response} =
               Client.responses(client, request_body(second), include_response_headers: false)

      assert {:ok, second_message} = ResponsesMessages.response_to_message(second_response)
      assert_structured_weather_result(cassette_name, second_message)
    end
  end

  defp assert_structured_weather_result(
         "test_inference_to_tool_output" <> _rest,
         %Message{} = message
       ) do
    assert [%ToolCall{name: "WeatherBaseModel", args: arguments}] = message.tool_calls
    assert_weather(arguments)
  end

  defp assert_structured_weather_result(_cassette_name, %Message{} = message) do
    assert {:ok, parsed} = BeamWeaver.JSON.decode(Message.text(message))
    assert_weather(parsed)
  end

  defp assert_weather(%{"temperature" => temperature, "condition" => condition}) do
    assert temperature == 75
    assert String.downcase(condition) == "sunny"
  end

  defp cassette_path(cassette_name), do: Path.join(@cassette_dir, cassette_name)

  defp replay_client(cassette_path) do
    %Client{
      api_key: "sk-replay-test",
      transport: BeamWeaver.Transport.Replay,
      transport_opts: [cassette_path: cassette_path]
    }
  end

  defp request_body(%{request: %{json_body: json}}), do: BeamWeaver.JSON.decode!(json)
end
