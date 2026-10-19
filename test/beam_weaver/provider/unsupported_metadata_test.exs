defmodule BeamWeaver.Provider.UnsupportedMetadataTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models

  # Moonshot, DeepSeek and Z.ai have no request metadata, so `metadata:` fails
  # before any request, when the model is created and on a call. It used to
  # be dropped without a word.
  for {id, api_opts} <- [
        {"moonshot:kimi-k2.6", []},
        {"deepseek:deepseek-v4-flash", []},
        {"deepseek:deepseek-v4-flash", [api: :responses]},
        {"zai:glm-5.2", []}
      ] do
    test "#{id}#{if api_opts != [], do: " (#{inspect(api_opts)})"} refuses metadata" do
      opts =
        [api_key: "k", transport: BeamWeaver.TestSupport.Conformance.Fakes.Transport, transport_opts: [parent: self()]] ++
          unquote(api_opts)

      assert {:error, %Error{}} = Models.init_chat_model(unquote(id), [metadata: %{"source" => "x"}] ++ opts)

      model = Models.init_chat_model!(unquote(id), opts)

      assert {:error, %Error{type: :unsupported_model_param, details: %{params: [:metadata]}}} =
               ChatModel.invoke(model, [Message.user("hi")], metadata: %{"source" => "x"})

      refute_received {:fake_transport_request, _request}
    end
  end

  test "a DeepSeek Responses model fails when it is created with an option its calls refuse" do
    assert {:error, %Error{type: :unsupported_model_param, details: %{params: [:store]}}} =
             Models.init_chat_model("deepseek:deepseek-v4-flash", api: :responses, api_key: "k", store: true)
  end
end
