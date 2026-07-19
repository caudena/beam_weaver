defmodule BeamWeaver.Models.InitializerTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry
  alias BeamWeaver.Tokenizer.OpenAI, as: OpenAITokenizer
  alias BeamWeaver.Tokenizer.StaticVocabulary

  defmodule TokenCounter do
    def count(value, extra), do: LanguageModel.count_tokens_approximately(value) + extra
  end

  defmodule ExplicitRegistry do
    def fetch(:fake, "chat") do
      {:ok,
       Profile.new(%{
         "provider" => :fake,
         "id" => "chat",
         "name" => "Custom fake chat",
         "supported_params" => [:temperature],
         "unknown_future_key" => "preserved"
       })}
    end
  end

  test "init_chat_model accepts provider-prefixed and inferred OpenAI identifiers" do
    assert {:ok, openai} = Models.init_chat_model("openai:gpt-5.4", temperature: 0.2)
    assert openai.__struct__ == BeamWeaver.OpenAI.ChatModel
    assert openai.model == "gpt-5.4"
    assert openai.temperature == 0.2

    assert %Profile{provider: :openai, tool_calling: true, structured_output: true} =
             openai.profile

    assert openai.profile.tool_call_streaming

    assert {:ok, inferred} = Models.init_chat_model("gpt-5.4")
    assert inferred.__struct__ == BeamWeaver.OpenAI.ChatModel
  end

  test "init_chat_model can select the explicit Chat Completions implementation" do
    assert {:ok, chat_completions} =
             Models.init_chat_model("openai:gpt-5.4-mini",
               api: :chat_completions,
               max_completion_tokens: 64
             )

    assert chat_completions.__struct__ == BeamWeaver.OpenAI.ChatCompletionsModel
    assert chat_completions.model == "gpt-5.4-mini"
    assert chat_completions.max_completion_tokens == 64
    assert Profile.api_supported?(chat_completions.profile, :chat_completions)

    assert Profile.supports_param?(
             chat_completions.profile,
             :chat_completions,
             :max_completion_tokens
           )

    refute Profile.supports_param?(chat_completions.profile, :chat_completions, :reasoning)
  end

  test "init_chat_model returns tagged errors for unsupported providers" do
    assert {:error, error} = Models.init_chat_model("unknown:model")
    assert error.type == :unsupported_provider
  end

  test "init_chat_model accepts explicit Google identifiers but not bare Gemini aliases" do
    assert {:ok, google} = Models.init_chat_model("google:gemini-3.5-flash")
    assert google.__struct__ == BeamWeaver.Google.ChatModel
    assert google.model == "gemini-3.5-flash"
    assert google.profile.provider == :google
    assert google.profile.max_input_tokens == 1_048_576
    refute google.profile.image_outputs
    refute google.profile.audio_outputs

    assert {:ok, pro} = Models.init_chat_model("google:gemini-3.1-pro-preview")
    assert pro.__struct__ == BeamWeaver.Google.ChatModel
    assert pro.profile.provider == :google
    assert pro.profile.reasoning_output

    assert {:error, error} = Models.init_chat_model("gemini-3.5-flash")
    assert error.type == :invalid_model
    assert error.details.expected == "google:gemini-3.5-flash"
  end

  test "init_chat_model accepts explicit Moonshot identifiers but not Kimi aliases" do
    assert {:ok, k3} = Models.init_chat_model("moonshot:kimi-k3")
    assert k3.__struct__ == BeamWeaver.Moonshot.ChatModel
    assert k3.profile.max_input_tokens == 1_048_576
    assert k3.profile.max_output_tokens == 1_048_576
    assert k3.profile.tool_call_streaming
    assert k3.profile.extra.reasoning_efforts == [:max]
    assert k3.profile.extra.default_max_completion_tokens == 131_072
    assert k3.profile.extra.tool_choice_when_thinking == ["auto", "none", "required"]
    assert Profile.supports_param?(k3.profile, :chat_completions, :reasoning_effort)
    refute Profile.supports_param?(k3.profile, :chat_completions, :thinking)

    assert {:ok, code_model} = Models.init_chat_model("moonshot:kimi-k2.7-code")
    assert code_model.__struct__ == BeamWeaver.Moonshot.ChatModel
    assert code_model.model == "kimi-k2.7-code"
    assert code_model.profile.provider == :moonshot
    assert code_model.profile.max_input_tokens == 262_144
    assert code_model.profile.reasoning_output
    assert code_model.profile.video_inputs
    assert code_model.profile.extra.thinking_modes == [:enabled]
    refute code_model.profile.extra.web_search_supported

    assert {:ok, highspeed_model} = Models.init_chat_model("moonshot:kimi-k2.7-code-highspeed")
    assert highspeed_model.model == "kimi-k2.7-code-highspeed"
    assert highspeed_model.profile.extra.highspeed
    assert highspeed_model.profile.extra.same_model_as == "kimi-k2.7-code"
    assert highspeed_model.profile.extra.output_speed_tokens_per_second == 180

    assert {:ok, moonshot} = Models.init_chat_model("moonshot:kimi-k2.6")
    assert moonshot.__struct__ == BeamWeaver.Moonshot.ChatModel
    assert moonshot.model == "kimi-k2.6"
    assert moonshot.profile.provider == :moonshot
    assert moonshot.profile.max_input_tokens == 262_144
    assert moonshot.profile.reasoning_output
    assert moonshot.profile.video_inputs
    assert moonshot.profile.chat_completions_api
    refute moonshot.profile.responses_api

    assert {:ok, k25_model} = Models.init_chat_model("moonshot:kimi-k2.5")
    assert k25_model.model == "kimi-k2.5"
    assert k25_model.profile.extra.thinking_modes == [:enabled, :disabled]

    assert {:error, bare} = Models.init_chat_model("kimi-k2.6")
    assert bare.type == :invalid_model
    assert bare.details.expected == "moonshot:kimi-k2.6"

    assert {:error, unsupported} = Models.init_chat_model("kimi:kimi-k2.6")
    assert unsupported.type == :unsupported_provider
  end

  test "init_chat_model accepts explicit Z.ai identifiers but not bare GLM aliases" do
    assert {:ok, zai} = Models.init_chat_model("zai:glm-5.2")
    assert zai.__struct__ == BeamWeaver.ZAI.ChatModel
    assert zai.model == "glm-5.2"
    assert zai.profile.provider == :zai
    assert zai.profile.max_input_tokens == 1_000_000
    assert zai.profile.max_output_tokens == 131_072
    assert zai.profile.reasoning_output
    assert zai.profile.tool_calling
    assert zai.profile.structured_output
    assert zai.profile.chat_completions_api
    refute zai.profile.responses_api

    assert {:error, bare} = Models.init_chat_model("glm-5.2")
    assert bare.type == :invalid_model
    assert bare.details.expected == "zai:glm-5.2"

    assert {:error, unsupported} = Models.init_chat_model("zai:glm-5.1")
    assert unsupported.type == :unsupported_model
    assert unsupported.details.expected == "zai:glm-5.2"
  end

  test "init_chat_model rejects discontinued Moonshot identifiers with replacements" do
    assert {:error, error} = Models.init_chat_model("moonshot:kimi-latest")

    assert error.type == :deprecated_model
    assert error.details.provider == :moonshot
    assert error.details.model == "kimi-latest"
    assert error.details.replacement == "kimi-k3"
    assert error.details.expected == "moonshot:kimi-k3"
  end

  test "init_chat_model rejects deprecated Google identifiers with replacements" do
    assert {:error, error} = Models.init_chat_model("google:gemini-2.5-flash")

    assert error.type == :deprecated_model
    assert error.details.provider == :google
    assert error.details.model == "gemini-2.5-flash"
    assert error.details.replacement == "gemini-3.5-flash"
    assert error.details.expected == "google:gemini-3.5-flash"

    assert {:error, error} = Models.init_chat_model("google:gemini-2.5-pro")
    assert error.type == :deprecated_model
    assert error.details.replacement == "gemini-3.1-pro-preview"
  end

  test "fake chat initializer preserves opts and chat input normalization accepts strings and prompt values" do
    parent = self()
    assert {:ok, model} = Models.init_chat_model("fake:chat", response: "pong", parent: parent)

    assert {:ok, %Message{content: "pong"}} = ChatModel.invoke(model, "ping")
    assert_receive {:fake_chat_model_call, [%Message{role: :user, content: "ping"}], _opts}

    prompt = %BeamWeaver.Prompt.Value{text: "from prompt"}
    assert {:ok, %Message{content: "pong"}} = ChatModel.invoke(model, prompt)
    assert_receive {:fake_chat_model_call, [%Message{role: :user, content: "from prompt"}], _opts}
  end

  test "init_embeddings accepts provider-prefixed identifiers" do
    assert {:ok, model} = Models.init_embeddings("fake:embedding", dimensions: 4)
    assert model.__struct__ == BeamWeaver.Models.FakeEmbeddingModel
    assert model.dimensions == 4
    assert {:ok, vector} = BeamWeaver.Core.EmbeddingModel.embed_query(model, "hello")
    assert length(vector) == 4
  end

  test "OpenAI embedding profile lookup rejects deprecated ada embeddings" do
    assert {:error, error} = Models.init_embeddings("openai:text-embedding-ada-002")
    assert error.type == :deprecated_model
    assert error.details.replacement == "text-embedding-3-small"
    assert error.details.expected == "openai:text-embedding-3-small"
  end

  test "token counting is explicit through functions, MFA, model callbacks, or approximate fallback" do
    assert {:ok, 2} = LanguageModel.count_tokens(:approximate, "hello world")
    assert {:ok, 7} = LanguageModel.count_tokens(fn _ -> 7 end, "ignored")
    assert {:ok, 5} = LanguageModel.count_tokens({TokenCounter, :count, [3]}, "hello world")

    assert {:ok, model} = Models.init_chat_model("fake:chat")
    assert {:ok, 2} = LanguageModel.count_tokens(model, [Message.user("hello world")])
  end

  test "static vocabulary tokenizer gives deterministic IDs and can drive model token counts" do
    tokenizer = %StaticVocabulary{vocabulary: %{"hello " => 11, "world" => 12}}

    assert {:ok, [11, 12]} = BeamWeaver.Tokenizer.encode(tokenizer, "hello world")
    assert {:ok, "hello world"} = BeamWeaver.Tokenizer.decode(tokenizer, [11, 12])
    assert {:ok, 2} = LanguageModel.count_tokens({:tokenizer, tokenizer}, "hello world")

    assert {:ok, model} = Models.init_chat_model("fake:chat", tokenizer: tokenizer)
    assert {:ok, 2} = LanguageModel.count_tokens({:model, model}, [Message.user("hello world")])
  end

  test "OpenAI tokenizer adapter gives exact deterministic counts when explicitly supplied" do
    # Upstream reference:
    # - token counting can be driven by an explicit model tokenizer.
    tokenizer = %OpenAITokenizer{model: "gpt-4o"}

    assert {:ok, [24_912, 2375]} = BeamWeaver.Tokenizer.encode(tokenizer, "hello world")
    assert {:ok, "hello world"} = BeamWeaver.Tokenizer.decode(tokenizer, [24_912, 2375])
    assert {:ok, 2} = BeamWeaver.Tokenizer.count_tokens(tokenizer, "hello world")

    assert {:ok, ["hello", " world"]} =
             BeamWeaver.Tokenizer.split_tokens(tokenizer, "hello world")

    assert {:ok, [15_339, 1917]} =
             BeamWeaver.Tokenizer.encode(%OpenAITokenizer{encoding: :cl100k_base}, "hello world")

    assert {:ok, model} = Models.init_chat_model("openai:gpt-5.4-mini")
    assert {:ok, %OpenAITokenizer{encoding: :o200k_base}} = Models.tokenizer_for(model.profile)
    assert {:ok, 6} = LanguageModel.count_tokens({:model, model}, [Message.user("hello world")])

    model =
      Models.with_tokenizer(
        model,
        %StaticVocabulary{vocabulary: %{"user" => 0, "hello " => 1, "world" => 2}}
      )

    assert {:ok, 6} = LanguageModel.count_tokens({:model, model}, [Message.user("hello world")])
  end

  test "OpenAI tokenizer returns tagged errors for unsupported encodings and missing selectors" do
    assert {:error, error} =
             BeamWeaver.Tokenizer.encode(%OpenAITokenizer{encoding: :not_real}, "hello")

    assert error.type == :unsupported_tokenizer
    assert error.details.encoding == :not_real

    assert {:error, error} = BeamWeaver.Tokenizer.count_tokens(%OpenAITokenizer{}, "hello")
    assert error.type == :invalid_tokenizer
  end

  test "OpenAI tokenizer matches upstream multilingual token-count fixtures" do
    # Upstream reference:
    text = "表情符号是\n🦜🔗"

    expected = %{
      "gpt-4" => 12,
      "gpt-4-32k" => 12,
      "gpt-3.5-turbo" => 12,
      "o1" => 11,
      "o3" => 11,
      "gpt-4o" => 11
    }

    for {model, count} <- expected do
      assert {:ok, ^count} =
               BeamWeaver.Tokenizer.count_tokens(%OpenAITokenizer{model: model}, text)
    end
  end

  test "OpenAI frontier profiles are strict while unknown non-family models stay permissive" do
    assert {:ok, gpt5_family} = ProfileRegistry.fetch(:openai, "gpt-5.5")
    assert Profile.api_supported?(gpt5_family, :responses)
    assert Profile.api_supported?(gpt5_family, :chat_completions)
    assert Profile.tokenizer_family(gpt5_family) == :o200k_base
    assert Profile.supports_param?(gpt5_family, :responses, :reasoning)
    refute Profile.supports_param?(gpt5_family, :chat_completions, :reasoning)

    assert {:error, error} =
             ParamPolicy.validate(gpt5_family, [reasoning: %{effort: "low"}], nil, api: :chat_completions)

    assert error.type == :unsupported_model_param
    assert error.details.params == [:reasoning]

    assert {:ok, sol} = ProfileRegistry.fetch(:openai, "gpt-5.6-sol")
    assert sol.status == :active
    assert sol.max_input_tokens == 1_050_000
    assert sol.max_output_tokens == 128_000
    assert sol.image_inputs
    refute sol.audio_inputs
    assert sol.extra.input_price_per_mtok == 5.00
    assert sol.extra.cached_input_price_per_mtok == 0.50
    assert sol.extra.cache_write_30m_price_per_mtok == 6.25
    assert sol.extra.output_price_per_mtok == 30.00
    assert sol.extra.regional_processing_multiplier == 1.1
    assert sol.extra.default_reasoning_effort == :medium
    assert sol.extra.reasoning_efforts == [:none, :low, :medium, :high, :xhigh, :max]
    assert :multi_agent_beta in sol.extra.provider_capabilities

    assert {:ok, gpt56_alias} = ProfileRegistry.fetch(:openai, "gpt-5.6")
    assert gpt56_alias.id == "gpt-5.6"
    assert gpt56_alias.extra.canonical_model == "gpt-5.6-sol"

    assert {:ok, unknown} = ProfileRegistry.fetch(:openai, "future-non-family-model")
    assert unknown.extra.unknown == true
    assert :ok = ParamPolicy.validate(unknown, [reasoning: %{effort: "low"}], nil)
  end

  test "OpenAI chat profile lookup rejects deprecated and non-frontier models" do
    assert {:error, deprecated} = Models.init_chat_model("openai:o4-mini")
    assert deprecated.type == :deprecated_model
    assert deprecated.details.replacement == "gpt-5-mini"
    assert deprecated.details.expected == "openai:gpt-5-mini"

    assert {:error, unsupported} = Models.init_chat_model("openai:gpt-4o-mini")
    assert unsupported.type == :unsupported_model
    assert unsupported.details.replacement == "gpt-5.4-mini"
    assert "gpt-5.5" in unsupported.details.supported
  end

  test "profile registry exposes deterministic checked-in profile introspection" do
    assert ProfileRegistry.providers() == [:anthropic, :fake, :google, :moonshot, :openai, :xai, :zai]

    all = ProfileRegistry.all()
    openai = ProfileRegistry.profiles(:openai)
    anthropic = ProfileRegistry.profiles(:anthropic)
    google = ProfileRegistry.profiles(:google)
    moonshot = ProfileRegistry.profiles(:moonshot)
    xai = ProfileRegistry.profiles(:xai)
    zai = ProfileRegistry.profiles(:zai)

    assert Enum.map(all, &{&1.provider, &1.id}) == Enum.sort(Enum.map(all, &{&1.provider, &1.id}))
    assert Enum.all?(openai, &(&1.provider == :openai))
    assert Enum.all?(anthropic, &(&1.provider == :anthropic))
    assert Enum.all?(google, &(&1.provider == :google))
    assert Enum.all?(moonshot, &(&1.provider == :moonshot))
    assert Enum.all?(xai, &(&1.provider == :xai))
    assert Enum.all?(zai, &(&1.provider == :zai))
    assert Enum.any?(openai, &(&1.id == "gpt-5.6-sol" and &1.tool_calling))
    assert Enum.any?(openai, &(&1.id == "gpt-5.6-terra" and &1.max_input_tokens == 1_050_000))

    assert Enum.any?(
             openai,
             &(&1.id == "gpt-5.6-luna" and &1.extra.input_price_per_mtok == 1.00)
           )

    assert Enum.any?(openai, &(&1.id == "gpt-5.5" and &1.tool_calling))
    assert Enum.any?(openai, &(&1.id == "gpt-5.4-mini" and &1.tool_calling))
    assert Enum.any?(openai, &(&1.id == "gpt-4.1" and &1.tool_calling))
    assert Enum.any?(openai, &(&1.id == "gpt-5.4-mini" and &1.tool_call_streaming))
    refute Enum.any?(openai, &(&1.id in ["gpt-4o", "gpt-4o-mini", "o3", "o4-mini"]))

    assert Enum.any?(
             anthropic,
             &(&1.id == "claude-opus-4-8" and &1.max_input_tokens == 1_000_000)
           )

    assert Enum.any?(
             anthropic,
             &(&1.id == "claude-fable-5" and &1.max_input_tokens == 1_000_000 and
                 &1.max_output_tokens == 128_000 and &1.extra.input_price_per_mtok == 10.00)
           )

    assert Enum.any?(
             anthropic,
             &(&1.id == "claude-mythos-5" and &1.status == :active and
                 &1.max_input_tokens == 1_000_000)
           )

    assert Enum.any?(anthropic, &(&1.id == "claude-opus-4-7" and &1.max_output_tokens == 128_000))
    assert Enum.any?(anthropic, &(&1.id == "claude-opus-4-6" and &1.max_output_tokens == 128_000))
    assert Enum.any?(anthropic, &(&1.id == "claude-sonnet-4-6" and &1.tool_calling))
    assert Enum.any?(anthropic, &(&1.id == "claude-haiku-4-5-20251001" and &1.tool_calling))

    refute Enum.any?(
             anthropic,
             &(&1.id in [
                 "claude-opus-4-20250514",
                 "claude-sonnet-4",
                 "claude-sonnet-4-20250514",
                 "claude-3-7-sonnet-20250219",
                 "claude-3-5-haiku-20241022"
               ])
           )

    assert Enum.any?(google, &(&1.id == "gemini-3.5-flash" and &1.structured_output))
    assert Enum.any?(google, &(&1.id == "gemini-3.1-pro-preview" and &1.structured_output))
    assert Enum.any?(moonshot, &(&1.id == "kimi-k3" and &1.max_input_tokens == 1_048_576))
    assert Enum.any?(moonshot, &(&1.id == "kimi-k3" and &1.extra.dynamic_tool_loading))
    assert Enum.any?(moonshot, &(&1.id == "kimi-k2.7-code" and &1.extra.thinking_modes == [:enabled]))
    assert Enum.any?(moonshot, &(&1.id == "kimi-k2.7-code-highspeed" and &1.extra.highspeed))
    assert Enum.any?(moonshot, &(&1.id == "kimi-k2.6" and &1.video_inputs))
    assert Enum.any?(moonshot, &(&1.id == "kimi-k2.6" and &1.tool_calling))
    assert Enum.any?(moonshot, &(&1.id == "kimi-k2.5" and &1.video_inputs))

    refute Enum.any?(
             google,
             &(&1.id in [
                 "gemini-2.0-flash",
                 "gemini-2.5-flash",
                 "gemini-2.5-pro",
                 "gemini-3-flash-preview"
               ])
           )

    refute Enum.any?(
             moonshot,
             &(&1.id in [
                 "kimi-latest",
                 "kimi-thinking-preview",
                 "kimi-k2-0905-preview",
                 "kimi-k2-thinking"
               ])
           )

    assert Enum.any?(xai, &(&1.id == "grok-4.5" and &1.tool_calling))
    assert Enum.any?(xai, &(&1.id == "grok-4.5" and &1.max_input_tokens == 500_000))
    assert Enum.any?(xai, &(&1.id == "grok-4.5" and &1.extra.input_price_per_mtok == 2.00))
    assert Enum.any?(xai, &(&1.id == "grok-4.5" and &1.extra.cached_input_price_per_mtok == 0.50))
    assert Enum.any?(xai, &(&1.id == "grok-4.5" and &1.extra.output_price_per_mtok == 6.00))
    assert Enum.any?(xai, &(&1.id == "grok-4.5" and &1.extra.reasoning_efforts == [:low, :medium, :high]))
    assert Enum.any?(xai, &(&1.id == "grok-4.3" and &1.tool_calling))
    assert Enum.any?(xai, &(&1.id == "grok-build-0.1" and &1.tool_calling))
    assert Enum.any?(xai, &(&1.id == "grok-4.20-multi-agent-0309" and &1.tool_calling))
    assert Enum.any?(xai, &(&1.id == "grok-4.5" and &1.tool_call_streaming))
    assert Enum.any?(xai, &(&1.id == "v1" and &1.extra.embedding_model))
    assert Enum.any?(zai, &(&1.id == "glm-5.2" and &1.max_input_tokens == 1_000_000))
    assert Enum.any?(zai, &(&1.id == "glm-5.2" and &1.max_output_tokens == 131_072))
    assert Enum.any?(zai, &(&1.id == "glm-5.2" and &1.extra.input_price_per_mtok == 1.40))

    refute Enum.any?(
             xai,
             &(&1.id in ["grok-2", "grok-2-vision", "grok-beta", "grok-vision-beta"])
           )
  end

  test "profile overrides and registries are explicit and preserve unknown keys in extra" do
    profile =
      Profile.new(%{
        "provider" => :fake,
        "id" => "chat",
        "supported_params" => [:temperature],
        "vendor_new_flag" => true
      })

    assert {:ok, override_model} = Models.init_chat_model("fake:chat", profile: profile)
    assert override_model.profile.supported_params == [:temperature]
    assert override_model.profile.extra["vendor_new_flag"] == true

    assert {:ok, registry_model} =
             Models.init_chat_model("fake:chat", profile_registry: ExplicitRegistry)

    assert registry_model.profile.name == "Custom fake chat"
    assert registry_model.profile.extra["unknown_future_key"] == "preserved"

    assert {:error, error} = Models.init_chat_model("fake:chat", profile_registry: __MODULE__)
    assert error.type == :invalid_profile_registry
  end

  test "profile preserves unknown keys without creating runtime atoms" do
    # Upstream reference:
    # - extra profile keys are accepted and survive validation.
    unknown_key = "future_profile_key_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unknown_key)
    end

    profile = Profile.new(%{"provider" => :fake, "id" => "chat", unknown_key => true})

    assert profile.extra[unknown_key] == true

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unknown_key)
    end
  end

  test "param policies are strict for known profiles and permissive for unknown profiles" do
    profile = Profile.new(provider: :fake, id: "strict", supported_params: [:max_output_tokens])

    assert {:error, error} =
             ParamPolicy.validate(profile, [temperature: 0.2], ParamPolicy.default_for(profile))

    assert error.type == :unsupported_model_param
    assert error.details.params == [:temperature]

    unknown = Profile.new(provider: :fake, id: "future", extra: %{unknown: true})

    assert :ok =
             ParamPolicy.validate(unknown, [temperature: 0.2], ParamPolicy.default_for(unknown))
  end

  test "warn param policy emits telemetry and still allows request construction" do
    profile = Profile.new(provider: :fake, id: "warn-profile", supported_params: [])
    ref = make_ref()
    parent = self()

    attach_id = "beam-weaver-param-warning-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      attach_id,
      [:beam_weaver, :models, :param_warning],
      &__MODULE__.handle_param_warning/4,
      {parent, ref}
    )

    on_exit(fn ->
      :telemetry.detach(attach_id)
    end)

    assert :ok =
             ParamPolicy.validate(profile, [temperature: 0.2], %ParamPolicy{mode: :warn},
               metadata: %{request_id: "warn-1"}
             )

    assert_receive {^ref, %{count: 1},
                    %{
                      provider: :fake,
                      model: "warn-profile",
                      params: [:temperature],
                      metadata: %{request_id: "warn-1"}
                    }},
                   1_000
  end

  test "provider escape hatches bypass standard param validation explicitly" do
    profile = Profile.new(provider: :fake, id: "strict-no-params", supported_params: [])

    assert :ok =
             ParamPolicy.validate(
               profile,
               [
                 extra_body: %{temperature: 0.2},
                 model_kwargs: %{future_param: true},
                 provider_opts: %{trace: "x"}
               ],
               %ParamPolicy{mode: :strict}
             )
  end

  test "profile capability flags are explicit" do
    assert {:ok, model} = Models.init_chat_model("openai:gpt-5.4")
    assert Profile.supports?(model.profile, :tool_calling)
    assert Profile.supports?(model.profile, :structured_output)
    refute Profile.supports?(model.profile, :video_outputs)
    assert Profile.supports_param?(model.profile, :response_format)
    refute Profile.supports_param?(model.profile, :responses, :max_tokens)
    assert Profile.supports_param?(model.profile, :chat_completions, :max_tokens)
  end

  def handle_param_warning(_event, measurements, metadata, {parent, ref}) do
    send(parent, {ref, measurements, metadata})
  end
end
