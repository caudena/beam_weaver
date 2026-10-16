defmodule BeamWeaver.Provider.CallOptionsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models

  @messages [Message.user("Where is my order A-1001?")]

  test "every provider rejects a call option its model doesn't take" do
    for {id, opts, param} <- [
          {"openai:gpt-5.4-mini", [top_k: 5], :top_k},
          {"openai:gpt-5.4-mini", [stop: ["END"]], :stop},
          {"anthropic:claude-haiku-4-5", [reasoning_effort: :low], :reasoning_effort},
          {"google:gemini-3.5-flash", [reasoning_effort: :low], :reasoning_effort},
          {"xai:grok-4.6", [top_k: 5], :top_k},
          {"moonshot:kimi-k2.6", [top_k: 5], :top_k},
          {"zai:glm-5.2", [top_k: 5], :top_k},
          {"deepseek:deepseek-v4-flash", [top_k: 5], :top_k}
        ] do
      model = Models.init_chat_model!(id)

      assert {:error, %Error{type: :unsupported_model_param, details: %{params: params}}} =
               model.__struct__.request_body(model, @messages, opts),
             "#{id} took #{inspect(opts)}"

      assert param in params
    end
  end

  test "Anthropic and Google take the common names for the output cap on a call" do
    anthropic = Models.init_chat_model!("anthropic:claude-haiku-4-5")

    assert {:ok, %{"max_tokens" => 100}} =
             anthropic.__struct__.request_body(anthropic, @messages, max_output_tokens: 100)

    google = Models.init_chat_model!("google:gemini-3.5-flash")
    assert {:ok, body} = google.__struct__.request_body(google, @messages, max_tokens: 100)
    assert body["generationConfig"]["maxOutputTokens"] == 100
  end

  test "a bare tool name as tool_choice forces that function on OpenAI-compatible APIs" do
    tool =
      BeamWeaver.Core.Tool.from_function!(
        name: "lookup_order",
        description: "Look up an order.",
        input_schema: %{type: :object, properties: %{order_id: %{type: :string}}},
        handler: fn _args, _opts -> "shipped" end
      )

    responses = Models.init_chat_model!("openai:gpt-5.4-mini")

    for {choice, expected} <- [
          {"lookup_order", %{"type" => "function", "name" => "lookup_order"}},
          {:lookup_order, %{"type" => "function", "name" => "lookup_order"}},
          {%{type: :function, function: %{name: "lookup_order"}}, %{"type" => "function", "name" => "lookup_order"}},
          {:required, "required"},
          {:any, "required"},
          {:auto, "auto"}
        ] do
      assert {:ok, %{"tool_choice" => ^expected}} =
               responses.__struct__.request_body(responses, @messages, tools: [tool], tool_choice: choice)
    end

    for id <- ["openai:gpt-5.4-mini", "xai:grok-4.20-0309-non-reasoning"] do
      model = Models.init_chat_model!(id, api: :chat_completions)

      assert {:ok, %{"tool_choice" => %{"type" => "function", "function" => %{"name" => "lookup_order"}}}} =
               model.__struct__.request_body(model, @messages, tools: [tool], tool_choice: "lookup_order")
    end

    kimi = Models.init_chat_model!("moonshot:kimi-k2.6", thinking: %{type: :disabled})

    assert {:ok, %{"tool_choice" => %{"type" => "function", "function" => %{"name" => "lookup_order"}}}} =
             kimi.__struct__.request_body(kimi, @messages, tools: [tool], tool_choice: "lookup_order")
  end

  test "a Responses API built-in tool on Chat Completions is an error, not an empty function" do
    for id <- ["openai:gpt-5.4-mini", "xai:grok-4.20-0309-non-reasoning"] do
      model = Models.init_chat_model!(id, api: :chat_completions)

      assert {:error, %Error{type: :unsupported_feature} = error} =
               model.__struct__.request_body(model, @messages, tools: [%{"type" => "web_search_preview"}])

      assert error.message =~ "web_search_preview"
    end

    assert_raise ArgumentError, ~r/web_search_preview/, fn ->
      BeamWeaver.OpenAI.ChatCompletions.Messages.tool_to_openai(%{type: "web_search_preview"})
    end

    assert %{"type" => "function", "function" => %{"name" => "lookup_order"}} =
             BeamWeaver.OpenAI.ChatCompletions.Messages.tool_to_openai(%{type: "function", name: "lookup_order"})
  end

  test "Responses requests return an error for content blocks they can't send" do
    alias BeamWeaver.Core.ContentBlock

    for id <- ["openai:gpt-5.4-mini", "deepseek:deepseek-v4-flash"],
        block <- [
          ContentBlock.video(%{url: "https://example.test/clip.mp4"}),
          ContentBlock.audio(%{url: "https://example.test/clip.mp3"})
        ] do
      opts = if id =~ "deepseek", do: [api: :responses], else: []
      model = Models.init_chat_model!(id, opts)
      messages = [Message.user([ContentBlock.text("What is in this?"), block])]

      assert {:error, %Error{type: :unsupported_feature, details: %{feature: feature}}} =
               model.__struct__.request_body(model, messages, [])

      assert feature == block.type
    end
  end

  test "requests are checked against the profile's efforts, thinking levels and unsupported tools" do
    for {id, opts, effort} <- [
          {"openai:gpt-5.4-mini", [], :max},
          {"openai:gpt-5.4-pro", [], :low},
          {"openai:gpt-5.4-mini", [api: :chat_completions], :max},
          {"xai:grok-4.5", [], :xhigh},
          {"xai:grok-4.5", [api: :chat_completions], :xhigh}
        ] do
      model = Models.init_chat_model!(id, opts)

      assert {:error, %Error{type: :unsupported_model_param, details: %{params: [:reasoning_effort]} = details}} =
               model.__struct__.request_body(model, @messages, reasoning_effort: effort),
             "#{id} #{inspect(opts)} took reasoning_effort #{effort}"

      assert details.value == to_string(effort)
    end

    gpt = Models.init_chat_model!("openai:gpt-5.4-mini")

    assert {:ok, %{"reasoning" => %{"effort" => "xhigh"}}} =
             gpt.__struct__.request_body(gpt, @messages, reasoning_effort: :xhigh)

    gemini = Models.init_chat_model!("google:gemini-3.8-flash")

    assert {:error, %Error{type: :unsupported_model_param, details: %{params: [:thinking_level]}}} =
             gemini.__struct__.request_body(gemini, @messages, thinking_level: :minimal)

    assert {:ok, body} = gemini.__struct__.request_body(gemini, @messages, thinking_level: :low)
    assert body["generationConfig"]["thinkingConfig"]["thinkingLevel"] == :low

    lite = Models.init_chat_model!("google:gemini-3.1-flash-lite")

    assert {:error, %Error{type: :unsupported_feature, details: %{unsupported_tools: [:computer_use]}}} =
             lite.__struct__.request_body(lite, @messages, tools: [BeamWeaver.Google.Tools.computer_use()])

    assert {:ok, _body} =
             lite.__struct__.request_body(lite, @messages, tools: [BeamWeaver.Google.Tools.google_search()])
  end
end
