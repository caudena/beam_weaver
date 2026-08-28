defmodule BeamWeaver.OpenAI.CodexResponsesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.OpenAI.CodexResponses

  test "builds the Codex first-party compatibility headers from a JWT" do
    token = jwt(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct-test"}})
    headers = Map.new(CodexResponses.headers(token, user_agent: "codex_cli_rs/harness-0.1"))

    assert headers["originator"] == "codex_cli_rs"
    assert headers["user-agent"] == "codex_cli_rs/harness-0.1"
    assert headers["ChatGPT-Account-ID"] == "acct-test"
  end

  test "malformed tokens never create an account header" do
    headers = Map.new(CodexResponses.headers("not-a-jwt", user_agent: "other/1"))
    assert headers == %{"originator" => "codex_cli_rs", "user-agent" => "codex_cli_rs/beam_weaver"}
  end

  test "omits Responses API limits rejected by the Codex subscription endpoint" do
    options = CodexResponses.request_options(max_output_tokens: 4_096, max_tool_calls: 1)

    refute Keyword.has_key?(options, :max_output_tokens)
    refute Keyword.has_key?(options, :max_tool_calls)
  end

  test "normalizes a bounded non-stored request and omits empty tools" do
    assert {:ok, body} =
             CodexResponses.normalize_body(%{
               "model" => "gpt-test",
               "input" => [],
               "max_output_tokens" => 4_096,
               "max_tool_calls" => 1,
               "store" => true,
               "tools" => []
             })

    assert body["store"] == false
    assert body["include"] == ["reasoning.encrypted_content"]
    refute Map.has_key?(body, "tools")
    refute Map.has_key?(body, "max_output_tokens")
    refute Map.has_key?(body, "max_tool_calls")

    assert {:error, :codex_request_too_large} =
             CodexResponses.normalize_body(%{"input" => String.duplicate("x", 20)},
               maximum_body_bytes: 10
             )

    assert {:error, :invalid_codex_request} =
             CodexResponses.normalize_body(%{"input" => []}, maximum_body_bytes: "unbounded")
  end

  test "normalizes controlled atom keys without leaving duplicate wire parameters" do
    assert {:ok, body} =
             CodexResponses.normalize_body(%{
               input: [],
               store: true,
               include: ["custom.include"],
               tools: [],
               max_output_tokens: 4_096,
               max_tool_calls: 1
             })

    assert body["store"] == false
    assert body["include"] == ["custom.include"]
    refute Map.has_key?(body, :store)
    refute Map.has_key?(body, :include)
    refute Map.has_key?(body, :tools)
    refute Map.has_key?(body, :max_output_tokens)
    refute Map.has_key?(body, :max_tool_calls)
    refute Map.has_key?(body, "tools")
  end

  defp jwt(claims) do
    encoded = fn value ->
      value |> Jason.encode!() |> Base.url_encode64(padding: false)
    end

    encoded.(%{"alg" => "none"}) <> "." <> encoded.(claims) <> ".signature"
  end
end
