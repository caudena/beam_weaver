defmodule BeamWeaver.Anthropic.ChatModelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Anthropic.ChatModel
  alias BeamWeaver.Anthropic.Client
  alias BeamWeaver.Anthropic.Error
  alias BeamWeaver.Anthropic.OutputParsers
  alias BeamWeaver.Anthropic.Tools
  alias BeamWeaver.Core.ChatModel, as: CoreChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Models
  alias BeamWeaver.Models.UsageCost

  test "constructor accepts native options, profile defaults, and streaming intent" do
    model =
      ChatModel.new(
        model: "claude-sonnet-4-5",
        endpoint: "https://proxy.test/v1/messages",
        count_tokens_endpoint: "https://proxy.test/v1/messages/count_tokens"
      )

    assert model.model == "claude-sonnet-4-5"
    assert model.endpoint == "https://proxy.test/v1/messages"
    assert model.count_tokens_endpoint == "https://proxy.test/v1/messages/count_tokens"
    assert model.max_tokens == 64_000

    assert ChatModel.should_stream?(%ChatModel{streaming: true})
    assert ChatModel.should_stream?(%ChatModel{}, stream: true)
    refute ChatModel.should_stream?(%ChatModel{})
  end

  test "namespace constructor preserves explicit endpoints" do
    model =
      BeamWeaver.Anthropic.chat_model(
        endpoint: "https://proxy.test/v1/messages",
        count_tokens_endpoint: "https://proxy.test/v1/messages/count_tokens"
      )

    assert model.endpoint == "https://proxy.test/v1/messages"
    assert model.count_tokens_endpoint == "https://proxy.test/v1/messages/count_tokens"
  end

  test "client constructor reads config defaults and builds Anthropic headers" do
    with_config(
      :anthropic,
      [
        api_key: "env-secret"
      ],
      fn ->
        client =
          Client.new(
            betas: ["tools-beta"],
            default_headers: [{"user-agent", "beam-weaver-test"}]
          )

        request = Client.request(client, %{"model" => "claude-haiku-4-5-20251001"})

        assert request.url == "https://api.anthropic.com/v1/messages"
        assert {"x-api-key", "env-secret"} in request.headers
        assert {"anthropic-version", "2023-06-01"} in request.headers
        assert {"anthropic-beta", "tools-beta"} in request.headers
        assert {"user-agent", "beam-weaver-test"} in request.headers
      end
    )
  end

  test "invokes Anthropic Messages API through fake transport and decodes assistant text" do
    model =
      ChatModel.new(
        model: "claude-haiku-4-5-20251001",
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          expect: %{
            method: :post,
            path: "/v1/messages",
            json: %{
              "model" => "claude-haiku-4-5-20251001",
              "max_tokens" => 64_000,
              "messages" => [%{"role" => "user", "content" => "ping"}],
              "stream" => false
            }
          },
          body: %{
            "id" => "msg_fake",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-haiku-4-5-20251001",
            "content" => [%{"type" => "text", "text" => "pong"}],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          }
        ]
      )

    assert {:ok, %Message{} = response} = CoreChatModel.invoke(model, [Message.user("ping")])
    assert Message.text(response) == "pong"
    assert response.usage_metadata == %{input_tokens: 1, output_tokens: 1, total_tokens: 2}

    assert_received {:fake_transport_request, request}
    assert {"x-api-key", "anthropic-secret"} in request.headers
    assert {"anthropic-version", "2023-06-01"} in request.headers
  end

  test "Claude Sonnet 5 responses preserve headers, usage, thinking, and model metadata" do
    model =
      ChatModel.new(
        model: "claude-sonnet-5",
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          expect: %{
            method: :post,
            path: "/v1/messages",
            json: %{
              "model" => "claude-sonnet-5",
              "max_tokens" => 128_000,
              "messages" => [%{"role" => "user", "content" => "ping"}],
              "stream" => false,
              "thinking" => %{"type" => "adaptive"},
              "output_config" => %{"effort" => "xhigh"}
            }
          },
          headers: [
            {"content-type", "application/json"},
            {"request-id", "req-sonnet-5"},
            {"anthropic-ratelimit-requests-remaining", "99"},
            {"anthropic-organization-id", "org_123"}
          ],
          body: %{
            "id" => "msg_sonnet_5",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-sonnet-5",
            "content" => [%{"type" => "text", "text" => "OK"}],
            "stop_reason" => "end_turn",
            "stop_details" => nil,
            "usage" => %{
              "input_tokens" => 2,
              "cache_read_input_tokens" => 3,
              "cache_creation_input_tokens" => 5,
              "cache_creation" => %{
                "ephemeral_5m_input_tokens" => 1,
                "ephemeral_1h_input_tokens" => 4
              },
              "output_tokens" => 8,
              "output_tokens_details" => %{"thinking_tokens" => 7},
              "service_tier" => "standard",
              "inference_geo" => "global"
            }
          }
        ]
      )

    assert {:ok, %Message{} = response} =
             CoreChatModel.invoke(model, [Message.user("ping")],
               thinking: %{type: :adaptive},
               effort: :xhigh
             )

    assert Message.text(response) == "OK"
    assert response.response_metadata.model.model == "claude-sonnet-5"
    assert response.response_metadata.model.requested_model == "claude-sonnet-5"
    assert response.response_metadata.reasoning.requested_effort == :xhigh
    assert response.response_metadata.transport.request_id == "req-sonnet-5"
    assert response.response_metadata.request_id == "req-sonnet-5"

    assert response.response_metadata.headers == %{
             request_id: "req-sonnet-5",
             anthropic_ratelimit_requests_remaining: "99",
             anthropic_organization_id: "org_123"
           }

    refute Map.has_key?(response.response_metadata.transport, :headers)
    assert response.response_metadata.provider_metadata.raw.raw_provider_response["model"] == "claude-sonnet-5"
    assert response.response_metadata.provider_metadata.raw.raw_provider_response["usage"]["service_tier"] == "standard"
    assert response.response_metadata.usage.reasoning_tokens == 7
    assert response.response_metadata.usage.output_token_details.thinking_tokens == 7
    assert response.response_metadata.usage.service_tier == "standard"
    assert response.response_metadata.usage.inference_geo == "global"
    assert response.response_metadata.usage.cache_creation_tokens == 5
    assert response.usage_metadata.input_token_details.cache_creation == 5
    assert response.usage_metadata.output_token_details.thinking_tokens == 7

    assert_received {:fake_transport_request, request}
    assert {"anthropic-version", "2023-06-01"} in request.headers
  end

  test "request body includes tools, structured output, thinking, mcp betas, and reused container" do
    model =
      ChatModel.new(
        model: "claude-sonnet-4-5",
        thinking: %{type: :enabled, budget_tokens: 1024},
        reuse_last_container: true
      )

    previous =
      Message.assistant("done",
        response_metadata: %{container: %{"id" => "container_123"}}
      )

    assert {:ok, body} =
             ChatModel.request_body(
               model,
               [Message.user("run"), previous, Message.user("again")],
               tools: [Tools.web_fetch()],
               response_format: %{schema: %{type: :object, properties: %{ok: %{type: :boolean}}}},
               mcp_servers: [%{type: :url, url: "https://mcp.example.test/mcp", name: "mcp"}],
               cache_control: %{type: :ephemeral},
               metadata: %{user_id: "user_123"},
               service_tier: :auto,
               diagnostics: %{trace: true},
               speed: :standard,
               user_profile_id: "profile_123",
               effort: :medium,
               parallel_tool_calls: false,
               tool_choice: :auto,
               stream: true
             )

    assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 1024}
    assert body["container"] == "container_123"
    assert body["cache_control"] == %{"type" => "ephemeral"}
    assert body["metadata"] == %{"user_id" => "user_123"}
    assert body["service_tier"] == "auto"
    assert body["diagnostics"] == %{"trace" => true}
    assert body["speed"] == "standard"
    assert body["user_profile_id"] == "profile_123"
    assert body["tools"] == [%{"type" => "web_fetch_20260309", "name" => "web_fetch"}]
    assert body["tool_choice"] == %{"type" => "auto", "disable_parallel_tool_use" => true}
    assert body["output_config"]["effort"] == "medium"
    assert body["output_config"]["format"]["type"] == "json_schema"
    assert "web-fetch-2026-03-09" in body["betas"]
    assert "mcp-client-2025-11-20" in body["betas"]
  end

  test "inferred betas are sent as the anthropic-beta header, not in the request body" do
    model =
      ChatModel.new(
        model: "claude-sonnet-4-5",
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          body: %{
            "id" => "msg_fake",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-sonnet-4-5",
            "content" => [%{"type" => "text", "text" => "ok"}],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          }
        ]
      )

    assert {:ok, %Message{}} =
             CoreChatModel.invoke(model, [Message.user("go")], tools: [Tools.web_fetch()])

    assert_received {:fake_transport_request, request}

    # The inferred beta is enabled via the anthropic-beta header...
    assert Enum.any?(request.headers, fn
             {"anthropic-beta", value} -> String.contains?(value, "web-fetch-2026-03-09")
             _ -> false
           end)

    # ...and is no longer left in the JSON body, where Anthropic would ignore it.
    refute Map.has_key?(request.json, "betas")
  end

  test "explicit container and count-token-only options match Anthropic schema" do
    model = ChatModel.new(model: "claude-sonnet-4-6")

    previous =
      Message.assistant("done",
        response_metadata: %{container: %{"id" => "container_old"}}
      )

    assert {:ok, body} =
             ChatModel.request_body(
               model,
               [Message.user("start"), previous, Message.user("again")],
               container: "container_explicit",
               reuse_last_container: true
             )

    assert body["container"] == "container_explicit"

    assert {:ok, count_body} =
             BeamWeaver.Anthropic.ChatModel.RequestBuilder.count_tokens_body(
               model,
               [Message.user("count")],
               cache_control: %{type: :ephemeral},
               thinking: %{type: :enabled, budget_tokens: 1024},
               tool_choice: :auto,
               output_config: %{effort: :low},
               mcp_servers: [%{type: :url, url: "https://mcp.example.test/mcp", name: "mcp"}],
               speed: :standard
             )

    assert count_body["cache_control"] == %{"type" => "ephemeral"}
    assert count_body["thinking"] == %{"type" => "enabled", "budget_tokens" => 1024}
    assert count_body["tool_choice"] == %{"type" => "auto"}
    assert count_body["output_config"] == %{"effort" => "low"}

    assert count_body["mcp_servers"] == [
             %{"type" => "url", "url" => "https://mcp.example.test/mcp", "name" => "mcp"}
           ]

    assert count_body["speed"] == "standard"
    assert "mcp-client-2025-11-20" in count_body["betas"]
  end

  test "Claude Opus 4.8 rejects deprecated sampling controls before transport" do
    model = ChatModel.new(model: "claude-opus-4-8")

    assert {:error, error} =
             ChatModel.request_body(model, [Message.user("hello")],
               temperature: 0.5,
               top_k: 5,
               top_p: 0.9
             )

    assert error.type == :unsupported_model_param
    assert error.details.provider == :anthropic
    assert error.details.model == "claude-opus-4-8"
    assert Enum.sort(error.details.params) == [:temperature, :top_k, :top_p]

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("hello")],
               temperature: 1.0,
               top_p: 0.99
             )

    assert body["temperature"] == 1.0
    assert body["top_p"] == 0.99
    refute Map.has_key?(body, "top_k")
  end

  test "Claude Opus 4.8 requires adaptive thinking when thinking is enabled" do
    model = ChatModel.new(model: "claude-opus-4-8")

    assert {:error, error} =
             ChatModel.request_body(model, [Message.user("hello")], thinking: %{type: :enabled, budget_tokens: 1024})

    assert error.type == :unsupported_model_param
    assert error.details.params == [:thinking]
    assert error.details.reason =~ "adaptive thinking"

    assert {:error, count_error} =
             BeamWeaver.Anthropic.ChatModel.RequestBuilder.count_tokens_body(
               model,
               [Message.user("hello")],
               thinking: %{type: :enabled, budget_tokens: 1024}
             )

    assert count_error.details.params == [:thinking]

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("hello")],
               thinking: %{type: :adaptive},
               effort: :high
             )

    assert body["thinking"] == %{"type" => "adaptive"}
    assert body["output_config"] == %{"effort" => "high"}
  end

  test "Claude Opus 5 defaults to adaptive thinking and enforces its effort cap" do
    model = ChatModel.new(model: "claude-opus-5")

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("hello")], effort: :max)

    refute Map.has_key?(body, "thinking")
    assert body["output_config"] == %{"effort" => "max"}

    for effort <- [:xhigh, :max] do
      assert {:error, error} =
               ChatModel.request_body(model, [Message.user("hello")],
                 thinking: %{type: :disabled},
                 effort: effort
               )

      assert error.type == :unsupported_model_param
      assert error.details.model == "claude-opus-5"
      assert error.details.params == [:thinking, :effort]
      assert error.details.reason =~ "high effort or below"
    end

    assert {:error, nested_error} =
             ChatModel.request_body(model, [Message.user("hello")],
               thinking: %{type: :disabled},
               output_config: %{effort: :max}
             )

    assert nested_error.details.params == [:thinking, :effort]

    assert {:ok, disabled_body} =
             ChatModel.request_body(model, [Message.user("hello")],
               thinking: %{type: :disabled},
               effort: :high
             )

    assert disabled_body["thinking"] == %{"type" => "disabled"}
    assert disabled_body["output_config"] == %{"effort" => "high"}
  end

  test "Claude Opus 5 supports fallback and mid-conversation instruction surfaces" do
    model = ChatModel.new(model: "claude-opus-5")

    messages = [
      Message.system("Review code carefully."),
      Message.user("Review module A."),
      Message.assistant("Module A looks good."),
      Message.user("Now review module B."),
      Message.system([
        %{type: :text, text: "Use the new security checklist."},
        %{type: :tool_addition, name: "security_scan"}
      ])
    ]

    assert {:ok, body} =
             ChatModel.request_body(model, messages, fallbacks: :default)

    assert body["system"] == "Review code carefully."
    assert List.last(body["messages"])["role"] == "system"

    assert List.last(body["messages"])["content"] |> List.last() == %{
             "type" => "tool_addition",
             "tool" => %{
               "type" => "tool_reference",
               "name" => "security_scan"
             }
           }

    assert body["fallbacks"] == "default"
    assert "mid-conversation-tool-changes-2026-07-01" in body["betas"]
    assert "server-side-fallback-2026-07-01" in body["betas"]

    assert {:ok, explicit_fallback_body} =
             ChatModel.request_body(model, [Message.user("hello")],
               fallbacks: [%{model: "claude-opus-4-8", max_tokens: 8_192}]
             )

    assert explicit_fallback_body["fallbacks"] == [
             %{"model" => "claude-opus-4-8", "max_tokens" => 8_192}
           ]

    assert "server-side-fallback-2026-06-01" in explicit_fallback_body["betas"]
  end

  test "Claude Opus 5 rejects unsupported sampling controls and web fetch" do
    model = ChatModel.new(model: "claude-opus-5")

    assert {:error, sampling_error} =
             ChatModel.request_body(model, [Message.user("hello")], temperature: 0.5)

    assert sampling_error.type == :unsupported_model_param
    assert sampling_error.details.params == [:temperature]

    assert {:error, tool_error} =
             ChatModel.request_body(model, [Message.user("hello")], tools: [Tools.web_fetch()])

    assert tool_error.type == :unsupported_feature
    assert tool_error.details.params == [:tools]
    assert tool_error.details.unsupported_server_tools == [:web_fetch]
  end

  test "Claude Sonnet 5 uses adaptive thinking effort and rejects deprecated controls" do
    model = ChatModel.new(model: "claude-sonnet-5")

    assert {:error, sampling_error} =
             ChatModel.request_body(model, [Message.user("hello")],
               temperature: 0.5,
               top_k: 5,
               top_p: 0.9
             )

    assert sampling_error.type == :unsupported_model_param
    assert sampling_error.details.model == "claude-sonnet-5"
    assert Enum.sort(sampling_error.details.params) == [:temperature, :top_k, :top_p]

    assert {:error, thinking_error} =
             ChatModel.request_body(model, [Message.user("hello")], thinking: %{type: :enabled, budget_tokens: 1024})

    assert thinking_error.type == :unsupported_model_param
    assert thinking_error.details.params == [:thinking]
    assert thinking_error.details.reason =~ "adaptive thinking"

    assert {:ok, body} =
             ChatModel.request_body(model, [Message.user("hello")],
               thinking: %{type: :adaptive},
               effort: :max
             )

    assert body["thinking"] == %{"type" => "adaptive"}
    assert body["output_config"] == %{"effort" => "max"}
  end

  test "Claude Fable 5.1 and Mythos 5.1 expose their exact limits and pricing" do
    for {model_id, availability} <- [
          {"claude-fable-5-1", :general_availability},
          {"claude-mythos-5-1", :invite_only}
        ] do
      model = ChatModel.new(model: model_id)

      assert model.max_tokens == 128_000
      assert model.profile.max_input_tokens == 1_000_000
      assert model.profile.max_output_tokens == 128_000
      assert model.profile.extra.availability == availability
      assert model.profile.extra.input_price_per_mtok == 10.0
      assert model.profile.extra.output_price_per_mtok == 50.0
      assert model.profile.extra.cache_read_price_per_mtok == 0.25
      assert model.profile.extra.cached_input_price_per_mtok == 0.25
      assert model.profile.extra.batch_cached_input_price_per_mtok == 0.125
      assert model.profile.extra.prompt_cache_min_tokens == 512
      assert model.profile.extra.knowledge_cutoff == "2026-06"
      assert model.profile.extra.training_data_cutoff == "2026-06"
      assert model.profile.extra.effort_levels == [:low, :medium, :high, :xhigh, :max]
      assert model.profile.extra.tool_choice_modes == [:auto, :none]
      assert model.profile.structured_output_with_tools

      costs =
        UsageCost.calculate(model.profile, %{
          input_tokens: 1_000,
          output_tokens: 2_000,
          input_token_details: %{cache_read: 400}
        })

      assert_in_delta costs.total_cost, 0.1061, 1.0e-12
    end
  end

  test "Claude Fable 5.1 and Mythos 5.1 require adaptive thinking and reject forced tools" do
    messages = [Message.user("hello")]

    for model_id <- ["claude-fable-5-1", "claude-mythos-5-1"] do
      model = ChatModel.new(model: model_id)

      assert {:error, thinking_error} =
               ChatModel.request_body(model, messages, thinking: %{type: :disabled})

      assert thinking_error.type == :unsupported_model_param
      assert thinking_error.details.model == model_id
      assert thinking_error.details.params == [:thinking]
      assert thinking_error.details.reason =~ "always on"

      assert {:error, count_thinking_error} =
               BeamWeaver.Anthropic.ChatModel.RequestBuilder.count_tokens_body(
                 model,
                 messages,
                 thinking: %{type: :disabled}
               )

      assert count_thinking_error.details.params == [:thinking]

      for choice <- [:any, :lookup, %{type: :tool, name: "lookup"}] do
        assert {:error, tool_choice_error} =
                 ChatModel.request_body(model, messages, tool_choice: choice)

        assert tool_choice_error.type == :unsupported_model_param
        assert tool_choice_error.details.model == model_id
        assert tool_choice_error.details.params == [:tool_choice]
        assert tool_choice_error.details.supported == [:auto, :none]

        assert {:error, count_tool_choice_error} =
                 BeamWeaver.Anthropic.ChatModel.RequestBuilder.count_tokens_body(
                   model,
                   messages,
                   tool_choice: choice
                 )

        assert count_tool_choice_error.details.params == [:tool_choice]
      end

      for choice <- [:auto, :none] do
        assert {:ok, body} =
                 ChatModel.request_body(model, messages,
                   thinking: %{type: :adaptive},
                   effort: :max,
                   tool_choice: choice
                 )

        assert body["thinking"] == %{"type" => "adaptive"}
        assert body["output_config"] == %{"effort" => "max"}
        assert body["tool_choice"] == %{"type" => Atom.to_string(choice)}
      end
    end
  end

  test "Claude 5.1 thinking binding controls infer their beta and validate mismatch behavior" do
    model = ChatModel.new(model: "claude-fable-5-1")
    messages = [Message.user("hello")]

    for builder <- [
          &ChatModel.request_body/3,
          &BeamWeaver.Anthropic.ChatModel.RequestBuilder.count_tokens_body/3
        ] do
      assert {:ok, body} =
               builder.(model, messages,
                 betas: ["existing-beta"],
                 thinking: %{
                   type: :adaptive,
                   block_binding: %{prefix_mismatch_behavior: :drop_block}
                 }
               )

      assert body["thinking"] == %{
               "type" => "adaptive",
               "block_binding" => %{"prefix_mismatch_behavior" => "drop_block"}
             }

      assert Enum.sort(body["betas"]) ==
               Enum.sort(["existing-beta", "thinking-binding-controls-2026-08-01"])

      assert {:error, error} =
               builder.(model, messages,
                 thinking: %{
                   type: :adaptive,
                   block_binding: %{prefix_mismatch_behavior: :keep_block}
                 }
               )

      assert error.type == :unsupported_model_param
      assert error.details.field == "thinking.block_binding.prefix_mismatch_behavior"
      assert error.details.supported == [:error, :drop_block]

      for invalid <- [
            %{type: :adaptive, block_binding: %{}},
            %{type: :adaptive, block_binding: "invalid"},
            %{"type" => "adaptive", "block_binding" => %{"prefix_mismatch_behavior" => "keep"}}
          ] do
        assert {:error, invalid_error} = builder.(model, messages, thinking: invalid)
        assert invalid_error.type == :unsupported_model_param
        assert invalid_error.details.field == "thinking.block_binding.prefix_mismatch_behavior"
      end

      assert {:error, shape_error} = builder.(model, messages, thinking: "adaptive")
      assert shape_error.type == :unsupported_model_param
      assert shape_error.details.expected == :map
    end
  end

  test "Claude Fable 5.1 and Mythos 5.1 combine native structured output with tools" do
    schema = %{
      "title" => "LookupResponse",
      "type" => "object",
      "required" => ["answer"],
      "properties" => %{"answer" => %{"type" => "string"}}
    }

    lookup_tool =
      Tool.from_function!(
        name: "lookup",
        description: "Look up a value.",
        input_schema: %{"type" => "object", "properties" => %{}},
        handler: fn args, _opts -> args end
      )

    for model_id <- ["claude-fable-5-1", "claude-mythos-5-1"] do
      model = ChatModel.new(model: model_id)

      assert %StructuredOutput.ProviderStrategy{} =
               strategy =
               StructuredOutput.effective_strategy(
                 StructuredOutput.auto(schema),
                 model,
                 [lookup_tool]
               )

      opts = Keyword.merge([tools: [lookup_tool]], StructuredOutput.provider_opts(strategy))

      assert {:ok, body} = ChatModel.request_body(model, [Message.user("look it up")], opts)
      assert body["output_config"]["format"] == %{"type" => "json_schema", "schema" => schema}
      assert [%{"name" => "lookup"}] = body["tools"]
      refute Map.has_key?(body, "tool_choice")
    end
  end

  test "Claude 5.1 validation follows per-call model overrides" do
    messages = [Message.user("hello")]
    fable_5 = ChatModel.new(model: "claude-fable-5")
    fable_5_1 = ChatModel.new(model: "claude-fable-5-1")

    for builder <- [
          &ChatModel.request_body/3,
          &BeamWeaver.Anthropic.ChatModel.RequestBuilder.count_tokens_body/3
        ] do
      assert {:error, error} =
               builder.(fable_5, messages,
                 model: "claude-fable-5-1",
                 tool_choice: :any
               )

      assert error.type == :unsupported_model_param
      assert error.details.model == "claude-fable-5-1"

      assert {:ok, body} =
               builder.(fable_5_1, messages,
                 model: "claude-fable-5",
                 tool_choice: :any
               )

      assert body["model"] == "claude-fable-5"
      assert body["tool_choice"] == %{"type" => "any"}
    end

    assert {:ok, haiku_body} =
             ChatModel.request_body(fable_5_1, messages, model: "claude-haiku-4-5-20251001")

    assert haiku_body["model"] == "claude-haiku-4-5-20251001"
    assert haiku_body["max_tokens"] == 64_000
  end

  test "per-call model overrides drive full invocation capabilities and response metadata" do
    schema = %{
      "title" => "answer",
      "type" => "object",
      "required" => ["value"],
      "properties" => %{"value" => %{"type" => "string"}}
    }

    inner =
      ChatModel.new(
        model: "claude-haiku-4-5-20251001",
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          expect: %{
            method: :post,
            path: "/v1/messages",
            json: %{
              "model" => "claude-fable-5-1",
              "max_tokens" => 64_000,
              "messages" => [%{"role" => "user", "content" => "answer"}],
              "stream" => false,
              "output_config" => %{
                "format" => %{"type" => "json_schema", "schema" => schema}
              }
            }
          },
          body: %{
            "id" => "msg_override",
            "type" => "message",
            "role" => "assistant",
            "model" => "claude-fable-5-1",
            "content" => [%{"type" => "text", "text" => ~s({"value":"native"})}],
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          }
        ]
      )

    model = Models.with_structured_output(inner, schema)

    assert {:ok, %Message{} = response} =
             CoreChatModel.invoke(model, [Message.user("answer")], model: "claude-fable-5-1")

    assert response.metadata.structured_response == %{"value" => "native"}
    assert response.response_metadata.model.requested_model == "claude-fable-5-1"
    assert response.response_metadata.model.profile_id == "claude-fable-5-1"
    assert response.response_metadata.limits.max_input_tokens == 1_000_000
    assert response.response_metadata.limits.max_output_tokens == 128_000
    assert_received {:fake_transport_request, _request}
  end

  test "raw extension maps cannot replace Anthropic-owned request fields" do
    messages = [Message.user("hello")]
    model = ChatModel.new(model: "claude-fable-5")

    for extension <- [:model_kwargs, :extra_body] do
      opts =
        [tool_choice: :any]
        |> Keyword.put(extension, %{
          model: "claude-fable-5-1",
          thinking: %{type: :disabled},
          tool_choice: %{type: :none},
          betas: ["unvalidated-beta"],
          extension_flag: true
        })

      assert {:ok, body} = ChatModel.request_body(model, messages, opts)
      assert body["model"] == "claude-fable-5"
      assert body["tool_choice"] == %{"type" => "any"}
      refute Map.has_key?(body, "thinking")
      refute "unvalidated-beta" in List.wrap(body["betas"])
      assert body["extension_flag"] == true
    end
  end

  test "string-keyed custom profile extras enforce Claude compatibility rules" do
    profile = %{
      provider: :anthropic,
      id: "claude-custom-5-1",
      max_input_tokens: 1_000_000,
      max_output_tokens: 128_000,
      supported_params: :unknown,
      extra: %{
        "thinking_always_on" => true,
        "thinking_mode" => "adaptive_only",
        "sampling_controls" => "restricted",
        "prefilled_model_turns" => false,
        "tool_choice_modes" => ["auto", "none"]
      }
    }

    model = ChatModel.new(model: "claude-custom-5-1", profile: profile)

    assert {:error, error} =
             ChatModel.request_body(model, [Message.user("hello")], thinking: %{type: :disabled})

    assert error.details.reason == "Thinking is always on for this Claude model"

    assert {:error, prefill_error} =
             ChatModel.request_body(model, [Message.user("hello"), Message.assistant("prefill")])

    assert prefill_error.type == :invalid_message

    assert {:error, tool_error} =
             ChatModel.request_body(model, [Message.user("hello")], tool_choice: :any)

    assert tool_error.details.supported == ["auto", "none"]
  end

  test "Claude Fable 5.1 and Mythos 5.1 reject final assistant prefills" do
    tool_call = %ToolCall{id: "call-1", name: "lookup", args: %{"q" => "beam"}}

    for model_id <- ["claude-fable-5-1", "claude-mythos-5-1"],
        final_message <- [
          Message.assistant("Answer:"),
          Message.assistant(""),
          Message.assistant("", tool_calls: [tool_call])
        ] do
      model = ChatModel.new(model: model_id)
      messages = [Message.user("Complete this"), final_message]

      for builder <- [
            &ChatModel.request_body/3,
            &BeamWeaver.Anthropic.ChatModel.RequestBuilder.count_tokens_body/3
          ] do
        assert {:error, error} = builder.(model, messages, [])
        assert error.type == :invalid_message
        assert error.details.model == model_id
        assert error.details.role == :assistant
        assert error.details.requirement == :final_user_tool_or_system_turn
      end
    end

    assert {:ok, _body} =
             ChatModel.request_body(
               ChatModel.new(model: "claude-sonnet-4-5"),
               [Message.user("Complete this"), Message.assistant("Answer:")]
             )
  end

  test "stream and stream_response consume Anthropic SSE fixtures" do
    body = """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_stream","type":"message","role":"assistant","model":"claude-haiku-4-5-20251001","content":[],"usage":{"input_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"po"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ng"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}
    """

    model =
      ChatModel.new(
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{
            method: :post,
            path: "/v1/messages",
            json: %{
              "model" => "claude-haiku-4-5-20251001",
              "max_tokens" => 64_000,
              "messages" => [%{"role" => "user", "content" => "stream"}],
              "stream" => true
            }
          },
          headers: [
            {"content-type", "text/event-stream"},
            {"request-id", "req-anthropic-stream"}
          ],
          body: body
        ]
      )

    assert {:ok, chunks} = ChatModel.stream(model, [Message.user("stream")])
    assert Enum.join(chunks) == "pong"

    assert {:ok, response} = ChatModel.stream_response(model, [Message.user("stream")])
    assert Message.text(response) == "pong"
    assert response.status == "end_turn"
    assert response.response_metadata.headers.request_id == "req-anthropic-stream"
  end

  test "stream_typed_events uses Anthropic's typed SSE parser" do
    body = """
    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"pong"}}
    """

    model =
      ChatModel.new(
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/v1/messages"},
          headers: [{"content-type", "text/event-stream"}],
          body: body
        ]
      )

    assert {:ok, stream} =
             CoreChatModel.stream_typed_events(model, [Message.user("stream")])

    events = Enum.to_list(stream)

    assert Enum.any?(events, &match?(%{event: %BeamWeaver.Stream.Events.Token{text: "pong"}}, &1))
    assert Enum.all?(events, &(&1.metadata.provider == :anthropic))
  end

  test "stream_exact_typed_events dispatches the persisted request bytes unchanged" do
    exact_body = "{\n  \"stream\": true, \"model\": \"persisted-model\"\n}\n"

    response_body = """
    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"pong"}}
    """

    model =
      ChatModel.new(
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          parent: self(),
          expect: %{method: :post, path: "/v1/messages"},
          headers: [{"content-type", "text/event-stream"}],
          body: response_body
        ]
      )

    assert {:ok, stream} = CoreChatModel.stream_exact_typed_events(model, exact_body)
    assert Enum.any?(stream, &match?(%{event: %BeamWeaver.Stream.Events.Token{text: "pong"}}, &1))

    assert_receive {:fake_transport_request, %BeamWeaver.Transport.Request{body: ^exact_body, json: nil}}
  end

  test "count_tokens uses Anthropic count_tokens endpoint" do
    model =
      ChatModel.new(
        api_key: "anthropic-secret",
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{
            method: :post,
            path: "/v1/messages/count_tokens",
            json: %{
              "model" => "claude-haiku-4-5-20251001",
              "messages" => [%{"role" => "user", "content" => "hello"}]
            }
          },
          body: %{"input_tokens" => 7}
        ]
      )

    assert {:ok, 7} = ChatModel.count_tokens(model, [Message.user("hello")])
  end

  test "Anthropic prompt-length HTTP errors are normalized as context overflow" do
    model =
      ChatModel.new(
        transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport,
        transport_opts: [
          expect: %{method: :post, path: "/v1/messages"},
          status: 400,
          body: %{
            "error" => %{
              "type" => "invalid_request_error",
              "message" => "prompt is too long: 1 > 0"
            }
          }
        ]
      )

    assert {:error, %Error{type: :context_overflow} = error} =
             CoreChatModel.invoke(model, [Message.user("test")])

    assert error.details.status == 400
    assert error.details.error["type"] == "invalid_request_error"
    assert error.message =~ "prompt is too long"
  end

  test "model initializer supports explicit and inferred Anthropic identifiers" do
    for model <- [
          "claude-haiku-4-5-20251001",
          "claude-fable-5-1",
          "claude-mythos-5-1",
          "claude-opus-4-8",
          "claude-opus-5",
          "claude-sonnet-5",
          "claude-fable-5",
          "claude-mythos-5"
        ] do
      assert {:ok, %ChatModel{model: ^model}} = Models.init_chat_model("anthropic:" <> model)
    end

    assert {:ok, inferred} = Models.init_chat_model("claude-sonnet-4-6")
    assert inferred.__struct__ == ChatModel
  end

  test "model initializer rejects deprecated and retired Anthropic identifiers" do
    assert {:error, deprecated} =
             Models.init_chat_model("anthropic:claude-sonnet-4-20250514")

    assert deprecated.type == :deprecated_model
    assert deprecated.details.provider == :anthropic
    assert deprecated.details.replacement == "claude-sonnet-4-6"
    assert deprecated.details.expected == "anthropic:claude-sonnet-4-6"
    assert deprecated.details.retirement_date == "2026-06-15"

    assert {:error, retired} =
             Models.init_chat_model("anthropic:claude-3-7-sonnet-20250219")

    assert retired.type == :deprecated_model
    assert retired.details.replacement == "claude-sonnet-4-6"
    assert retired.details.retirement_date == "2026-02-19"

    assert {:error, opus} =
             Models.init_chat_model("anthropic:claude-opus-4-20250514")

    assert opus.type == :deprecated_model
    assert opus.details.replacement == "claude-opus-4-8"
    assert opus.details.expected == "anthropic:claude-opus-4-8"
  end

  test "output parser extracts Anthropic tool_use blocks" do
    content = [
      %{"type" => "text", "text" => "checking"},
      %{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup", "input" => %{"q" => "beam"}}
    ]

    assert OutputParsers.extract_tool_calls(content) == [
             %ToolCall{
               id: "toolu_1",
               provider_id: "toolu_1",
               call_id: "toolu_1",
               name: "lookup",
               args: %{"q" => "beam"}
             }
           ]
  end

  defp with_config(group, values, fun) do
    BeamWeaver.TestSupport.ConfigHelper.put_config(group, values)
    fun.()
  end
end
