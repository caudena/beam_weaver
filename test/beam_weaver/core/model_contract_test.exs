defmodule BeamWeaver.Core.ModelContractTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.EmbeddingModel
  alias BeamWeaver.Core.LLM
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Prompt
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defmodule BadStreamLLM do
    @behaviour BeamWeaver.Core.LLM

    defstruct []

    @impl true
    def complete(_model, _prompt, _opts), do: {:ok, "fallback"}

    def stream(_model, _prompt, _opts), do: {:ok, ["good", %{bad: true}]}
  end

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
             ChatModel.batch(model, ["one", %Prompt.Value{text: "two"}])

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

  test "LLM wrapper rejects non-string completions" do
    assert {:error, error} =
             LLM.complete(%BeamWeaver.TestSupport.Conformance.Fakes.BadLLM{}, "hello")

    assert error.type == :invalid_response
  end

  test "LLM facade exposes native streaming and validates list chunks" do
    model = %BeamWeaver.Models.FakeLLM{stream_chunks: ["a", "b"]}

    assert {:ok, ["a", "b"]} = LLM.stream(model, "hello")

    assert {:error, error} = LLM.stream(%BadStreamLLM{}, "hello")
    assert error.type == :invalid_response
  end

  test "fake LLM can rotate response lists and stream selected responses as chunks" do
    model = BeamWeaver.Models.FakeLLM.new(responses: ["ab", "cd"])

    assert {:ok, "ab"} = LLM.complete(model, "first")
    assert {:ok, "cd"} = LLM.complete(model, "second")
    assert {:ok, "ab"} = LLM.complete(model, "third")

    assert {:ok, ["c", "d"]} = LLM.stream(model, "streamed")
    assert {:ok, ["a", "b"]} = LLM.stream(model, "async streamed")
  end

  test "LLM facade exposes invoke and batch" do
    model = %BeamWeaver.Models.FakeLLM{response: "completion", parent: self()}

    assert {:ok, "completion"} = LLM.invoke(model, "single")
    assert_received {:fake_llm_call, "single", []}

    assert [{:ok, "completion"}, {:ok, "completion"}] = LLM.batch(model, ["a", "b"])
    assert_received {:fake_llm_call, "a", []}
    assert_received {:fake_llm_call, "b", []}
  end
end
