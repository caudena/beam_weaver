defmodule BeamWeaver.Provider.RegistryTest do
  use ExUnit.Case

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry
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

  test "checked-in profiles are deterministic, unique, and round-trip through the registry" do
    profiles = ProfileRegistry.all()
    identities = Enum.map(profiles, &{&1.provider, &1.id})

    assert ProfileRegistry.providers() == [
             :anthropic,
             :deepseek,
             :fake,
             :google,
             :moonshot,
             :openai,
             :xai,
             :zai
           ]

    assert identities == Enum.sort(identities)
    assert identities == Enum.uniq(identities)

    for profile <- profiles do
      assert is_binary(profile.id) and profile.id != ""
      assert profile.provider in ProfileRegistry.providers()
      assert {:ok, ^profile} = ProfileRegistry.fetch(profile.provider, profile.id)
    end

    matrix = Compatibility.matrix()
    assert Enum.map(matrix, &{&1.provider, &1.model}) == identities

    assert Enum.all?(matrix, fn row ->
             Map.keys(row.features) |> Enum.sort() == Enum.sort(Compatibility.features()) and
               Enum.all?(row.features, fn {_feature, supported?} -> is_boolean(supported?) end)
           end)
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

  test "deprecated Google models are not exposed through fallback profiles" do
    assert {:error, error} = Registry.profile(:google, "gemini-3-flash-preview")
    assert error.type == :deprecated_model
    assert error.details.expected == "google:gemini-3.5-flash"
  end

  test "limited-access Google models are not exposed through fallback profiles" do
    assert {:error, error} = Registry.profile(:google, "gemini-3.5-flash-cyber")
    assert error.type == :unsupported_model
    assert error.details.access == :codemender_limited_access
  end
end
