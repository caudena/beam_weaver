defmodule BeamWeaver.Models.InitializerTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.LanguageModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Tokenizer.OpenAI, as: OpenAITokenizer
  alias BeamWeaver.Tokenizer.StaticVocabulary

  defmodule FixtureRegistry do
    def fetch(provider, id) do
      {:ok,
       Profile.new(
         provider: provider,
         id: id,
         tool_calling: true,
         streaming: true,
         supported_params: [:temperature, :max_output_tokens, :tools, :tool_choice, :stream, :stop]
       )}
    end
  end

  defmodule RejectingRegistry do
    def fetch(_provider, _id), do: {:error, BeamWeaver.Core.Error.new(:deprecated_model, "fixture retired")}
  end

  defp fixture_model(id, opts \\ []) do
    Models.init_chat_model(id, Keyword.put(opts, :profile_registry, FixtureRegistry))
  end

  defp fixture_model!(id, opts), do: fixture_model(id, opts) |> BeamWeaver.Policy.bang()

  test "provider families require explicit prefixes and preserve arbitrary model IDs" do
    for {provider, id, module} <- [
          {"google", "gemini-fixture", BeamWeaver.Google.ChatModel},
          {"moonshot", "kimi-fixture", BeamWeaver.Moonshot.ChatModel},
          {"zai", "glm-fixture", BeamWeaver.ZAI.ChatModel},
          {"deepseek", "deepseek-fixture", BeamWeaver.DeepSeek.ChatModel}
        ] do
      assert {:ok, model} = fixture_model(provider <> ":" <> id)
      assert model.__struct__ == module
      assert model.model == id
      assert {:error, error} = fixture_model(id)
      assert error.type == :invalid_model
      assert error.details.expected == provider <> ":" <> id
    end

    assert {:ok, %BeamWeaver.Anthropic.ChatModel{}} = fixture_model("claude-fixture")
    assert {:error, %{type: :unsupported_provider}} = fixture_model("kimi:kimi-fixture")
  end

  test "registry errors propagate instead of constructing a model" do
    assert {:error, %{type: :deprecated_model, message: "fixture retired"}} =
             Models.init_chat_model("fake:retired", profile_registry: RejectingRegistry)
  end

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
    assert {:ok, openai} = fixture_model("openai:gpt-fixture", temperature: 0.2)
    assert openai.__struct__ == BeamWeaver.OpenAI.ChatModel
    assert openai.model == "gpt-fixture"
    assert openai.temperature == 0.2

    assert {:ok, inferred} = fixture_model("gpt-fixture")
    assert inferred.__struct__ == BeamWeaver.OpenAI.ChatModel
  end

  test "init_chat_model can select the explicit Chat Completions implementation" do
    assert {:ok, chat_completions} =
             fixture_model("openai:gpt-fixture",
               api: :chat_completions,
               max_completion_tokens: 64
             )

    assert chat_completions.__struct__ == BeamWeaver.OpenAI.ChatCompletionsModel
    assert chat_completions.model == "gpt-fixture"
    assert chat_completions.max_completion_tokens == 64
  end

  test "init_chat_model rejects options the provider doesn't take" do
    assert {:error, typo} = fixture_model("openai:gpt-fixture", temprature: 0.2)
    assert typo.type == :unsupported_model_param
    assert typo.details.params == [:temprature]
    assert typo.details.provider == :openai

    assert {:error, foreign} = fixture_model("anthropic:claude-fixture", frequency_penalty: 0.5)
    assert foreign.details.params == [:frequency_penalty]
    refute foreign.message =~ "when you call"

    assert {:error, call_option} = fixture_model("openai:gpt-fixture", tools: [%{"type" => "web_search"}])
    assert call_option.details.params == [:tools]
    assert call_option.message =~ "pass :tools when you call the model"

    assert {:error, %{details: %{params: [:respones]}}} = fixture_model("fake:chat", respones: ["Hi"])
    assert {:ok, _fake} = fixture_model("fake:chat", responses: ["Hi"], api_key: "unused", timeout: 5_000)
    assert {:error, %{details: %{params: [:temperature]}}} = Models.init_embeddings("fake:embedding", temperature: 0.1)

    assert {:error, %{type: :invalid_provider_option, details: %{option: :api}}} =
             fixture_model("openai:gpt-fixture", api: :chat_completion)

    assert {:error, %{details: %{params: [:api]}}} =
             fixture_model("anthropic:claude-fixture", api: :responses)
  end

  test "an option error names the provider for every API" do
    for {id, opts, provider} <- [
          {"openai:gpt-fixture", [api: :chat_completions], :openai},
          {"xai:grok-fixture", [api: :chat_completions], :xai},
          {"xai:grok-fixture", [], :xai},
          {"deepseek:deepseek-fixture", [api: :responses], :deepseek}
        ] do
      assert {:error, %{type: :unsupported_model_param, details: %{provider: ^provider, params: [:temprature]}}} =
               fixture_model(id, [{:temprature, 0.2} | opts])
    end

    assert {:error, %{details: %{provider: :openai}}} =
             Models.init_embeddings("openai:text-embedding-3-small", temprature: 0.2)
  end

  test "init_chat_model takes the common names for the output cap and stop sequences" do
    assert %{max_tokens: 1_000, stop_sequences: ["END"]} =
             fixture_model!("anthropic:claude-fixture", max_output_tokens: 1_000, stop: ["END"])

    assert %{max_output_tokens: 1_000, stop_sequences: ["END"]} =
             fixture_model!("google:gemini-fixture", max_tokens: 1_000, stop: ["END"])

    assert %{max_tokens: 500} =
             fixture_model!("anthropic:claude-fixture", max_tokens: 500, max_output_tokens: 1_000)
  end

  test "init_chat_model keeps stream: true as the model's default" do
    for id <- [
          "openai:gpt-fixture",
          "anthropic:claude-fixture",
          "google:gemini-fixture",
          "xai:grok-fixture",
          "moonshot:kimi-fixture",
          "zai:glm-fixture",
          "deepseek:deepseek-fixture",
          "fake:chat"
        ] do
      assert %{streaming: true} = fixture_model!(id, stream: true)
    end

    assert %{streaming: true} = fixture_model!("openai:gpt-fixture", api: :chat_completions, stream: true)
    assert %{streaming: true} = fixture_model!("xai:grok-fixture", api: :chat_completions, stream: true)
  end

  test "init_options leaves an agent's call options for the calls" do
    opts = [temperature: 0.2, tool_choice: :auto, tools: [%{"type" => "web_search"}], stream: true, timeout: 5_000]

    assert Models.init_options("openai:gpt-fixture", opts) == [temperature: 0.2, stream: true, timeout: 5_000]
    assert Models.init_options("anthropic:claude-fixture", stop: ["END"], tool_choice: :auto) == [stop: ["END"]]
    assert Models.init_options("openai:gpt-fixture", temprature: 0.2) == [temprature: 0.2]
    assert Models.init_options("openai:gpt-fixture", tool_timeout: 30_000, timeout: 5_000) == [timeout: 5_000]
  end

  test "init_chat_model returns tagged errors for unsupported providers" do
    assert {:error, error} = fixture_model("unknown:model")
    assert error.type == :unsupported_provider
  end

  test "initializers reject a model option that is not an identifier" do
    for model <- [[foo: 1], [], %{foo: 1}, 123] do
      for init <- [&Models.init_chat_model/2, &Models.init_embeddings/2, &Models.init_decision_model/2] do
        assert {:error, %BeamWeaver.Core.Error{type: :invalid_model}} = init.([model: model], [])
        assert {:error, %BeamWeaver.Core.Error{type: :invalid_model}} = init.(%{model: model}, [])
        assert {:error, %BeamWeaver.Core.Error{type: :invalid_model}} = init.([], model: model)
      end
    end
  end

  test "fake chat initializer preserves opts and chat input normalization accepts strings" do
    parent = self()
    assert {:ok, model} = Models.init_chat_model("fake:chat", response: "pong", parent: parent)

    assert {:ok, %Message{content: "pong"}} = ChatModel.invoke(model, "ping")
    assert_receive {:fake_chat_model_call, [%Message{role: :user, content: "ping"}], _opts}
  end

  test "init_embeddings accepts provider-prefixed identifiers" do
    assert {:ok, model} = Models.init_embeddings("fake:embedding", dimensions: 4)
    assert model.__struct__ == BeamWeaver.Models.FakeEmbeddingModel
    assert model.dimensions == 4
    assert {:ok, vector} = BeamWeaver.Core.EmbeddingModel.embed_query(model, "hello")
    assert length(vector) == 4

    assert {:ok, %{mode: :random}} = Models.init_embeddings("fake:embedding", mode: :random)
  end

  test "token counting is explicit through functions, MFA, model callbacks, or approximate fallback" do
    # About four characters per token, plus three per message for its role and framing.
    assert {:ok, 3} = LanguageModel.count_tokens(:approximate, "hello world")
    assert {:ok, 7} = LanguageModel.count_tokens(fn _ -> 7 end, "ignored")
    assert {:ok, 6} = LanguageModel.count_tokens({TokenCounter, :count, [3]}, "hello world")

    assert {:ok, model} = Models.init_chat_model("fake:chat")
    assert {:ok, 7} = LanguageModel.count_tokens(model, [Message.user("hello world")])
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
    tokenizer = %OpenAITokenizer{encoding: :o200k_base}

    assert {:ok, [24_912, 2375]} = BeamWeaver.Tokenizer.encode(tokenizer, "hello world")
    assert {:ok, "hello world"} = BeamWeaver.Tokenizer.decode(tokenizer, [24_912, 2375])
    assert {:ok, 2} = BeamWeaver.Tokenizer.count_tokens(tokenizer, "hello world")

    assert {:ok, ["hello", " world"]} =
             BeamWeaver.Tokenizer.split_tokens(tokenizer, "hello world")

    assert {:ok, [15_339, 1917]} =
             BeamWeaver.Tokenizer.encode(%OpenAITokenizer{encoding: :cl100k_base}, "hello world")

    profile = Profile.new(provider: :openai, id: "fixture", tokenizer: :o200k_base)
    assert {:ok, %OpenAITokenizer{} = configured_tokenizer} = Models.tokenizer_for(profile)
    model = Models.init_chat_model!("openai:fixture", profile: profile, tokenizer: configured_tokenizer)
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

  test "OpenAI tokenizer matches multilingual token-count fixtures" do
    text = "表情符号是\n🦜🔗"

    expected = %{cl100k_base: 12, o200k_base: 11}

    for {encoding, count} <- expected do
      assert {:ok, ^count} =
               BeamWeaver.Tokenizer.count_tokens(%OpenAITokenizer{encoding: encoding}, text)
    end
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

    params = [temperature: 0.2, metadata: %{user_id: "user_123"}]
    assert :ok = ParamPolicy.validate(profile, params, %ParamPolicy{mode: :warn})

    # The event names the params, never their values.
    assert_receive {^ref, %{count: 2}, %{model: "warn-profile"} = metadata}, 1_000
    assert metadata == %{provider: :fake, model: "warn-profile", params: [:temperature, :metadata]}
  end

  test "provider escape hatches bypass standard param validation explicitly" do
    profile = Profile.new(provider: :fake, id: "strict-no-params", supported_params: [])

    assert :ok =
             ParamPolicy.validate(
               profile,
               [
                 extra_body: %{temperature: 0.2, future_param: true},
                 provider_opts: %{trace: "x"}
               ],
               %ParamPolicy{mode: :strict}
             )
  end

  def handle_param_warning(_event, measurements, metadata, {parent, ref}) do
    send(parent, {ref, measurements, metadata})
  end
end
