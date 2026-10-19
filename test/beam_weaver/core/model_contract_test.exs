defmodule BeamWeaver.Core.ModelContractTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.EmbeddingModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defmodule InvokeOnlyChatModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct reply: "invoke"

    @impl true
    def invoke(%__MODULE__{reply: reply}, messages, _opts) do
      {:ok, Message.assistant("#{reply}: #{messages |> List.last() |> Message.text()}")}
    end
  end

  test "chat model wrapper rejects invalid provider responses" do
    model = %BeamWeaver.TestSupport.Conformance.Fakes.InvalidChatModel{}

    assert {:error, error} = ChatModel.invoke(model, [Message.user("hello")])
    assert error.type == :invalid_response
  end

  test "chat model facade falls back to invoke for stream-only callers" do
    model = %InvokeOnlyChatModel{}

    assert {:ok, stream} = ChatModel.stream(model, "hello")
    assert [%Message{role: :assistant, content: "invoke: hello"}] = Enum.to_list(stream)

    assert {:ok, message_stream} = ChatModel.stream(model, [Message.user("async hello")])
    assert [%Message{content: "invoke: async hello"}] = Enum.to_list(message_stream)
  end

  test "chat model facade batches ordered responses and typed stream events" do
    model = %InvokeOnlyChatModel{reply: "native"}

    assert [{:ok, first}, {:ok, second}] =
             ChatModel.batch(model, ["one", [Message.user("two")]])

    assert first.content == "native: one"
    assert second.content == "native: two"

    assert {:ok, events} = ChatModel.stream_events(model, "events", run_id: "run-1")

    assert [
             %Envelope{
               run_id: "run-1",
               node: "InvokeOnlyChatModel",
               event: %Events.Message{message: %Message{content: "native: events"}}
             },
             %Envelope{
               run_id: "run-1",
               node: "InvokeOnlyChatModel",
               event: %Events.Done{}
             }
           ] = Enum.to_list(events)
  end

  test "embedding wrapper rejects mismatched vector counts and invalid vectors" do
    assert {:error, count_error} =
             EmbeddingModel.embed_documents(
               %BeamWeaver.TestSupport.Conformance.Fakes.BadCountEmbeddingModel{},
               [
                 "one",
                 "two"
               ]
             )

    assert count_error.type == :invalid_embeddings

    assert {:error, vector_error} =
             EmbeddingModel.embed_query(
               %BeamWeaver.TestSupport.Conformance.Fakes.BadVectorEmbeddingModel{},
               "one"
             )

    assert vector_error.type == :invalid_embedding
  end

  test "embedding facade embeds a query and a matching document to the same vector" do
    model = %BeamWeaver.Models.FakeEmbeddingModel{dimensions: 3}

    assert {:ok, [doc_vector]} = EmbeddingModel.embed_documents(model, ["same"])
    assert {:ok, query_vector} = EmbeddingModel.embed_query(model, "same")
    assert doc_vector == query_vector
  end

  test "fake embedding model supports deterministic and random test-double modes" do
    deterministic = %BeamWeaver.Models.FakeEmbeddingModel{dimensions: 4}
    random = %BeamWeaver.Models.FakeEmbeddingModel{dimensions: 4, mode: :random}

    assert {:ok, stable_one} = EmbeddingModel.embed_query(deterministic, "seeded")
    assert {:ok, stable_two} = EmbeddingModel.embed_query(deterministic, "seeded")
    assert stable_one == stable_two
    assert length(stable_one) == 4

    assert {:ok, random_one} = EmbeddingModel.embed_query(random, "seeded")
    assert {:ok, random_two} = EmbeddingModel.embed_query(random, "seeded")
    assert length(random_one) == 4
    refute random_one == random_two
  end
end
