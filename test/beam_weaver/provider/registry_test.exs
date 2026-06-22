defmodule BeamWeaver.Provider.RegistryTest do
  use ExUnit.Case

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Provider.Compatibility
  alias BeamWeaver.Provider.Registry

  defmodule DummyChatModel do
    @behaviour ChatModel

    defstruct [:model, :profile, :parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, _opts) do
      if parent, do: send(parent, {:dummy_chat_invoked, messages})
      {:ok, Message.assistant("dummy")}
    end
  end

  defmodule DummyProvider do
    @behaviour BeamWeaver.Provider.Adapter

    @profile Profile.new(%{
               provider: :dummy,
               id: "dummy-chat",
               name: "Dummy chat",
               text_inputs: true,
               text_outputs: true,
               streaming: true,
               usage_metadata: true,
               supported_params: [:stream]
             })

    @impl true
    def provider, do: :dummy

    @impl true
    def profiles, do: [@profile]

    @impl true
    def profile("dummy-chat"), do: {:ok, @profile}

    def profile(model),
      do: {:ok, Profile.new(provider: :dummy, id: model, extra: %{unknown: true})}

    @impl true
    def chat_model(_opts), do: {:ok, DummyChatModel}

    @impl true
    def infer_provider?("dummy-" <> _rest, :chat), do: true
    def infer_provider?(_model, _kind), do: false

    @impl true
    def default_model(:chat), do: "dummy-chat"
    def default_model(_kind), do: nil
  end

  setup do
    Registry.unregister(:dummy)

    on_exit(fn ->
      Registry.unregister(:dummy)
    end)

    :ok
  end

  test "built-in provider surface exposes expected provider IDs and profiles" do
    assert Registry.providers() == [:anthropic, :fake, :google, :moonshot, :openai, :xai, :zai]
    assert {:ok, profile} = Registry.profile(:google, "gemini-3.5-flash")
    assert profile.provider == :google
    assert profile.structured_output
    assert profile.reasoning_output

    assert {:ok, moonshot} = Registry.profile(:moonshot, "kimi-k2.6")
    assert moonshot.provider == :moonshot
    assert moonshot.chat_completions_api
    refute moonshot.responses_api

    assert {:ok, kimi_code} = Registry.profile(:moonshot, "kimi-k2.7-code")
    assert kimi_code.provider == :moonshot
    assert kimi_code.extra.thinking_modes == [:enabled]
    assert kimi_code.extra.model_category == :coding

    assert {:ok, glm} = Registry.profile(:zai, "glm-5.2")
    assert glm.provider == :zai
    assert glm.chat_completions_api
    assert glm.max_input_tokens == 1_000_000
    assert glm.max_output_tokens == 131_072
    assert glm.extra.input_price_per_mtok == 1.40
  end

  test "runtime providers can be registered, inferred, initialized, and unregistered" do
    assert :ok = Registry.register(:dummy, DummyProvider)
    assert {:ok, entry} = Registry.fetch(:dummy)
    assert entry.adapter == DummyProvider
    assert Registry.infer_provider("dummy-chat", :chat) == :dummy

    assert {:ok, model} = Models.init_chat_model("dummy:dummy-chat", parent: self())
    assert %DummyChatModel{model: "dummy-chat"} = model

    assert {:ok, %Message{content: "dummy"}} = ChatModel.invoke(model, "ping")
    assert_receive {:dummy_chat_invoked, [%Message{content: "ping"}]}

    assert :ok = Registry.unregister(:dummy)
    assert {:error, %Error{type: :unsupported_provider}} = Registry.fetch(:dummy)
  end

  test "provider config is loaded through the registry" do
    BeamWeaver.TestSupport.ConfigHelper.put_config(:providers, [DummyProvider])

    assert :ok = Registry.load_from_config!()
    assert {:ok, entry} = Registry.fetch(:dummy)
    assert entry.provider == :dummy
  end

  test "compatibility matrix includes normalized capability rows" do
    assert Enum.any?(Compatibility.matrix(), fn row ->
             row.provider == :google and row.model == "gemini-3.5-flash" and
               row.features.structured_output and row.features.reasoning
           end)

    refute Compatibility.supports?({:google, "gemini-3.5-flash"}, :image_output)
    assert Compatibility.supports?({:google, "gemini-3.1-pro-preview"}, :tool_calling)
    assert Compatibility.supports?({:moonshot, "kimi-k2.7-code"}, :tool_calling)
    assert Compatibility.supports?({:moonshot, "kimi-k2.7-code-highspeed"}, :video_input)
    assert Compatibility.supports?({:moonshot, "kimi-k2.6"}, :video_input)
    assert Compatibility.supports?({:moonshot, "kimi-k2.6"}, :reasoning)
    assert Compatibility.supports?({:moonshot, "kimi-k2.5"}, :reasoning)
    assert Compatibility.supports?({:zai, "glm-5.2"}, :tool_calling)
    assert Compatibility.supports?({:zai, "glm-5.2"}, :structured_output)
    assert Compatibility.supports?({:zai, "glm-5.2"}, :reasoning)
    refute Compatibility.supports?({:xai, "grok-2"}, :reasoning)
  end

  test "deprecated Google models are not exposed through fallback profiles" do
    assert {:error, error} = Registry.profile(:google, "gemini-3-flash-preview")
    assert error.type == :deprecated_model
    assert error.details.expected == "google:gemini-3.5-flash"
  end
end
