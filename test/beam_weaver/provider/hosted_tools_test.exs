defmodule BeamWeaver.Provider.HostedToolsTest do
  use ExUnit.Case, async: true
  alias BeamWeaver.Provider.{HostedTools, Replay}

  test "current hosted defaults include computation and preserve configured future declarations" do
    tools = HostedTools.defaults(:openai, :responses, "gpt-6-astra")
    assert Enum.any?(tools, &(&1["type"] == "code_interpreter"))
    assert Enum.any?(tools, &(&1["type"] == "image_generation"))
    assert Enum.any?(tools, &(&1["type"] == "shell" and &1["environment"]["type"] == "container_auto"))
    future = %{"type" => "future_analysis", "future_setting" => %{"enabled" => true}}
    assert future in HostedTools.merge(tools, [future])
    replacement = %{"type" => "web_search", "filters" => %{"allowed_domains" => ["example.com"]}}
    merged = HostedTools.merge(tools, [replacement])
    assert Enum.filter(merged, &(&1["type"] == "web_search")) == [replacement]
  end

  test "raw future declarations survive each provider renderer" do
    future = %{"type" => "future_analysis_20300101", "name" => "future_analysis", "settings" => %{"enabled" => true}}
    assert [^future] = BeamWeaver.OpenAI.ToolCalling.to_openai_tools([future])
    assert [^future] = BeamWeaver.Anthropic.Tools.to_anthropic_tools([future])
    assert [^future] = BeamWeaver.XAI.Tools.to_responses_tools([future])
    assert :ok = BeamWeaver.XAI.Tools.validate_responses_tools([future])
    assert :ok = BeamWeaver.DeepSeek.Tools.validate_responses_tools([future])
    assert [^future] = BeamWeaver.ZAI.Tools.to_chat_tools([future])
    assert :ok = BeamWeaver.ZAI.Tools.validate_chat_tools([future])
    google = %{"futureAnalysis" => %{"enabled" => true}}
    assert {:ok, [^google]} = BeamWeaver.Google.Tools.render_tools([google], [])
  end

  test "OpenAI hosted output, future fields and local calls retain exact order through replay" do
    native = %{"type" => "future_analysis_call", "id" => "future-1", "result" => %{"enabled" => true, "score" => 0.25}}
    local = %{"type" => "function_call", "id" => "fc-1", "call_id" => "call-1", "name" => "lookup", "arguments" => "{}"}
    response = %{"id" => "resp-1", "status" => "completed", "output" => [native, local]}
    assert {:ok, message} = BeamWeaver.OpenAI.Messages.response_to_message(response)
    assert length(message.tool_calls) == 1
    binding = %{provider: "openai", dialect: "responses"}
    assert {:ok, projected} = Replay.project(message, binding)
    assert {:ok, restored} = projected |> Jason.encode!() |> Jason.decode!() |> Replay.restore(binding)
    assert {:ok, [^native, replayed_call]} = BeamWeaver.OpenAI.Messages.to_responses_input([restored], store: false)
    assert replayed_call == Map.delete(local, "id")
  end

  test "Claude server pause retains calls, results, future blocks and container" do
    content = [
      %{"type" => "server_tool_use", "id" => "srv-1", "name" => "code_execution", "input" => %{"code" => "1+1"}},
      %{
        "type" => "code_execution_tool_result",
        "tool_use_id" => "srv-1",
        "content" => %{"type" => "code_execution_result", "stdout" => "2", "stderr" => "", "return_code" => 0}
      },
      %{"type" => "future_tool_result", "tool_use_id" => "future-1", "content" => [%{"enabled" => true}]}
    ]

    response = %{
      "id" => "msg-1",
      "type" => "message",
      "role" => "assistant",
      "stop_reason" => "pause_turn",
      "container" => %{"id" => "container-1"},
      "content" => content,
      "usage" => %{}
    }

    assert {:ok, message} = BeamWeaver.Anthropic.Messages.response_to_message(response)
    assert message.tool_calls == []
    binding = %{provider: "anthropic", dialect: "messages"}
    assert {:ok, projected} = Replay.project(message, binding)
    assert {:ok, restored} = projected |> Jason.encode!() |> Jason.decode!() |> Replay.restore(binding)
    assert restored.response_metadata.container == %{"id" => "container-1"}
    assert {:ok, {_, [%{"content" => ^content}]}} = BeamWeaver.Anthropic.Messages.format_messages([restored])
  end

  test "Gemini computation and thought signatures remain in native context circulation" do
    parts = [
      %{"executableCode" => %{"language" => "PYTHON", "code" => "print(2)"}, "thoughtSignature" => "opaque-signature"},
      %{"codeExecutionResult" => %{"outcome" => "OUTCOME_OK", "output" => "2"}},
      %{"functionCall" => %{"id" => "fc-1", "name" => "lookup", "args" => %{}}}
    ]

    response = %{"candidates" => [%{"content" => %{"role" => "model", "parts" => parts}, "finishReason" => "STOP"}]}
    assert {:ok, message} = BeamWeaver.Google.Messages.response_to_message(response)
    binding = %{provider: "google", dialect: "generate_content"}
    assert {:ok, projected} = Replay.project(message, binding)
    assert {:ok, restored} = projected |> Jason.encode!() |> Jason.decode!() |> Replay.restore(binding)
    assert {:ok, {_, [%{"parts" => ^parts}]}} = BeamWeaver.Google.Messages.encode_messages([restored])
  end
end
