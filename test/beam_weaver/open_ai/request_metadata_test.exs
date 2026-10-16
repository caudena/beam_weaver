defmodule BeamWeaver.OpenAI.RequestMetadataTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.TestSupport.Conformance.Fakes.Transport

  # OpenAI's API reference gives `metadata`, on both APIs, at most 16
  # key-value pairs, keys of at most 64 characters and string values of at
  # most 512. Anything else fails before the request, both when the model is
  # created and on a call.

  @pairs Map.new(1..16, &{"key_#{&1}", "value"})

  for api <- [:responses, :chat_completions] do
    describe "#{api} metadata" do
      for {name, metadata, message} <- [
            {"17 pairs", Map.put(@pairs, "key_17", "value"), "OpenAI metadata takes at most 16 key-value pairs"},
            {"a key longer than 64 characters", %{String.duplicate("k", 65) => "value"},
             ~s(OpenAI metadata key "#{String.duplicate("k", 64)}" <> ... is longer than 64 characters)},
            {"a value longer than 512 characters", %{note: String.duplicate("v", 513)},
             ~s(OpenAI metadata value for "note" is longer than 512 characters)},
            {"a value that isn't a string", %{order: 1001}, ~s(OpenAI metadata value for "order" must be a string)},
            {"a keyword list", [tier: "gold"], "OpenAI metadata must be a map of string keys to string values"}
          ] do
        test "with #{name} fails before the request" do
          metadata = unquote(Macro.escape(metadata))
          api = unquote(api)

          assert {:error, %Error{type: :unsupported_model_param, message: unquote(message)} = error} =
                   Models.init_chat_model("openai:gpt-4.1", api: api, api_key: "k", metadata: metadata)

          assert %{provider: :openai, model: "gpt-4.1", params: [:metadata]} = error.details

          model =
            Models.init_chat_model!("openai:gpt-4.1",
              api: api,
              api_key: "k",
              transport: Transport,
              transport_opts: [parent: self()]
            )

          assert {:error, %Error{type: :unsupported_model_param, message: unquote(message)}} =
                   ChatModel.invoke(model, [Message.user("ping")], metadata: metadata)

          refute_received {:fake_transport_request, _request}
        end
      end

      test "at the limits goes through, counted in characters" do
        # "é" is two bytes, so these strings are twice as long in bytes.
        metadata =
          Map.merge(Map.drop(@pairs, ["key_15", "key_16"]), %{
            String.duplicate("é", 64) => String.duplicate("é", 512),
            source: :summarization
          })

        model = Models.init_chat_model!("openai:gpt-4.1", api: unquote(api), api_key: "k", metadata: metadata)

        assert {:ok, %{"metadata" => sent}} = model.__struct__.request_body(model, [Message.user("ping")])
        assert map_size(sent) == 16
        assert sent["source"] == "summarization"
        assert sent[String.duplicate("é", 64)] == String.duplicate("é", 512)
      end
    end
  end
end
