defmodule BeamWeaver.RunnableTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable
  alias BeamWeaver.Runnable.Config

  @uuidv7_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  defmodule ModuleRunnable do
    def invoke(input, opts), do: {:ok, {input, Keyword.fetch!(opts, :mode)}}
  end

  defmodule BadStreamRunnable do
    defstruct []

    def invoke(%__MODULE__{}, input, _opts), do: {:ok, input}
    def stream(%__MODULE__{}, _input, _opts), do: {:ok, :not_an_enumerable}
  end

  defmodule PlainStructRunnable do
    defstruct [:value]

    def invoke(%__MODULE__{value: value}, input, _opts), do: {:ok, {value, input}}
  end

  defmodule RecordingChatModel do
    @behaviour BeamWeaver.Core.ChatModel

    defstruct [:parent]

    @impl true
    def invoke(%__MODULE__{parent: parent}, messages, opts) do
      send(parent, {:chat_model_call, messages, opts})
      {:ok, BeamWeaver.Core.Message.assistant("Hello Ada")}
    end
  end

  def handle_telemetry(event, measurements, metadata, parent) do
    send(parent, {:runnable_telemetry, event, measurements, metadata})
  end

  def handle_stream_telemetry(event, measurements, metadata, parent) do
    send(parent, {:stream_telemetry, event, measurements, metadata})
  end

  test "sequence composes runnable outputs and propagates config to lambdas" do
    chain =
      Runnable.sequence([
        Runnable.lambda(fn input, opts ->
          {:ok, Map.put(input, :seen_tags, Keyword.fetch!(opts, :tags))}
        end),
        Runnable.lambda(fn input ->
          {:ok, "#{input.name}:#{Enum.join(input.seen_tags, ",")}"}
        end)
      ])

    assert {:ok, "Ada:core,test"} =
             Runnable.invoke(chain, %{name: "Ada"}, tags: [:core, :test])
  end

  test "a sequence pipes a chat prompt into a chat model and a parser" do
    chain =
      Runnable.sequence([
        BeamWeaver.Prompt.chat([{:user, "Hi {name}"}]),
        %RecordingChatModel{parent: self()},
        BeamWeaver.OutputParser.string()
      ])

    assert {:ok, "Hello Ada"} =
             Runnable.invoke(chain, %{name: "Ada"}, temperature: 0.2, metadata: %{tenant: "acme"}, tags: [:t])

    assert_received {:chat_model_call, [%BeamWeaver.Core.Message{role: :user, content: "Hi Ada"}], opts}

    # Call options reach the model; the run's own settings don't.
    assert opts[:temperature] == 0.2
    refute Keyword.has_key?(opts, :metadata)
    refute Keyword.has_key?(opts, :tags)

    fake = BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["x"])

    assert {:ok, %BeamWeaver.Core.Message{content: "x"}} =
             Runnable.invoke(Runnable.sequence([BeamWeaver.Prompt.chat([{:user, "Hi {name}"}]), fake]), %{name: "Ada"})
  end

  test "chat models take a string as one user message through invoke, stream and batch" do
    model = %RecordingChatModel{parent: self()}

    assert {:ok, %BeamWeaver.Core.Message{content: "Hello Ada"}} = Runnable.invoke(model, "Hi")
    assert_received {:chat_model_call, [%BeamWeaver.Core.Message{role: :user, content: "Hi"}], _opts}

    assert {:ok, stream} = Runnable.stream(model, "Hi")
    assert [%BeamWeaver.Core.Message{content: "Hello Ada"}] = Enum.to_list(stream)

    assert {:ok, [%BeamWeaver.Core.Message{}, %BeamWeaver.Core.Message{}]} = Runnable.batch(model, ["Hi", "Hey"])
  end

  test "batch honors an explicit :timeout and otherwise uses a generous default" do
    hanging = Runnable.lambda(fn _input -> Process.sleep(:infinity) end)

    slow =
      Runnable.lambda(fn _input ->
        Process.sleep(120)
        42
      end)

    # An explicit short timeout aborts a task that would otherwise never finish...
    assert {:error, %Error{type: :runnable_batch_exit}} = Runnable.batch(hanging, [:x], timeout: 30)

    # ...while the default (300_000ms, not the old 5_000) lets it complete.
    assert {:ok, [42]} = Runnable.batch(slow, [:x])
  end

  test "batch keeps input order while respecting max concurrency" do
    parent = self()

    runnable =
      Runnable.lambda(fn input ->
        send(parent, {:started, input})
        Process.sleep(10 - input)
        input * 2
      end)

    assert {:ok, [2, 4, 6]} =
             Runnable.batch(runnable, [1, 2, 3], max_concurrency: 2)

    assert_received {:started, 1}
    assert_received {:started, 2}
    assert_received {:started, 3}
  end

  test "batch does not exceed max concurrency" do
    {:ok, counter} = Agent.start_link(fn -> %{current: 0, max: 0} end)

    runnable =
      Runnable.lambda(fn input ->
        Agent.get_and_update(counter, fn state ->
          current = state.current + 1
          {current, %{state | current: current, max: max(state.max, current)}}
        end)

        Process.sleep(25)
        Agent.update(counter, &%{&1 | current: &1.current - 1})
        input
      end)

    assert {:ok, [1, 2, 3, 4, 5, 6]} =
             Runnable.batch(runnable, [1, 2, 3, 4, 5, 6], max_concurrency: 2)

    assert Agent.get(counter, & &1.max) <= 2
  end

  test "config appends tags merges metadata and preserves arbitrary provider options" do
    config = %Config{
      tags: [:outer],
      metadata: %{tenant: "acme"},
      configurable: %{region: "eu"},
      run_id: "fixed-run"
    }

    runnable =
      Runnable.lambda(fn input, opts ->
        {:ok,
         %{
           input: input,
           tags: Keyword.fetch!(opts, :tags),
           metadata: Keyword.fetch!(opts, :metadata),
           configurable: Keyword.fetch!(opts, :configurable),
           run_id: Keyword.fetch!(opts, :run_id),
           temperature: Keyword.fetch!(opts, :temperature)
         }}
      end)

    assert {:ok,
            %{
              input: "prompt",
              tags: [:outer, :inner],
              metadata: %{tenant: "acme", request_id: "req-1"},
              configurable: %{region: "eu", model: "gpt"},
              run_id: "fixed-run",
              temperature: 0.4
            }} =
             Runnable.invoke(runnable, "prompt",
               config: config,
               tags: [:inner],
               metadata: %{request_id: "req-1"},
               configurable: %{model: "gpt"},
               temperature: 0.4
             )
  end

  test "config copies model and checkpoint namespace into metadata without overriding explicit values" do
    config =
      Config.normalize(
        model: "gpt-5.4",
        checkpoint_ns: "ns-1",
        metadata: %{nooverride: 18}
      )

    assert config.metadata == %{nooverride: 18, model: "gpt-5.4", checkpoint_ns: "ns-1"}
    assert config.configurable == %{model: "gpt-5.4", checkpoint_ns: "ns-1"}

    no_override =
      Config.normalize(
        configurable: %{model: "from-configurable", checkpoint_ns: "from-configurable"},
        metadata: %{model: "from-metadata", checkpoint_ns: "from-metadata"}
      )

    assert no_override.metadata == %{
             model: "from-metadata",
             checkpoint_ns: "from-metadata"
           }
  end

  test "config generates UUIDv7 run IDs by default" do
    config = Config.normalize([])

    assert config.run_id =~ @uuidv7_regex
  end

  test "config exposes safe inheritable tracing metadata" do
    metadata =
      Config.inheritable_metadata(
        something: "else",
        __secret_key: "hidden",
        metadata: %{model: "from-metadata", checkpoint_ns: "from-metadata"},
        configurable: %{
          model: "from-configurable",
          checkpoint_ns: "from-configurable",
          thread_id: "thread-1",
          temperature: 0.5,
          streaming: true,
          api_key: "sk-secret",
          custom_setting: %{nested: true},
          none_value: nil
        }
      )

    assert metadata == %{
             something: "else",
             model: "from-metadata",
             checkpoint_ns: "from-metadata",
             thread_id: "thread-1",
             temperature: 0.5,
             streaming: true
           }
  end

  test "module runnables and unloaded struct modules execute through the facade" do
    assert {:ok, {"input", :fast}} =
             Runnable.invoke(ModuleRunnable, "input", mode: :fast)
  end

  test "lambda exceptions become tagged BeamWeaver errors" do
    runnable =
      Runnable.lambda(fn _input ->
        raise "boom"
      end)

    assert {:error, %Error{type: :runnable_exception, message: "boom"}} =
             Runnable.invoke(runnable, :input)
  end

  test "stream defaults to a single enumerable item and rejects non-enumerable streams" do
    assert {:ok, stream} = Runnable.stream(Runnable.lambda(&String.upcase/1), "beam")
    assert Enum.to_list(stream) == ["BEAM"]

    assert {:error, %Error{type: :invalid_runnable_stream}} =
             Runnable.stream(%BadStreamRunnable{}, "beam")
  end

  test "sequence streams through the final runnable after invoking prefix steps" do
    chain =
      Runnable.sequence([
        Runnable.lambda(fn input -> ["#{input}-a", "#{input}-b"] end),
        Runnable.lambda(fn inputs -> Stream.map(inputs, &String.upcase/1) end)
      ])

    assert {:ok, stream} = Runnable.stream(chain, "beam")
    assert Enum.to_list(stream) == ["BEAM-A", "BEAM-B"]
  end

  test "stream telemetry fires around lazy runnable consumption" do
    parent = self()
    handler_id = {__MODULE__, :stream, make_ref()}

    :telemetry.attach_many(
      handler_id,
      [
        [:beam_weaver, :stream, :start],
        [:beam_weaver, :stream, :event],
        [:beam_weaver, :stream, :stop]
      ],
      &__MODULE__.handle_stream_telemetry/4,
      parent
    )

    try do
      assert {:ok, stream} =
               Runnable.stream(Runnable.lambda(fn _ -> ["a", "b"] end), :input, run_id: "stream-run")

      assert_received {:stream_telemetry, [:beam_weaver, :stream, :start], %{system_time: _}, %{run_id: "stream-run"}}

      assert Enum.to_list(stream) == ["a", "b"]

      assert_received {:stream_telemetry, [:beam_weaver, :stream, :event], %{count: 1}, %{run_id: "stream-run"}}

      assert_received {:stream_telemetry, [:beam_weaver, :stream, :stop], %{count: 2}, %{run_id: "stream-run"}}
    after
      :telemetry.detach(handler_id)
    end
  end

  test "default transform merges addable chunks before invoking" do
    default = Runnable.lambda(fn value -> {:ok, value <> "!"} end)
    assert {:ok, merged} = Runnable.transform(default, ["he", "llo"])
    assert Enum.to_list(merged) == ["hello!"]
  end

  test "telemetry is the Elixir callback surface for runnable execution" do
    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach_many(
      handler_id,
      [
        [:beam_weaver, :runnable, :start],
        [:beam_weaver, :runnable, :stop],
        [:beam_weaver, :runnable, :exception]
      ],
      &__MODULE__.handle_telemetry/4,
      parent
    )

    try do
      assert {:ok, "ok"} = Runnable.invoke(Runnable.lambda(fn _ -> "ok" end), :input)

      assert_received {:runnable_telemetry, [:beam_weaver, :runnable, :start], %{system_time: _},
                       %{runnable: "BeamWeaver.Runnable.Lambda"}}

      assert_received {:runnable_telemetry, [:beam_weaver, :runnable, :stop], %{duration: _},
                       %{runnable: "BeamWeaver.Runnable.Lambda"}}

      assert {:error, %Error{type: :expected}} =
               Runnable.invoke(
                 Runnable.lambda(fn _ -> {:error, Error.new(:expected, "expected")} end),
                 :input
               )

      assert_received {:runnable_telemetry, [:beam_weaver, :runnable, :exception], %{duration: _},
                       %{error: %Error{type: :expected}}}
    after
      :telemetry.detach(handler_id)
    end
  end
end
