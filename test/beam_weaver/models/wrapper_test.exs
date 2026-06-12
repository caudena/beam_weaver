defmodule BeamWeaver.Models.WrapperTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.EmbeddingModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.LLM
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models
  alias BeamWeaver.Models.InvocationMetadata
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defmodule RecordingModel do
    @behaviour ChatModel

    defstruct [:parent, reply: "ok"]

    @impl true
    def invoke(%__MODULE__{} = model, messages, opts) do
      if model.parent, do: send(model.parent, {:model_call, messages, opts})
      {:ok, Message.assistant(model.reply)}
    end
  end

  defmodule StructuredToolModel do
    @behaviour ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, _messages, opts) do
      if parent do
        send(parent, {:structured_tools, Enum.map(Keyword.get(opts, :tools, []), &Tool.name/1)})
      end

      {:ok,
       Message.assistant("",
         tool_calls: [
           %{id: "call_answer", name: "answer", args: %{"value" => "accepted"}}
         ]
       )}
    end
  end

  defmodule ProviderStructuredModel do
    @behaviour ChatModel

    defstruct [:parent, supports_structured_output: true]

    @impl true
    def invoke(%__MODULE__{parent: parent}, _messages, opts) do
      if parent,
        do: send(parent, {:provider_response_format, Keyword.get(opts, :response_format)})

      {:ok, Message.assistant("", metadata: %{parsed: %{"value" => "native"}})}
    end
  end

  test "bind_tools passes tool declarations through model options" do
    parent = self()

    tool =
      Tool.from_function!(
        name: "search",
        description: "Search docs",
        input_schema: %{"type" => "object"},
        handler: fn args, _opts -> args end
      )

    model = Models.bind_tools(%RecordingModel{parent: parent}, [tool], temperature: 0.1)

    assert {:ok, %Message{content: "ok"}} =
             ChatModel.invoke(model, [Message.user("hello")], timeout: 100)

    assert_received {:model_call, [%Message{role: :user}], opts}
    assert Keyword.fetch!(opts, :temperature) == 0.1
    assert Enum.map(Keyword.fetch!(opts, :tools), &Tool.name/1) == ["search"]
  end

  test "with_structured_output parses structured tool calls into metadata" do
    schema = %{
      "title" => "answer",
      "type" => "object",
      "required" => ["value"],
      "properties" => %{"value" => %{"type" => "string"}}
    }

    model =
      %StructuredToolModel{parent: self()}
      |> Models.with_structured_output(schema)

    assert {:ok, %Message{metadata: metadata}} =
             ChatModel.invoke(model, [Message.user("answer")], [])

    assert metadata.structured_response == %{"value" => "accepted"}
    assert_received {:structured_tools, ["answer"]}
  end

  test "with_structured_output uses provider-native strategy when model profile supports it" do
    schema = %{
      "title" => "answer",
      "type" => "object",
      "required" => ["value"],
      "properties" => %{"value" => %{"type" => "string"}}
    }

    model =
      %ProviderStructuredModel{parent: self()}
      |> Models.with_structured_output(schema)

    assert {:ok, %Message{metadata: %{structured_response: %{"value" => "native"}}}} =
             ChatModel.invoke(model, [Message.user("answer")], [])

    assert_received {:provider_response_format, %{name: "answer", schema: ^schema}}
  end

  test "cached models avoid repeated underlying invocations for identical inputs" do
    cache = BeamWeaver.Cache.ETS.new(visibility: :private)
    parent = self()

    model =
      %RecordingModel{parent: parent, reply: "cached"}
      |> Models.cached(cache)

    assert {:ok, %Message{content: "cached"}} =
             ChatModel.invoke(model, [Message.user("hello")], temperature: 0.2)

    assert {:ok, %Message{content: "cached"}} =
             ChatModel.invoke(model, [Message.user("hello")], temperature: 0.2)

    assert_received {:model_call, [%Message{role: :user}], _opts}
    refute_received {:model_call, _messages, _opts}
  end

  test "unwrapped chat models do not use cache state" do
    parent = self()
    model = %RecordingModel{parent: parent, reply: "uncached"}

    assert {:ok, %Message{content: "uncached"}} = ChatModel.invoke(model, [Message.user("hello")])
    assert {:ok, %Message{content: "uncached"}} = ChatModel.invoke(model, [Message.user("hello")])

    assert_received {:model_call, [%Message{role: :user}], _opts}
    assert_received {:model_call, [%Message{role: :user}], _opts}
  end

  test "cached models include provider options in the cache key" do
    cache = BeamWeaver.Cache.ETS.new(visibility: :private)
    parent = self()

    model =
      %RecordingModel{parent: parent, reply: "cached"}
      |> Models.cached(cache)

    assert {:ok, %Message{content: "cached"}} =
             ChatModel.invoke(model, [Message.user("hello")], temperature: 0.2)

    assert {:ok, %Message{content: "cached"}} =
             ChatModel.invoke(model, [Message.user("hello")], temperature: 0.9)

    assert_received {:model_call, [%Message{role: :user}], opts_1}
    assert_received {:model_call, [%Message{role: :user}], opts_2}
    assert Keyword.fetch!(opts_1, :temperature) != Keyword.fetch!(opts_2, :temperature)
  end

  test "cached chat model keys ignore transient message ids and runtime opts" do
    cache = BeamWeaver.Cache.ETS.new(visibility: :private)
    parent = self()

    model =
      %RecordingModel{parent: parent, reply: "cached"}
      |> Models.cached(cache)

    assert {:ok, %Message{content: "cached"}} =
             ChatModel.invoke(model, [Message.user("hello", id: "msg-1")],
               task_supervisor: :ignored,
               rate_limiter: :ignored
             )

    assert {:ok, %Message{content: "cached"}} =
             ChatModel.invoke(model, [Message.user("hello", id: "msg-2")],
               callbacks: [],
               rate_limiter: :other
             )

    assert_received {:model_call, [%Message{role: :user, id: "msg-1"}], _opts}
    refute_received {:model_call, _messages, _opts}
  end

  test "cached chat model keys are stable when swapping equivalent cache adapters" do
    first_cache = BeamWeaver.Cache.ETS.new(visibility: :private)
    parent = self()

    first_model =
      %RecordingModel{parent: parent, reply: "cached"}
      |> Models.cached(first_cache)

    assert {:ok, %Message{content: "cached"}} =
             ChatModel.invoke(first_model, [Message.user("hi")])

    assert_received {:model_call, _messages, _opts}

    second_cache = BeamWeaver.Cache.ETS.new(visibility: :private)

    entries =
      for {{namespace, key}, entry} <- :ets.tab2list(first_cache.table), into: %{} do
        {{namespace, key}, entry.value}
      end

    assert :ok = BeamWeaver.Cache.set_many(second_cache, entries)

    second_model =
      %RecordingModel{parent: parent, reply: "uncached"}
      |> Models.cached(second_cache)

    assert {:ok, %Message{content: "cached"}} =
             ChatModel.invoke(second_model, [Message.user("hi")])

    refute_received {:model_call, _messages, _opts}
  end

  test "cached chat model hits zero usage cost metadata" do
    cache = BeamWeaver.Cache.ETS.new(visibility: :private)

    model =
      %BeamWeaver.Models.FakeChatModel{
        response: "cached",
        usage_metadata: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
      }
      |> Models.cached(cache)

    assert {:ok, %Message{usage_metadata: %{total_tokens: 2}}} =
             ChatModel.invoke(model, [Message.user("hi")])

    assert {:ok, %Message{usage_metadata: metadata}} =
             ChatModel.invoke(model, [Message.user("hi")])

    assert metadata.total_cost == 0
    assert metadata["total_cost"] == 0
  end

  test "cached LLM completions support sync, batch, and async facades" do
    cache = BeamWeaver.Cache.ETS.new()
    parent = self()

    llm =
      %BeamWeaver.Models.FakeLLM{response: "completion", parent: parent}
      |> Models.cached(cache)

    assert {:ok, "completion"} = LLM.complete(llm, "prompt")
    assert {:ok, "completion"} = LLM.complete(llm, "prompt")
    assert_received {:fake_llm_call, "prompt", []}
    refute_received {:fake_llm_call, _prompt, _opts}

    assert [{:ok, "completion"}, {:ok, "completion"}] = LLM.batch(llm, ["prompt", "other"])
    assert_received {:fake_llm_call, "other", []}
    refute_received {:fake_llm_call, "prompt", _opts}

    assert [{:ok, "completion"}, {:ok, "completion"}] =
             llm
             |> LLM.async_batch(["prompt", "other"])
             |> BeamWeaver.Core.Async.await_batch()

    refute_received {:fake_llm_call, _prompt, _opts}
  end

  test "cached LLM streams cache the joined completion and replay as one chunk" do
    cache = BeamWeaver.Cache.ETS.new()
    parent = self()

    llm =
      %BeamWeaver.TestSupport.Conformance.Fakes.LLM{
        stream_chunks: ["stream", "ed"],
        parent: parent
      }
      |> Models.cached(cache)

    assert {:ok, ["stream", "ed"]} = LLM.stream(llm, "prompt")
    assert_received {:fake_llm_stream, "prompt", []}

    assert {:ok, ["streamed"]} = LLM.stream(llm, "prompt")
    refute_received {:fake_llm_stream, _prompt, _opts}

    assert {:ok, ["streamed"]} =
             llm
             |> LLM.async_stream("prompt")
             |> BeamWeaver.Core.Async.await()

    refute_received {:fake_llm_stream, _prompt, _opts}
  end

  test "cached model event streams replay semantic events on warm cache hits" do
    # Upstream reference:
    # - cache-hit stream replay emits lifecycle-equivalent events.
    cache = BeamWeaver.Cache.ETS.new(visibility: :private)
    parent = self()

    model =
      %RecordingModel{parent: parent, reply: "cached"}
      |> Models.cached(cache)

    assert {:ok, cold_stream} = ChatModel.stream_events(model, [Message.user("hello")])

    assert [
             %Envelope{event: %Events.Debug{payload: %{type: :cache_replay, cache: :miss}}},
             %Envelope{event: %Events.Message{message: %Message{content: "cached"}}},
             %Envelope{event: %Events.Done{}}
           ] = Enum.to_list(cold_stream)

    assert {:ok, warm_stream} = ChatModel.stream_events(model, [Message.user("hello")])

    assert [
             %Envelope{event: %Events.Debug{payload: %{type: :cache_replay, cache: :hit}}},
             %Envelope{event: %Events.Message{message: %Message{content: "cached"}}},
             %Envelope{event: %Events.Done{}}
           ] = Enum.to_list(warm_stream)

    assert_received {:model_call, [%Message{role: :user}], _opts}
    refute_received {:model_call, _messages, _opts}
  end

  test "fake chat model event streams expose normalized invocation metadata" do
    tool =
      Tool.from_function!(
        name: "lookup",
        description: "Lookup",
        input_schema: %{type: "object"},
        handler: fn input, _opts -> input end
      )

    model = %BeamWeaver.Models.FakeChatModel{
      response: "fake",
      usage_metadata: %{input_tokens: 2, output_tokens: 1, total_tokens: 3}
    }

    assert {:ok, stream} =
             ChatModel.stream_events(model, [Message.user("hello")],
               tools: [tool],
               tool_choice: :auto,
               response_format: %{type: :json_object},
               temperature: 0.2
             )

    events = Enum.to_list(stream)

    assert %Envelope{metadata: metadata, event: %Events.Done{usage: usage}} =
             Enum.find(events, &match?(%Envelope{event: %Events.Done{}}, &1))

    assert %InvocationMetadata{} = metadata.invocation_metadata
    assert metadata.model_provider == :fake
    assert metadata.model_name == "fake-chat"
    assert metadata.bound_tools == ["lookup"]
    assert metadata.tool_choice == :auto
    assert metadata.invocation_params.temperature == 0.2
    refute Map.has_key?(metadata.invocation_params, :tools)
    refute Map.has_key?(metadata.invocation_params, :response_format)
    assert usage == %{input_tokens: 2, output_tokens: 1, total_tokens: 3}
  end

  test "cached models require an explicit cache adapter" do
    model =
      %RecordingModel{reply: "cached"}
      |> Models.cached(true)

    assert {:error, %Error{type: :explicit_cache_required}} =
             ChatModel.invoke(model, [Message.user("hello")], [])
  end

  test "wrapped chat models are executable through the runnable facade" do
    model =
      %RecordingModel{reply: "runnable"}
      |> Models.bind_tools([])

    assert {:ok, %Message{content: "runnable"}} =
             BeamWeaver.Runnable.invoke(model, [Message.user("hello")])
  end

  test "fake LLM and embedding models are deterministic test doubles" do
    llm = %BeamWeaver.Models.FakeLLM{response: "completion", parent: self()}

    assert {:ok, "completion"} = LLM.complete(llm, "prompt", temperature: 0.1)
    assert_received {:fake_llm_call, "prompt", [temperature: 0.1]}

    assert {:ok, "completion"} = LLM.complete(llm, "prompt", temperature: 0.1)
    assert_received {:fake_llm_call, "prompt", [temperature: 0.1]}

    assert {:ok, "completion"} =
             llm
             |> LLM.async_complete("prompt", temperature: 0.1)
             |> BeamWeaver.Core.Async.await()

    assert_received {:fake_llm_call, "prompt", [temperature: 0.1]}

    embeddings = %BeamWeaver.Models.FakeEmbeddingModel{dimensions: 4}

    assert {:ok, [doc_vector]} = EmbeddingModel.embed_documents(embeddings, ["doc"], [])
    assert {:ok, query_vector} = EmbeddingModel.embed_query(embeddings, "doc", [])
    assert length(doc_vector) == 4
    assert doc_vector == query_vector
  end

  test "fake chat model simulates tool calls, structured output, usage, streams, and validation" do
    profile =
      BeamWeaver.Models.Profile.new(%{
        provider: :fake,
        id: "chat",
        supported_params: [:tools, :response_format],
        structured_output: true,
        tool_calling: true
      })

    model = %BeamWeaver.Models.FakeChatModel{
      response: "needs tool",
      profile: profile,
      usage_metadata: %{input_tokens: 1, output_tokens: 2, total_tokens: 3},
      tool_calls: [%{id: "call_1", name: "lookup", args: %{query: "hello"}}],
      structured_response: %{"value" => "ok"},
      stream_chunks: [Message.assistant("chunk")]
    }

    assert {:ok, %Message{tool_calls: [%{name: "lookup"}], usage_metadata: usage}} =
             ChatModel.invoke(model, [Message.user("hello")], tools: [])

    assert usage.total_tokens == 3

    assert {:ok, %Message{metadata: %{parsed: %{"value" => "ok"}}}} =
             ChatModel.invoke(model, [Message.user("hello")],
               response_format: %{name: "Answer", schema: %{"type" => "object"}}
             )

    assert {:ok, stream} = model.__struct__.stream(model, [Message.user("hello")], [])
    assert Enum.to_list(stream) == [Message.assistant("chunk")]

    strict = %{model | profile: %{profile | supported_params: []}}

    assert {:error, %Error{type: :unsupported_model_param}} =
             ChatModel.invoke(strict, [Message.user("hello")], temperature: 0.5)
  end
end
