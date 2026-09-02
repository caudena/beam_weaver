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
  end

  test "init_chat_model returns tagged errors for unsupported providers" do
    assert {:error, error} = Models.init_chat_model("unknown:model")
    assert error.type == :unsupported_provider
  end

  test "init_chat_model accepts explicit Google identifiers but not bare Gemini aliases" do
    for model <- [
          "gemini-3.8-flash",
          "gemini-3.7-flash",
          "gemini-3.6-flash",
          "gemini-3.5-flash-lite",
          "gemini-3.5-flash",
          "gemini-3.1-pro-preview",
          "gemini-3.1-flash-lite"
        ] do
      assert {:ok, %BeamWeaver.Google.ChatModel{model: ^model}} =
               Models.init_chat_model("google:" <> model)
    end

    assert {:error, error} = Models.init_chat_model("gemini-3.5-flash")
    assert error.type == :invalid_model
    assert error.details.expected == "google:gemini-3.5-flash"
  end

  test "latest Gemini models reject deprecated generation controls" do
    for model <- [
          "google:gemini-3.8-flash",
          "google:gemini-3.7-flash",
          "google:gemini-3.6-flash",
          "google:gemini-3.5-flash-lite"
        ] do
      assert {:ok, configured} = Models.init_chat_model(model, temperature: 0.2)

      assert {:error, error} =
               BeamWeaver.Google.ChatModel.request_body(configured, [Message.user("hello")])

      assert error.type == :unsupported_model_param
      assert error.details.params == [:temperature]

      assert {:ok, configured} = Models.init_chat_model(model, thinking_budget: 512)

      assert {:error, error} =
               BeamWeaver.Google.ChatModel.request_body(configured, [Message.user("hello")])

      assert error.type == :unsupported_model_param
      assert error.details.params == [:thinking_budget]
    end
  end

  test "Gemini 3.8 Flash resolves to its exact production profile" do
    assert {:ok, profile} = ProfileRegistry.fetch(:google, "gemini-3.8-flash")

    assert profile.name == "Gemini 3.8 Flash"
    assert profile.status == :active
    assert profile.release_date == "2026-09-02"
    assert profile.max_input_tokens == 1_048_576
    assert profile.max_output_tokens == 65_536
    assert profile.extra.default_thinking_level == :medium
    assert profile.extra.thinking_levels == [:low, :medium, :high]
    assert profile.extra.input_price_per_mtok == 0.75
    assert profile.extra.output_price_per_mtok == 3.75
    assert profile.extra.computer_use == :preview
  end

  test "init_chat_model rejects limited-access Gemini models before family fallback" do
    assert {:error, error} = Models.init_chat_model("google:gemini-3.5-flash-cyber")
    assert error.type == :unsupported_model
    assert error.details.provider == :google
    assert error.details.model == "gemini-3.5-flash-cyber"
    assert error.details.access == :codemender_limited_access
    assert error.details.reason =~ "governments and trusted partners"
  end

  test "init_chat_model accepts explicit Moonshot identifiers but not Kimi aliases" do
    for model <- ["kimi-k3", "kimi-k2.7-code", "kimi-k2.7-code-highspeed", "kimi-k2.6", "kimi-k2.5"] do
      assert {:ok, %BeamWeaver.Moonshot.ChatModel{model: ^model}} =
               Models.init_chat_model("moonshot:" <> model)
    end

    assert {:error, bare} = Models.init_chat_model("kimi-k2.6")
    assert bare.type == :invalid_model
    assert bare.details.expected == "moonshot:kimi-k2.6"

    assert {:error, unsupported} = Models.init_chat_model("kimi:kimi-k2.6")
    assert unsupported.type == :unsupported_provider
  end

  test "init_chat_model accepts explicit Z.ai identifiers but not bare GLM aliases" do
    for model <- ["glm-5.3", "glm-5.3-flash", "glm-5.2"] do
      assert {:ok, %BeamWeaver.ZAI.ChatModel{model: ^model}} =
               Models.init_chat_model("zai:" <> model)
    end

    assert {:error, bare} = Models.init_chat_model("glm-5.2")
    assert bare.type == :invalid_model
    assert bare.details.expected == "zai:glm-5.2"

    assert {:error, unsupported} = Models.init_chat_model("zai:glm-5.1")
    assert unsupported.type == :unsupported_model
    assert unsupported.details.expected == "zai:glm-5.3"
  end

  test "init_chat_model rejects discontinued Moonshot identifiers with replacements" do
    assert {:error, error} = Models.init_chat_model("moonshot:kimi-latest")

    assert error.type == :deprecated_model
    assert error.details.provider == :moonshot
    assert error.details.model == "kimi-latest"
    assert error.details.replacement == "kimi-k3"
    assert error.details.expected == "moonshot:kimi-k3"
  end

  test "Google stable 2.5 identifiers remain available without announced shutdowns" do
    for model <- ["gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-pro"] do
      assert {:ok, initialized} = Models.init_chat_model("google:" <> model)
      assert initialized.model == model
    end
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

    assert {:error, error} =
             ParamPolicy.validate(gpt5_family, [reasoning: %{effort: "low"}], nil, api: :chat_completions)

    assert error.type == :unsupported_model_param
    assert error.details.params == [:reasoning]

    assert {:ok, unknown} = ProfileRegistry.fetch(:openai, "future-non-family-model")
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

  def handle_param_warning(_event, measurements, metadata, {parent, ref}) do
    send(parent, {ref, measurements, metadata})
  end
end
