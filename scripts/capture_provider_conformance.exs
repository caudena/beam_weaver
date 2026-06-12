Application.ensure_all_started(:ex_unit)
Application.ensure_all_started(:beam_weaver)

Code.require_file(Path.expand("../support/provider_conformance.exs", __DIR__))

alias BeamWeaver.Agent.StructuredOutput
alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.Core.Messages
alias BeamWeaver.TestSupport.ProviderConformance, as: Fixtures

defmodule BeamWeaver.ProviderConformanceCapture do
  @moduledoc false

  @providers [:openai, :xai, :google, :moonshot]

  def run do
    unless System.get_env("BEAM_WEAVER_CAPTURE_PROVIDER_FIXTURES") == "true" do
      Mix.shell().info("""
      Provider fixture capture is disabled.

      Set BEAM_WEAVER_CAPTURE_PROVIDER_FIXTURES=true and the provider API keys to refresh fixtures:

        BEAM_WEAVER_CAPTURE_PROVIDER_FIXTURES=true \\
        OPENAI_API_KEY=... \\
        XAI_API_KEY=... \\
        GOOGLE_API_KEY=... \\
        KIMI_API_KEY=... \\
        mix run scripts/capture_provider_conformance.exs
      """)

      System.halt(0)
    end

    Enum.each(@providers, &capture_provider/1)
  end

  defp capture_provider(provider) do
    case api_key(provider) do
      {:ok, api_key} ->
        Mix.shell().info("Capturing #{provider} provider conformance fixtures...")
        Enum.each(provider_cases(provider), &capture_case(provider, api_key, &1))

      :missing ->
        Mix.shell().info("Skipping #{provider}: API key is not configured.")
    end
  end

  defp capture_case(provider, api_key, {scenario, fun}) do
    scenario_name = Atom.to_string(scenario)
    model = Fixtures.capture_model(provider, scenario_name, api_key: api_key)
    result = fun.(model)
    path = Fixtures.fixture_path(provider, scenario_name)

    Fixtures.put_expected!(path, expected_snapshot(result))
    Mix.shell().info("  wrote #{Path.relative_to_cwd(path)}")
  rescue
    exception ->
      Mix.shell().error("  failed #{provider}/#{scenario}: #{Exception.message(exception)}")
      reraise exception, __STACKTRACE__
  end

  defp provider_cases(:openai) do
    [
      basic_chat: &basic_chat/1,
      multiple_tool_calls: &multiple_tool_calls/1,
      tool_result_followup: &tool_result_followup/1,
      provider_structured_success: &provider_structured_success/1
    ]
  end

  defp provider_cases(:xai) do
    [
      single_tool_call: &single_tool_call/1,
      tool_strategy_structured_success: &tool_strategy_structured_success/1
    ]
  end

  defp provider_cases(:google) do
    [
      basic_chat: &basic_chat/1,
      tool_call: &single_tool_call/1,
      provider_structured_success: &provider_structured_success/1
    ]
  end

  defp provider_cases(:moonshot) do
    [
      basic_chat: &basic_chat/1,
      single_tool_call: &single_tool_call/1,
      provider_structured_success: &provider_structured_success/1,
      streaming_usage: &streaming_usage/1
    ]
  end

  defp basic_chat(model) do
    ChatModel.invoke(model, [Message.user("Reply with exactly: pong")])
  end

  defp single_tool_call(model) do
    ChatModel.invoke(
      model,
      [Message.user("Call get_weather for Tokyo. Do not answer directly.")],
      tools: [Fixtures.weather_tool()]
    )
  end

  defp multiple_tool_calls(model) do
    ChatModel.invoke(
      model,
      [Message.user("Call get_weather once for Paris and once for Berlin. Do not answer directly.")],
      tools: [Fixtures.weather_tool()]
    )
  end

  defp tool_result_followup(model) do
    messages = [
      Message.user("weather in Paris"),
      Message.assistant("",
        tool_calls: [
          Messages.tool_call(
            id: "call_weather_paris",
            provider_id: "fc_weather_paris",
            call_id: "call_weather_paris",
            name: "get_weather",
            args: %{"city" => "Paris"}
          )
        ]
      ),
      Message.tool(%{"condition" => "clear", "temperature" => "18C"},
        tool_call_id: "call_weather_paris",
        name: "get_weather"
      )
    ]

    ChatModel.invoke(model, messages, tools: [Fixtures.weather_tool()])
  end

  defp provider_structured_success(model) do
    ChatModel.invoke(
      model,
      [Message.user("Return a structured answer where answer is exactly pong.")],
      response_format: %{name: "answer_output", schema: Fixtures.answer_schema()}
    )
  end

  defp tool_strategy_structured_success(model) do
    [answer_tool] = StructuredOutput.setup_tools(Fixtures.structured_output(:tool))

    ChatModel.invoke(
      model,
      [Message.user("Call answer_output with answer set to pong. Do not answer directly.")],
      tools: [answer_tool]
    )
  end

  defp streaming_usage(model) do
    model.__struct__.stream_response(model, [Message.user("Reply with exactly: streamed pong")])
  end

  defp expected_snapshot({:ok, %Message{} = message}) do
    %{"message" => Fixtures.message_snapshot(message)}
  end

  defp expected_snapshot({:error, error}) do
    %{"error" => Fixtures.error_snapshot(error)}
  end

  defp api_key(:openai), do: env_key("OPENAI_API_KEY")
  defp api_key(:xai), do: env_key("XAI_API_KEY")
  defp api_key(:google), do: env_key("GOOGLE_API_KEY")
  defp api_key(:moonshot), do: env_key(["KIMI_API_KEY", "MOONSHOT_API_KEY"])

  defp env_key(names) when is_list(names) do
    Enum.find_value(names, :missing, fn name ->
      case env_key(name) do
        {:ok, key} -> {:ok, key}
        :missing -> nil
      end
    end)
  end

  defp env_key(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> :missing
    end
  end
end

BeamWeaver.ProviderConformanceCapture.run()
