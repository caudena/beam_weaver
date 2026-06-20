defmodule BeamWeaver.Models.RateLimitedTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Cache.ETS, as: CacheETS
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.RateLimiter

  defmodule Limiter do
    defstruct [:parent]

    def acquire(%__MODULE__{parent: parent}, amount, opts) do
      send(parent, {:acquire, amount, opts})
      :ok
    end
  end

  defmodule Model do
    @behaviour ChatModel

    defstruct []

    def invoke(%__MODULE__{}, _messages, _opts), do: {:ok, Message.assistant("ok")}
  end

  defmodule RecordingModel do
    @behaviour ChatModel

    defstruct [:parent]

    def invoke(%__MODULE__{parent: parent}, _messages, _opts) do
      send(parent, :model_invoked)
      {:ok, Message.assistant("ok")}
    end
  end

  defmodule StreamingModel do
    @behaviour ChatModel

    defstruct [:parent]

    def invoke(%__MODULE__{parent: parent}, _messages, _opts) do
      send(parent, :invoke_fallback)
      {:ok, Message.assistant("fallback")}
    end

    def stream(%__MODULE__{parent: parent}, _messages, _opts) do
      send(parent, :model_streamed)
      {:ok, [Message.assistant("chunk")]}
    end
  end

  defmodule LazyStreamingModel do
    @behaviour ChatModel

    defstruct [:parent]

    def invoke(%__MODULE__{parent: parent}, _messages, _opts) do
      send(parent, :lazy_invoke_fallback)
      {:ok, Message.assistant("fallback")}
    end

    def stream(%__MODULE__{parent: parent}, _messages, _opts) do
      send(parent, :lazy_model_streamed)
      {:ok, [Message.assistant("chunk")]}
    end
  end

  defmodule RejectingLimiter do
    defstruct [:parent]

    def acquire(%__MODULE__{parent: parent}, amount, opts) do
      send(parent, {:rejected_acquire, amount, opts})
      {:error, RateLimiter.Error.new(:rate_limited, "not enough tokens")}
    end
  end

  test "rate-limited model explicitly acquires before model invocation" do
    parent = self()

    model =
      %Model{}
      |> Models.with_rate_limiter(
        limiter: %Limiter{parent: parent},
        amount: 2,
        key: {:openai, "gpt"}
      )

    assert {:ok, %Message{content: "ok"}} = ChatModel.invoke(model, [Message.user("hi")])
    assert_received {:acquire, 2, opts}
    assert opts[:key] == {:openai, "gpt"}
  end

  test "rate-limited model requires an explicit limiter when policy opts in without one" do
    model =
      %Model{}
      |> Models.with_rate_limiter(amount: 1, key: {:openai, "gpt"})

    assert {:error, %Error{type: :rate_limiter_required}} =
             ChatModel.invoke(model, [Message.user("hi")])
  end

  test "rate-limited model does not invoke the wrapped model when acquisition fails" do
    parent = self()

    model =
      %RecordingModel{parent: parent}
      |> Models.with_rate_limiter(
        limiter: %RejectingLimiter{parent: parent},
        amount: 3,
        key: {:openai, "gpt"}
      )

    assert {:error, %RateLimiter.Error{type: :rate_limited}} =
             ChatModel.invoke(model, [Message.user("hi")])

    assert_received {:rejected_acquire, 3, opts}
    assert opts[:key] == {:openai, "gpt"}
    refute_received :model_invoked
  end

  test "rate-limited model accepts a runtime limiter override" do
    parent = self()

    model =
      %Model{}
      |> Models.with_rate_limiter(
        amount: 2,
        key: {:openai, "gpt"},
        timeout: 25
      )

    assert {:ok, %Message{content: "ok"}} =
             ChatModel.invoke(model, [Message.user("hi")], rate_limiter: %Limiter{parent: parent})

    assert_received {:acquire, 2, opts}
    assert opts[:key] == {:openai, "gpt"}
    assert opts[:timeout] == 25
  end

  test "rate-limited model works through sync and async batches" do
    parent = self()

    model =
      %Model{}
      |> Models.with_rate_limiter(
        limiter: %Limiter{parent: parent},
        amount: 1,
        key: {:openai, "gpt"}
      )

    assert [
             {:ok, %Message{content: "ok"}},
             {:ok, %Message{content: "ok"}}
           ] = ChatModel.batch(model, [[Message.user("one")], [Message.user("two")]])

    assert_received {:acquire, 1, opts}
    assert opts[:key] == {:openai, "gpt"}
    assert_received {:acquire, 1, opts}
    assert opts[:key] == {:openai, "gpt"}

    assert [
             {:ok, %Message{content: "ok"}},
             {:ok, %Message{content: "ok"}}
           ] =
             model
             |> ChatModel.async_batch([[Message.user("three")], [Message.user("four")]])
             |> Async.await_batch()

    assert_received {:acquire, 1, _opts}
    assert_received {:acquire, 1, _opts}
  end

  test "rate-limited model acquires before streaming and supports async stream handles" do
    parent = self()

    model =
      %StreamingModel{parent: parent}
      |> Models.with_rate_limiter(
        limiter: %Limiter{parent: parent},
        amount: 1,
        key: {:openai, "gpt"}
      )

    assert {:ok, [%Message{content: "chunk"}]} = ChatModel.stream(model, [Message.user("hi")])

    assert_received {:acquire, 1, opts}
    assert opts[:key] == {:openai, "gpt"}
    assert_received :model_streamed

    assert {:ok, [%Message{content: "chunk"}]} =
             model
             |> ChatModel.async_stream([Message.user("hi")])
             |> Async.await()

    assert_received {:acquire, 1, _opts}
    assert_received :model_streamed
    refute_received :invoke_fallback
  end

  test "rate-limited model delegates streaming to the wrapped model instead of falling back to invoke" do
    parent = self()

    model =
      %LazyStreamingModel{parent: parent}
      |> Models.with_rate_limiter(
        limiter: %Limiter{parent: parent},
        amount: 1,
        key: {:openai, "gpt"}
      )

    assert {:ok, [%Message{content: "chunk"}]} = ChatModel.stream(model, [Message.user("hi")])

    assert_received {:acquire, 1, _opts}
    assert_received :lazy_model_streamed
    refute_received :lazy_invoke_fallback
  end

  test "cache hits skip the inner rate limiter in the explicit native wrapper order" do
    parent = self()
    cache = CacheETS.new()

    model =
      %RecordingModel{parent: parent}
      |> Models.with_rate_limiter(
        limiter: %Limiter{parent: parent},
        amount: 1,
        key: {:openai, "gpt"}
      )
      |> Models.cached(cache)

    assert {:ok, %Message{content: "ok"}} = ChatModel.invoke(model, [Message.user("hi")])
    assert_received {:acquire, 1, _opts}
    assert_received :model_invoked

    assert {:ok, %Message{content: "ok"}} = ChatModel.invoke(model, [Message.user("hi")])
    refute_received {:acquire, 1, _opts}
    refute_received :model_invoked

    assert {:ok, %Message{content: "ok"}} =
             model
             |> ChatModel.async_invoke([Message.user("hi")])
             |> Async.await()

    refute_received {:acquire, 1, _opts}
    refute_received :model_invoked
  end
end
