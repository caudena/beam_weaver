defmodule BeamWeaver.RunnableTest do
  use ExUnit.Case, async: true

  # Upstream references:
  # - langchain/libs/core/tests/unit_tests/runnables/test_runnable.py
  # - langchain/libs/core/tests/unit_tests/runnables/test_config.py
  # - langchain/libs/core/tests/unit_tests/runnables/test_concurrency.py
  # - langchain/libs/core/tests/unit_tests/runnables/test_fallbacks.py

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.ChatHistory
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.OutputParser
  alias BeamWeaver.Runnable
  alias BeamWeaver.Runnable.Config
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

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

  test "pipe composes runnables into a named native sequence" do
    chain =
      Runnable.lambda(fn value -> value + 1 end)
      |> Runnable.pipe(
        [
          Runnable.lambda(fn value -> value * 2 end),
          Runnable.lambda(fn value -> "value=#{value}" end)
        ],
        name: :math_chain
      )

    assert Runnable.get_name(chain) == "math_chain"
    assert {:ok, "value=8"} = Runnable.invoke(chain, 3)
  end

  test "with_listeners emits root lifecycle runs without Python callback managers" do
    BeamWeaver.Tracing.reset()
    parent = self()

    chain =
      Runnable.lambda(fn input -> String.upcase(input) end)
      |> Runnable.pipe(Runnable.lambda(fn input -> "#{input}!" end), name: :listener_chain)
      |> Runnable.with_listeners(
        on_start: fn run, config ->
          send(parent, {:listener_start, run.name, run.inputs, config.tags})
        end,
        on_end: fn run ->
          send(
            parent,
            {:listener_end, run.status, run.outputs, is_struct(run.ended_at, DateTime)}
          )
        end
      )

    assert {:ok, "BEAM!"} = Runnable.invoke(chain, "beam", tags: [:core])
    assert_received {:listener_start, "listener_chain", "beam", [:core]}
    assert_received {:listener_end, :ok, "BEAM!", true}
  end

  test "with_listeners reports errors and map invokes listeners once per item" do
    BeamWeaver.Tracing.reset()
    parent = self()

    failing =
      Runnable.lambda(fn _input -> {:error, Error.new(:expected_failure, "expected")} end)
      |> Runnable.with_listeners(
        on_error: fn run ->
          send(parent, {:listener_error, run.status, run.error})
        end
      )

    assert {:error, %Error{type: :expected_failure}} = Runnable.invoke(failing, :input)
    assert_received {:listener_error, :error, %{type: :expected_failure}}

    wrapped =
      Runnable.lambda(fn input -> Map.put(input, :seen, true) end)
      |> Runnable.with_listeners(
        on_start: fn run ->
          send(parent, {:mapped_listener_start, run.id, run.inputs})
        end
      )
      |> Runnable.map()

    assert {:ok, [%{name: "one", seen: true}, %{name: "two", seen: true}]} =
             Runnable.invoke(wrapped, [%{name: "one"}, %{name: "two"}], max_concurrency: 1)

    assert_received {:mapped_listener_start, first_id, %{name: "one"}}
    assert_received {:mapped_listener_start, second_id, %{name: "two"}}
    refute first_id == second_id
  end

  test "with_alisteners runs listener callbacks through Tasks" do
    parent = self()

    runnable =
      Runnable.lambda(fn input -> input + 1 end)
      |> Runnable.with_alisteners(
        on_start: fn run ->
          send(parent, {:async_listener_start, run.inputs, self()})
        end
      )

    caller = self()
    assert {:ok, 42} = Runnable.invoke(runnable, 41)
    assert_received {:async_listener_start, 41, listener_pid}
    assert listener_pid != caller
  end

  test "listener trace metadata includes safe configurable values without leaking secrets" do
    BeamWeaver.Tracing.reset()
    parent = self()

    runnable =
      Runnable.lambda(fn input -> input end)
      |> Runnable.with_listeners(
        on_start: fn run ->
          send(parent, {:trace_metadata, run.metadata})
        end
      )

    assert {:ok, "ok"} =
             Runnable.invoke(runnable, "ok",
               metadata: %{model: "from-metadata", request_id: "req-1"},
               configurable: %{
                 thread_id: "thread-1",
                 model: "from-configurable",
                 temperature: 0.2,
                 streaming: true,
                 api_key: "sk-live-secret",
                 __secret_key: "hidden",
                 custom_setting: %{nested: true},
                 none_value: nil
               }
             )

    assert_received {:trace_metadata, metadata}
    assert metadata.thread_id == "thread-1"
    assert metadata.temperature == 0.2
    assert metadata.streaming == true
    assert metadata.model == "from-metadata"
    assert metadata.request_id == "req-1"
    refute Map.has_key?(metadata, :api_key)
    refute Map.has_key?(metadata, :__secret_key)
    refute Map.has_key?(metadata, :custom_setting)
    refute Map.has_key?(metadata, :none_value)
  end

  test "listener wrappers compose through other native runnable wrappers" do
    parent = self()

    runnable =
      Runnable.lambda(fn input -> input end)
      |> Runnable.with_listeners(
        on_start: fn run ->
          send(parent, {:outer_listener_start, run.inputs})
        end
      )

    assert {:ok, "retry"} =
             runnable
             |> Runnable.with_retry(max_attempts: 1)
             |> Runnable.invoke("retry")

    assert_received {:outer_listener_start, "retry"}

    assert {:ok, "typed"} =
             runnable
             |> Runnable.with_types(output: %{"type" => "string"})
             |> Runnable.invoke("typed")

    assert_received {:outer_listener_start, "typed"}

    assert {:ok, "configured"} =
             runnable
             |> Runnable.with_config(tags: [:configured])
             |> Runnable.invoke("configured")

    assert_received {:outer_listener_start, "configured"}

    assert {:ok, "bound"} =
             runnable
             |> Runnable.bind(stop: ["ignored"])
             |> Runnable.invoke("bound")

    assert_received {:outer_listener_start, "bound"}

    nested =
      runnable
      |> Runnable.with_listeners(
        on_start: fn run ->
          send(parent, {:inner_listener_start, run.inputs})
        end
      )

    assert {:ok, "nested"} = Runnable.invoke(nested, "nested")
    assert_received {:outer_listener_start, "nested"}
    assert_received {:inner_listener_start, "nested"}
  end

  test "parallel map and list preserve deterministic output order" do
    runnable =
      Runnable.parallel(%{
        double: Runnable.lambda(&(&1 * 2)),
        square: Runnable.lambda(&(&1 * &1))
      })

    assert {:ok, %{double: 6, square: 9}} = Runnable.invoke(runnable, 3)

    ordered =
      Runnable.parallel([
        Runnable.lambda(fn input ->
          Process.sleep(20)
          input + 1
        end),
        Runnable.lambda(&(&1 + 2))
      ])

    assert {:ok, [4, 5]} = Runnable.invoke(ordered, 3)
  end

  test "passthrough assign and pick transform maps" do
    runnable =
      Runnable.assign(%{
        full_name:
          Runnable.lambda(fn input ->
            "#{input.first} #{input.last}"
          end)
      })
      |> Runnable.sequence()
      |> then(fn assign ->
        Runnable.sequence([
          assign,
          Runnable.pick([:full_name, :role])
        ])
      end)

    assert {:ok, %{full_name: "Ada Lovelace", role: "engineer"}} =
             Runnable.invoke(runnable, %{first: "Ada", last: "Lovelace", role: "engineer"})
  end

  test "branch selects the first matching runnable and reports missing branches" do
    branch =
      Runnable.branch([
        {fn input -> input.kind == :known end, Runnable.lambda(fn input -> {:ok, input.value} end)},
        {:default, Runnable.lambda(fn _input -> {:ok, :fallback} end)}
      ])

    assert {:ok, 42} = Runnable.invoke(branch, %{kind: :known, value: 42})
    assert {:ok, :fallback} = Runnable.invoke(branch, %{kind: :other})

    assert {:error, %Error{type: :no_matching_branch}} =
             Runnable.invoke(Runnable.branch([]), %{kind: :none})
  end

  test "branch predicates can use runtime config" do
    branch =
      Runnable.branch([
        {fn input, opts -> input.kind == Keyword.fetch!(opts, :route) end,
         Runnable.lambda(fn input -> {:ok, {:matched, input.kind}} end)},
        {:default, Runnable.lambda(fn input -> {:ok, {:default, input.kind}} end)}
      ])

    assert {:ok, {:matched, :admin}} =
             Runnable.invoke(branch, %{kind: :admin}, route: :admin)

    assert {:ok, {:default, :viewer}} =
             Runnable.invoke(branch, %{kind: :viewer}, route: :admin)
  end

  test "router routes invoke stream batch async and missing keys" do
    router =
      Runnable.router(%{
        "double" => Runnable.lambda(fn input -> {:ok, input * 2} end),
        :upper => Runnable.generator(fn input -> [String.upcase(input)] end)
      })

    assert {:ok, 6} = Runnable.invoke(router, %{key: "double", input: 3})
    assert {:ok, 8} = Runnable.invoke(router, %{"key" => "double", "input" => 4})

    assert {:ok, stream} = Runnable.stream(router, %{key: "upper", input: "beam"})
    assert Enum.to_list(stream) == ["BEAM"]

    assert {:ok, [4, 10]} =
             Runnable.batch(router, [
               %{key: "double", input: 2},
               %{key: "double", input: 5}
             ])

    assert {:ok, 12} =
             router
             |> Runnable.async_invoke(%{key: "double", input: 6})
             |> Async.await()

    assert {:ok, async_stream} =
             router
             |> Runnable.async_stream(%{key: "upper", input: "async"})
             |> Async.await()

    assert Enum.to_list(async_stream) == ["ASYNC"]

    assert {:error, %Error{type: :missing_router_route}} =
             Runnable.invoke(router, %{key: "missing", input: 1})

    assert {:error, %Error{type: :invalid_router_input}} =
             Runnable.invoke(router, %{key: "double"})
  end

  test "router specs and branch introspection stay native" do
    router = Runnable.router(%{"text" => OutputParser.string(), "json" => OutputParser.json()})

    assert {:ok, spec} = Runnable.to_spec(router)
    assert {:ok, restored} = Runnable.from_spec(spec)

    assert {:ok, %{"answer" => 42}} =
             Runnable.invoke(restored, %{key: "json", input: ~s({"answer":42})})

    typed =
      Runnable.with_types(Runnable.lambda(fn input -> {:ok, input.answer} end),
        input: %{"type" => "object"},
        output: %{"type" => "string"}
      )

    branch =
      Runnable.branch([
        {fn _input -> false end, Runnable.lambda(& &1)},
        {:default, typed}
      ])

    assert Runnable.input_schema(branch) == %{"type" => "object"}
    assert Runnable.output_schema(branch) == %{"type" => "string"}
    assert Runnable.get_graph(branch).nodes["input"].label == "Input"
  end

  test "retry and fallbacks recover from runnable errors" do
    parent = self()

    flaky =
      Runnable.lambda(fn input ->
        count = Process.get(:runnable_retry_count, 0) + 1
        Process.put(:runnable_retry_count, count)
        send(parent, {:retry_attempt, count})

        if count < 3 do
          {:error, Error.new(:temporary, "not yet")}
        else
          {:ok, input * 10}
        end
      end)

    assert {:ok, 70} =
             flaky
             |> Runnable.with_retry(max_attempts: 3)
             |> Runnable.invoke(7)

    assert_received {:retry_attempt, 1}
    assert_received {:retry_attempt, 2}
    assert_received {:retry_attempt, 3}

    fallback =
      Runnable.with_fallbacks(
        Runnable.lambda(fn _ -> {:error, Error.new(:primary_failed, "failed")} end),
        [Runnable.lambda(fn input -> {:ok, {:fallback, input}} end)]
      )

    assert {:ok, {:fallback, "work"}} = Runnable.invoke(fallback, "work")
  after
    Process.delete(:runnable_retry_count)
  end

  test "retry composes with batch and Task-backed async facades" do
    {:ok, counts} = Agent.start_link(fn -> %{} end)

    flaky =
      Runnable.lambda(fn input ->
        attempt =
          Agent.get_and_update(counts, fn counts ->
            next = Map.get(counts, input, 0) + 1
            {next, Map.put(counts, input, next)}
          end)

        if input == :fail or attempt < 2 do
          {:error, Error.new(:temporary, "not yet", %{input: input, attempt: attempt})}
        else
          {:ok, {:ok, input, attempt}}
        end
      end)
      |> Runnable.with_retry(max_attempts: 3)

    assert {:ok, [{:ok, :a, 2}, {:ok, :b, 2}]} = Runnable.batch(flaky, [:a, :b])
    assert {:ok, {:ok, :async, 2}} = flaky |> Runnable.async_invoke(:async) |> Async.await()

    assert {:error, %Error{type: :temporary, details: %{input: :fail, attempt: 3}}} =
             Runnable.invoke(flaky, :fail)
  end

  test "fallbacks propagate handled errors through exception_key and respect handled types" do
    runnable =
      Runnable.lambda(fn
        %{text: "foo"} ->
          "first"

        %{text: "bar", exception: %Error{type: :missing_exception}} ->
          "second"

        %{text: "baz", exception: %Error{type: :missing_exception}} ->
          {:error, Error.new(:runtime_failure, "runtime")}

        %{text: "baz", exception: %Error{type: :runtime_failure}} ->
          "third"

        _input ->
          {:error, Error.new(:missing_exception, "missing exception")}
      end)

    single = Runnable.with_fallbacks(runnable, [runnable], exception_key: :exception)
    assert {:ok, "second"} = Runnable.invoke(single, %{text: "bar"})

    assert {:error, %Error{type: :runtime_failure}} =
             Runnable.invoke(single, %{text: "baz"})

    double = Runnable.with_fallbacks(runnable, [runnable, runnable], exception_key: :exception)
    assert {:ok, "third"} = Runnable.invoke(double, %{text: "baz"})

    only_missing =
      Runnable.with_fallbacks(runnable, [runnable, runnable],
        exception_key: :exception,
        exceptions_to_handle: [:missing_exception]
      )

    assert {:error, %Error{type: :runtime_failure}} =
             Runnable.invoke(only_missing, %{text: "baz"})

    assert {:error, %Error{type: :invalid_runnable_input}} =
             Runnable.invoke(single, "not a map")
  end

  test "fallback batch keeps order and can return errors as values" do
    runnable =
      Runnable.lambda(fn
        %{text: "foo"} ->
          "first"

        %{text: "bar", exception: %Error{type: :missing_exception}} ->
          "second"

        %{text: "baz", exception: %Error{type: :missing_exception}} ->
          {:error, Error.new(:runtime_failure, "runtime")}

        %{text: "baz", exception: %Error{type: :runtime_failure}} ->
          "third"

        _input ->
          {:error, Error.new(:missing_exception, "missing exception")}
      end)

    single = Runnable.with_fallbacks(runnable, [runnable], exception_key: :exception)

    assert {:ok, ["first", "second", %Error{type: :runtime_failure}]} =
             Runnable.batch(single, [%{text: "foo"}, %{text: "bar"}, %{text: "baz"}],
               return_errors: true,
               max_concurrency: 2
             )

    assert {:error, %Error{type: :runtime_failure}} =
             Runnable.batch(single, [%{text: "foo"}, %{text: "bar"}, %{text: "baz"}], max_concurrency: 2)

    double = Runnable.with_fallbacks(runnable, [runnable, runnable], exception_key: :exception)

    assert {:ok, ["first", "second", "third"]} =
             Runnable.batch(double, [%{text: "foo"}, %{text: "bar"}, %{text: "baz"}], max_concurrency: 2)
  end

  test "fallback streams retry immediate stream failures and expose primary schemas/config specs" do
    primary =
      Runnable.generator(fn _input -> {:error, Error.new(:stream_failed, "failed")} end)
      |> Runnable.with_types(input: %{"type" => "object"}, output: %{"type" => "string"})

    backup = Runnable.generator(fn _input -> ["f", "o", "o"] end)

    fallback = Runnable.with_fallbacks(primary, [backup])

    assert {:ok, stream} = Runnable.stream(fallback, %{})
    assert Enum.to_list(stream) == ["f", "o", "o"]

    assert Runnable.input_schema(fallback) == %{"type" => "object"}
    assert Runnable.output_schema(fallback) == %{"type" => "string"}

    spec_fallback =
      Runnable.with_fallbacks(
        Runnable.lambda(& &1) |> Runnable.configure(model: [id: "model", name: "Model"]),
        [Runnable.lambda(& &1) |> Runnable.configure(backup: [id: "backup", name: "Backup"])]
      )

    assert spec_fallback |> Runnable.config_specs() |> Enum.map(& &1.id) |> Enum.sort() == [
             "backup",
             "model"
           ]
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

  test "batch_as_completed streams index tagged results as tasks finish" do
    runnable =
      Runnable.lambda(fn input ->
        Process.sleep(input.sleep_ms)

        if Map.get(input, :fail?, false) do
          {:error, Error.new(:expected_failure, "failed #{input.value}")}
        else
          {:ok, input.value * 2}
        end
      end)

    inputs = [
      %{value: 1, sleep_ms: 30},
      %{value: 2, sleep_ms: 5},
      %{value: 3, sleep_ms: 10, fail?: true}
    ]

    assert {:ok, stream} = Runnable.batch_as_completed(runnable, inputs, max_concurrency: 3)

    results = Enum.to_list(stream)
    assert Enum.map(results, &elem(&1, 0)) == [1, 2, 0]

    assert {1, {:ok, 4}} in results
    assert {0, {:ok, 2}} in results
    assert Enum.any?(results, &match?({2, {:error, %Error{type: :expected_failure}}}, &1))
  end

  test "async_batch_as_completed returns a handle to the completion stream" do
    handle =
      Runnable.async_batch_as_completed(
        Runnable.lambda(fn input -> {:ok, input + 1} end),
        [1, 2]
      )

    assert {:ok, stream} = Async.await(handle)
    assert stream |> Enum.to_list() |> Enum.sort() == [{0, {:ok, 2}}, {1, {:ok, 3}}]
  end

  test "binding merges bound options before runtime options" do
    runnable =
      Runnable.lambda(fn input, opts ->
        {:ok, {input, Keyword.fetch!(opts, :temperature), Keyword.fetch!(opts, :model)}}
      end)
      |> Runnable.bind(temperature: 0.2, model: :mini)

    assert {:ok, {"hello", 0.8, :mini}} =
             Runnable.invoke(runnable, "hello", temperature: 0.8)
  end

  test "binding merges options into stream event facades" do
    parent = self()

    runnable =
      Runnable.generator(fn _input, opts ->
        send(parent, {:stream_opts, opts})
        [Keyword.fetch!(opts, :marker)]
      end)

    bound = Runnable.bind(runnable, marker: "from-bind")

    assert {:ok, events} = Runnable.stream_events(bound, "input")
    assert Enum.any?(events, &match?(%Envelope{event: %Events.Custom{payload: "from-bind"}}, &1))
    assert_received {:stream_opts, opts}
    assert Keyword.fetch!(opts, :marker) == "from-bind"

    assert {:ok, override_events} =
             bound
             |> Runnable.async_stream_events("input", marker: "from-call")
             |> Async.await()

    assert Enum.any?(
             override_events,
             &match?(%Envelope{event: %Events.Custom{payload: "from-call"}}, &1)
           )

    assert_received {:stream_opts, override_opts}
    assert Keyword.fetch!(override_opts, :marker) == "from-call"
  end

  test "stream_events emits typed lifecycle envelopes with run-name and tag filtering" do
    runnable =
      Runnable.generator(fn input ->
        ["#{input}:one", "#{input}:two"]
      end)

    assert {:ok, events} =
             Runnable.stream_events(runnable, "beam",
               run_name: :native_stream,
               tags: [:keep],
               metadata: %{tenant: "acme"}
             )

    assert [
             %Envelope{
               event: %Events.Debug{payload: %{kind: :start}},
               node: "native_stream",
               metadata: %{tags: [:keep], metadata: %{tenant: "acme"}}
             },
             %Envelope{event: %Events.Custom{payload: "beam:one"}, node: "native_stream"},
             %Envelope{event: %Events.Custom{payload: "beam:two"}, node: "native_stream"},
             %Envelope{event: %Events.Done{}, node: "native_stream"}
           ] = Enum.to_list(events)

    assert {:ok, included} =
             Runnable.stream_events(runnable, "beam",
               run_name: :native_stream,
               tags: [:keep],
               include_names: [:native_stream],
               include_tags: ["keep"]
             )

    assert length(Enum.to_list(included)) == 4

    assert {:ok, excluded} =
             Runnable.stream_events(runnable, "beam",
               run_name: :native_stream,
               tags: [:keep],
               exclude_names: ["native_stream"]
             )

    assert Enum.to_list(excluded) == []
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

  test "named runnables and as_tool use native metadata and tool conversion" do
    runnable = Runnable.lambda(fn input -> {:ok, String.upcase(input["value"])} end, name: :upper)

    assert Runnable.get_name(runnable) == "upper"

    assert {:ok, tool} =
             Runnable.as_tool(runnable,
               name: "upper",
               description: "Uppercases value",
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"value" => %{"type" => "string"}}
               }
             )

    assert Tool.name(tool) == "upper"
    assert {:ok, "BEAM"} = Tool.invoke(tool, %{"value" => "beam"})
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
        Runnable.generator(fn inputs -> Stream.map(inputs, &String.upcase/1) end)
      ])

    assert {:ok, stream} = Runnable.stream(chain, "beam")
    assert Enum.to_list(stream) == ["BEAM-A", "BEAM-B"]
  end

  test "branch and map stream preserve selected branch and ordered mapped output" do
    branch =
      Runnable.branch([
        {fn input -> input.mode == :numbers end,
         Runnable.sequence([
           Runnable.lambda(& &1.value),
           Runnable.map(Runnable.lambda(&(&1 * 2)))
         ])},
        {:default, Runnable.generator(fn input -> [input.value] end)}
      ])

    assert {:ok, stream} = Runnable.stream(branch, %{mode: :numbers, value: [1, 2, 3]})
    assert Enum.to_list(stream) == [2, 4, 6]

    assert {:ok, fallback_stream} = Runnable.stream(branch, %{mode: :text, value: "fallback"})
    assert Enum.to_list(fallback_stream) == ["fallback"]
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
               Runnable.stream(Runnable.generator(fn _ -> ["a", "b"] end), :input, run_id: "stream-run")

      assert_received {:stream_telemetry, [:beam_weaver, :stream, :start], %{system_time: _}, %{run_id: "stream-run"}}

      assert Enum.to_list(stream) == ["a", "b"]

      assert_received {:stream_telemetry, [:beam_weaver, :stream, :event], %{count: 1}, %{run_id: "stream-run"}}

      assert_received {:stream_telemetry, [:beam_weaver, :stream, :stop], %{count: 2}, %{run_id: "stream-run"}}
    after
      :telemetry.detach(handler_id)
    end
  end

  test "async runnable APIs return BeamWeaver handles" do
    handle = Runnable.async_invoke(Runnable.lambda(&(&1 + 1)), 1)
    assert {:ok, 2} = Async.await(handle)

    batch = Runnable.async_batch(Runnable.lambda(&(&1 * 2)), [1, 2, 3])
    assert {:ok, [2, 4, 6]} = Async.await(batch)

    stream = Runnable.async_stream(Runnable.generator(fn _ -> ["a", "b"] end), :input)
    assert {:ok, enumerable} = Async.await(stream)
    assert Enum.to_list(enumerable) == ["a", "b"]

    transform =
      Runnable.async_transform(
        Runnable.generator(fn stream -> Stream.map(stream, &String.upcase/1) end),
        ["a", "b"]
      )

    assert {:ok, transformed} = Async.await(transform)
    assert Enum.to_list(transformed) == ["A", "B"]

    event_handle = Runnable.async_stream_events(Runnable.generator(fn _ -> ["x"] end), :input)
    assert {:ok, events} = Async.await(event_handle)
    assert Enum.any?(events, &match?(%Envelope{event: %Events.Done{}}, &1))

    log_handle = Runnable.async_stream_log(Runnable.generator(fn _ -> ["x"] end), :input)
    assert {:ok, patches} = Async.await(log_handle)
    assert Enum.any?(patches, &match?(%BeamWeaver.Runnable.RunLogPatch{}, &1))

    slow =
      Runnable.async_invoke(
        Runnable.lambda(fn _ ->
          Process.sleep(100)
          :done
        end),
        :input
      )

    assert Async.yield(slow, 1) == nil
    cancel_result = Async.cancel(slow, 10)

    assert is_nil(cancel_result) or match?({:exit, _}, cancel_result) or
             match?({:ok, _}, cancel_result)
  end

  test "with_config merges defaults before invocation options" do
    runnable =
      Runnable.lambda(fn input, opts ->
        {:ok, {input, Keyword.fetch!(opts, :tags), Keyword.fetch!(opts, :metadata)}}
      end)
      |> Runnable.with_config(tags: [:default], metadata: %{a: 1})

    assert {:ok, {"x", [:default, :call], %{a: 1, b: 2}}} =
             Runnable.invoke(runnable, "x", tags: [:call], metadata: %{b: 2})
  end

  test "configure applies explicit runtime values through protocol-backed structs" do
    model =
      %BeamWeaver.Models.FakeChatModel{response: Message.assistant("default")}
      |> Runnable.configure(response: [id: "answer"])

    assert [%BeamWeaver.Runnable.ConfigSpec{id: "answer", field: :response}] =
             Runnable.config_specs(model)

    assert {:ok, %Message{content: "runtime"}} =
             Runnable.invoke(model, [], configurable: %{"answer" => Message.assistant("runtime")})

    assert {:ok, %Message{content: "default"}} = Runnable.invoke(model, [])
  end

  test "configure rejects user structs that do not implement the configurable protocol" do
    runnable = Runnable.configure(%PlainStructRunnable{value: :default}, value: [])

    assert {:error, %Error{type: :unsupported_configurable}} =
             Runnable.invoke(runnable, :input, configurable: %{value: :runtime})
  end

  test "alternatives select runnables from runtime config and evaluate lazy builders only when selected" do
    parent = self()

    runnable =
      Runnable.alternatives(
        Runnable.lambda(fn input -> {:ok, {:default, input}} end),
        :model,
        %{
          fast: Runnable.lambda(fn input -> {:ok, {:fast, input}} end),
          lazy: fn ->
            send(parent, :lazy_built)
            Runnable.lambda(fn input -> {:ok, {:lazy, input}} end)
          end
        }
      )

    assert {:ok, {:default, "q"}} = Runnable.invoke(runnable, "q")
    refute_received :lazy_built

    assert {:ok, {:fast, "q"}} = Runnable.invoke(runnable, "q", configurable: %{model: :fast})

    assert {:ok, {:lazy, "q"}} =
             Runnable.invoke(runnable, "q", configurable: %{"model" => "lazy"})

    assert_received :lazy_built

    assert {:error, %Error{type: :unknown_runnable_alternative}} =
             Runnable.invoke(runnable, "q", configurable: %{model: :missing})
  end

  test "alternatives can prefix nested configurable fields" do
    default =
      %BeamWeaver.Models.FakeChatModel{response: Message.assistant("default")}
      |> Runnable.configure(response: [id: "responses"])

    chat =
      %BeamWeaver.Models.FakeChatModel{response: Message.assistant("chat-default")}
      |> Runnable.configure(response: [id: "responses"])

    runnable = Runnable.alternatives(default, :llm, %{chat: chat}, prefix_keys: true)

    assert Runnable.config_specs(runnable) |> Enum.map(& &1.id) |> Enum.sort() == [
             "llm",
             "llm==chat/responses",
             "llm==default/responses"
           ]

    assert {:ok, %Message{content: "configured default"}} =
             Runnable.invoke(runnable, [],
               configurable: %{
                 "llm==default/responses" => Message.assistant("configured default")
               }
             )

    assert {:ok, %Message{content: "configured chat"}} =
             Runnable.invoke(runnable, [],
               configurable: %{
                 "llm" => "chat",
                 "llm==chat/responses" => Message.assistant("configured chat")
               }
             )
  end

  test "message history injects prior messages and appends only successful turns" do
    store = BeamWeaver.Core.ChatHistory.ETS.new()

    runnable =
      Runnable.lambda(fn messages ->
        assert [%Message{role: :user, content: "hello"}] = messages
        Message.assistant("hi")
      end)
      |> Runnable.with_history(history: store)

    assert {:ok, %Message{content: "hi"}} =
             Runnable.invoke(runnable, "hello", configurable: %{session_id: "s1"})

    session = BeamWeaver.Core.ChatHistory.ETS.for_session(store, "s1")

    assert {:ok, [%Message{content: "hello"}, %Message{content: "hi"}]} =
             ChatHistory.get_messages(session)

    failing =
      Runnable.lambda(fn _ -> {:error, Error.new(:expected, "expected")} end)
      |> Runnable.with_history(history: store)

    assert {:error, %Error{type: :expected}} =
             Runnable.invoke(failing, "again", configurable: %{session_id: "s1"})

    assert {:ok, [%Message{content: "hello"}, %Message{content: "hi"}]} =
             ChatHistory.get_messages(session)
  end

  test "message history supports map input keys and separate sessions" do
    store = BeamWeaver.Core.ChatHistory.ETS.new()

    runnable =
      Runnable.lambda(fn input ->
        assert input.history == []
        assert input.input == "first"
        Message.assistant("second")
      end)
      |> Runnable.with_history(
        history: store,
        input_messages_key: :input,
        history_messages_key: :history
      )

    assert {:ok, %Message{content: "second"}} =
             Runnable.invoke(runnable, %{input: "first"}, configurable: %{session_id: "a"})

    assert {:ok, []} =
             store
             |> BeamWeaver.Core.ChatHistory.ETS.for_session("b")
             |> ChatHistory.get_messages()
  end

  test "message history extracts output messages from map output key" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/runnables/test_history.py
    # - output_messages_key controls which map field is persisted as assistant history.
    parent = self()
    store = BeamWeaver.Core.ChatHistory.ETS.new()

    runnable =
      Runnable.lambda(fn input ->
        send(parent, {:history_seen, Enum.map(input.history, & &1.content)})
        %{output: [Message.assistant("you said: #{input.input}")], ignored: "not-history"}
      end)
      |> Runnable.with_history(
        history: store,
        input_messages_key: :input,
        history_messages_key: :history,
        output_messages_key: :output
      )

    assert {:ok, %{output: [%Message{content: "you said: hello"}], ignored: "not-history"}} =
             Runnable.invoke(runnable, %{input: "hello"}, configurable: %{session_id: "out"})

    assert_received {:history_seen, []}

    assert {:ok, %{output: [%Message{content: "you said: again"}]}} =
             Runnable.invoke(runnable, %{input: "again"}, configurable: %{session_id: "out"})

    assert_received {:history_seen, ["hello", "you said: hello"]}

    session = BeamWeaver.Core.ChatHistory.ETS.for_session(store, "out")

    assert {:ok,
            [
              %Message{role: :user, content: "hello"},
              %Message{role: :assistant, content: "you said: hello"},
              %Message{role: :user, content: "again"},
              %Message{role: :assistant, content: "you said: again"}
            ]} = ChatHistory.get_messages(session)
  end

  test "message history factory can receive full configurable values" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/runnables/test_history.py
    # - custom history factories can key sessions from multiple configurable values.
    parent = self()
    store = BeamWeaver.Core.ChatHistory.ETS.new()

    history_factory = fn configurable ->
      session_id = "#{configurable.user_id}:#{configurable.conversation_id}"
      BeamWeaver.Core.ChatHistory.ETS.for_session(store, session_id)
    end

    runnable =
      Runnable.lambda(fn input ->
        send(parent, {:factory_history_seen, Enum.map(input.history, & &1.content)})
        [Message.assistant("you said: #{hd(input.messages).content}")]
      end)
      |> Runnable.with_history(
        history: history_factory,
        session_key: :user_id,
        config_specs: [
          [id: :user_id, name: "User ID", description: "Unique identifier for the user."],
          [
            id: :conversation_id,
            name: "Conversation ID",
            description: "Unique identifier for the conversation."
          ]
        ],
        history_factory_input: :configurable,
        input_messages_key: :messages,
        history_messages_key: :history
      )

    assert runnable |> Runnable.config_specs() |> Enum.map(& &1.id) |> Enum.sort() == [
             "conversation_id",
             "user_id"
           ]

    assert {:ok, [%Message{content: "you said: hello"}]} =
             Runnable.invoke(
               runnable,
               %{messages: [Message.user("hello")]},
               configurable: %{user_id: "u1", conversation_id: "c1"}
             )

    assert_received {:factory_history_seen, []}

    assert {:ok, [%Message{content: "you said: goodbye"}]} =
             Runnable.invoke(
               runnable,
               %{messages: [Message.user("goodbye")]},
               configurable: %{user_id: "u1", conversation_id: "c1"}
             )

    assert_received {:factory_history_seen, ["hello", "you said: hello"]}

    assert {:ok, [%Message{content: "you said: meow"}]} =
             Runnable.invoke(
               runnable,
               %{messages: [Message.user("meow")]},
               configurable: %{user_id: "u2", conversation_id: "c1"}
             )

    assert_received {:factory_history_seen, []}

    async =
      Runnable.async_invoke(
        runnable,
        %{messages: [Message.user("async")]},
        configurable: %{user_id: "u1", conversation_id: "c2"}
      )

    assert {:ok, [%Message{content: "you said: async"}]} = Async.await(async)
    assert_received {:factory_history_seen, []}
  end

  test "message history appends streamed output after full consumption" do
    store = BeamWeaver.Core.ChatHistory.ETS.new()

    runnable =
      Runnable.generator(fn _ ->
        [
          Messages.ai_chunk("he"),
          Messages.ai_chunk("llo")
        ]
      end)
      |> Runnable.with_history(history: store)

    assert {:ok, stream} =
             Runnable.stream(runnable, "prompt", configurable: %{session_id: "stream"})

    session = BeamWeaver.Core.ChatHistory.ETS.for_session(store, "stream")
    assert {:ok, []} = ChatHistory.get_messages(session)

    assert Enum.to_list(stream) == [Messages.ai_chunk("he"), Messages.ai_chunk("llo")]

    assert {:ok, [%Message{content: "prompt"}, %Message{role: :assistant, content: "hello"}]} =
             ChatHistory.get_messages(session)
  end

  test "message history does not append partial streamed output when consumer halts early" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/runnables/test_history.py
    # - streamed history is persisted only after the run finishes successfully.
    store = BeamWeaver.Core.ChatHistory.ETS.new()

    runnable =
      Runnable.generator(fn _ ->
        [
          Messages.ai_chunk("he"),
          Messages.ai_chunk("llo")
        ]
      end)
      |> Runnable.with_history(history: store)

    assert {:ok, stream} =
             Runnable.stream(runnable, "prompt", configurable: %{session_id: "halted"})

    session = BeamWeaver.Core.ChatHistory.ETS.for_session(store, "halted")
    assert Enum.take(stream, 1) == [Messages.ai_chunk("he")]
    assert {:ok, []} = ChatHistory.get_messages(session)

    assert {:ok, full_stream} =
             Runnable.stream(runnable, "prompt", configurable: %{session_id: "halted"})

    assert Enum.to_list(full_stream) == [Messages.ai_chunk("he"), Messages.ai_chunk("llo")]

    assert {:ok, [%Message{content: "prompt"}, %Message{role: :assistant, content: "hello"}]} =
             ChatHistory.get_messages(session)
  end

  test "message history composes with async invoke and async stream handles" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/runnables/test_history.py
    # - async history wrappers preserve ordering and session state.
    store = BeamWeaver.Core.ChatHistory.ETS.new()

    runnable =
      Runnable.lambda(fn messages ->
        user_messages =
          messages
          |> Enum.filter(&match?(%Message{role: :user}, &1))
          |> Enum.map_join("\n", & &1.content)

        Message.assistant("you said: #{user_messages}")
      end)
      |> Runnable.with_history(history: store)

    first = Runnable.async_invoke(runnable, "hello", configurable: %{session_id: "async-history"})
    assert {:ok, %Message{content: "you said: hello"}} = Async.await(first)

    streamable =
      Runnable.generator(fn messages ->
        user_messages =
          messages
          |> Enum.filter(&match?(%Message{role: :user}, &1))
          |> Enum.map_join("\n", & &1.content)

        [Messages.ai_chunk("you said: #{user_messages}")]
      end)
      |> Runnable.with_history(history: store)

    handle =
      Runnable.async_stream(streamable, "again", configurable: %{session_id: "async-history"})

    assert {:ok, stream} = Async.await(handle)
    assert Enum.to_list(stream) == [Messages.ai_chunk("you said: hello\nagain")]

    session = BeamWeaver.Core.ChatHistory.ETS.for_session(store, "async-history")

    assert {:ok,
            [
              %Message{content: "hello"},
              %Message{content: "you said: hello"},
              %Message{content: "again"},
              %Message{content: "you said: hello\nagain"}
            ]} = ChatHistory.get_messages(session)
  end

  test "message history requires configured session id" do
    runnable =
      Runnable.lambda(& &1)
      |> Runnable.with_history(history: BeamWeaver.Core.ChatHistory.ETS.new())

    assert {:error, %Error{type: :missing_configurable}} = Runnable.invoke(runnable, "hello")
  end

  test "message history supports zero-arity history factories without session config" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/runnables/test_history.py
    # - a history factory may ignore session config and return a fixed history object.
    store = BeamWeaver.Core.ChatHistory.ETS.new()
    session = BeamWeaver.Core.ChatHistory.ETS.for_session(store, "fixed")

    runnable =
      Runnable.lambda(fn messages ->
        Message.assistant("seen: #{length(messages)}")
      end)
      |> Runnable.with_history(history: fn -> session end)

    assert {:ok, %Message{content: "seen: 1"}} = Runnable.invoke(runnable, "hello")
    assert {:ok, %Message{content: "seen: 3"}} = Runnable.invoke(runnable, "again")

    assert {:ok,
            [
              %Message{content: "hello"},
              %Message{content: "seen: 1"},
              %Message{content: "again"},
              %Message{content: "seen: 3"}
            ]} = ChatHistory.get_messages(session)

    assert [] = Runnable.config_specs(runnable)
  end

  test "message history rejects unsupported assistant outputs without appending the turn" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/runnables/test_history.py
    # - invalid output values should fail at the history boundary instead of being persisted.
    store = BeamWeaver.Core.ChatHistory.ETS.new()

    runnable =
      Runnable.lambda(fn _messages -> false end)
      |> Runnable.with_history(history: store)

    assert {:error, %Error{type: :invalid_message_history_output}} =
             Runnable.invoke(runnable, "hello", configurable: %{session_id: "invalid"})

    session = BeamWeaver.Core.ChatHistory.ETS.for_session(store, "invalid")
    assert {:ok, []} = ChatHistory.get_messages(session)
  end

  test "transform streams through sequences and default transform merges addable chunks" do
    chain =
      Runnable.sequence([
        Runnable.passthrough(),
        Runnable.generator(fn stream -> Stream.map(stream, &String.upcase/1) end)
      ])

    assert {:ok, stream} = Runnable.transform(chain, ["a", "b"])
    assert Enum.to_list(stream) == ["A", "B"]

    default = Runnable.lambda(fn value -> {:ok, value <> "!"} end)
    assert {:ok, merged} = Runnable.transform(default, ["he", "llo"])
    assert Enum.to_list(merged) == ["hello!"]
  end

  test "stream_events and stream_log project typed events and run log patches" do
    runnable = Runnable.generator(fn _ -> ["a", "b"] end)

    assert {:ok, events} = Runnable.stream_events(runnable, :input, run_id: "events-run")
    events = Enum.to_list(events)

    assert [%Envelope{event: %Events.Debug{payload: %{kind: :start}}} | _] = events
    assert Enum.any?(events, &match?(%Envelope{event: %Events.Custom{payload: "a"}}, &1))
    assert Enum.any?(events, &match?(%Envelope{event: %Events.Done{}}, &1))

    assert {:ok, patches} = Runnable.stream_log(runnable, :input, run_id: "log-run")
    patches = Enum.to_list(patches)

    assert [%BeamWeaver.Runnable.RunLogPatch{ops: [%{"op" => "replace", "path" => ""}]} | _] =
             patches

    assert Enum.any?(
             patches,
             &match?(
               %BeamWeaver.Runnable.RunLogPatch{
                 ops: [%{"path" => "/streamed_output/-", "value" => "a"}]
               },
               &1
             )
           )

    assert List.last(patches) == %BeamWeaver.Runnable.RunLogPatch{
             ops: [%{"op" => "replace", "path" => "/final_output", "value" => ["a", "b"]}]
           }
  end

  test "stream_events filters typed envelopes by runnable name and tags" do
    runnable = Runnable.generator(fn _ -> ["a", "b"] end, name: :numbers)

    assert {:ok, included} =
             Runnable.stream_events(runnable, :input,
               tags: [:keep],
               include_names: ["numbers"],
               include_tags: [:keep]
             )

    included = Enum.to_list(included)
    assert length(included) == 4
    assert Enum.all?(included, &(&1.node == "numbers"))
    assert Enum.all?(included, &(:keep in &1.metadata.tags))

    assert {:ok, excluded_by_name} =
             Runnable.stream_events(runnable, :input,
               include_names: ["other"],
               tags: [:keep]
             )

    assert Enum.to_list(excluded_by_name) == []

    assert {:ok, excluded_by_tag} =
             Runnable.stream_events(runnable, :input,
               tags: [:keep, :blocked],
               exclude_tags: [:blocked]
             )

    assert Enum.to_list(excluded_by_tag) == []
  end

  test "safe specs export supported built-ins and import through explicit registry" do
    runnable =
      Runnable.sequence([
        Runnable.passthrough(),
        Runnable.pick(:answer)
      ])
      |> Runnable.bind(mode: :safe)

    assert {:ok, spec} = Runnable.to_spec(runnable)
    refute inspect(spec) =~ "binary_to_term"

    assert {:ok, rebuilt} = Runnable.from_spec(spec)
    assert {:ok, 42} = Runnable.invoke(rebuilt, %{answer: 42})

    assert {:error, %Error{type: :unsupported_runnable_spec}} =
             Runnable.to_spec(Runnable.lambda(& &1))

    assert {:error, %Error{type: :unknown_runnable_spec}} =
             Runnable.from_spec(%{"type" => "not_registered"})
  end

  test "safe specs can be extended only through an explicit caller registry" do
    spec = %{"type" => "constant_test_runnable", "value" => 12}

    assert {:error, %Error{type: :unknown_runnable_spec}} =
             Runnable.from_spec(spec)

    registry =
      Map.put(
        BeamWeaver.Runnable.Registry.default(),
        "constant_test_runnable",
        fn spec, _registry ->
          {:ok, Runnable.lambda(fn _ -> {:ok, Map.fetch!(spec, "value")} end)}
        end
      )

    assert {:ok, runnable} = Runnable.from_spec(spec, registry: registry)
    assert {:ok, 12} = Runnable.invoke(runnable, :ignored)

    assert {:error, %Error{type: :invalid_runnable_spec}} =
             Runnable.from_spec(%{"steps" => []}, registry: registry)
  end

  test "graph introspection renders deterministic mermaid ascii and opt-in PNG" do
    runnable =
      Runnable.sequence([
        Runnable.passthrough(),
        Runnable.parallel(%{answer: Runnable.pick(:answer)})
      ])

    graph = Runnable.get_graph(runnable)
    assert map_size(graph.nodes) == 2
    assert graph.edges == [{"step_0", "step_1"}]

    assert Runnable.draw_mermaid(runnable) =~ "graph TD"
    assert Runnable.draw_ascii(runnable) == "step_0 -> step_1"
    assert {:ok, {:png, mermaid}} = Runnable.draw_png(runnable, renderer: &{:png, &1})
    assert mermaid =~ "graph TD"

    assert {:error, %Error{type: :png_renderer_not_configured}} = Runnable.draw_png(runnable)
  end

  test "runnable graph renderer supports safe ids frontmatter api URLs and trims" do
    graph = %BeamWeaver.Runnable.Graph{
      nodes: %{
        "__start__" => %{label: "Start"},
        "#foo*&!" => %{label: "Special"},
        "结束" => %{label: "Done"}
      },
      edges: [{"__start__", "#foo*&!"}, {"#foo*&!", "结束", "ok"}]
    }

    assert BeamWeaver.Runnable.Graph.safe_id("#foo*&!") == "\\23foo\\2a\\26\\21"

    mermaid =
      BeamWeaver.Runnable.Graph.Renderer.to_mermaid(graph,
        frontmatter_config: %{
          "config" => %{
            "theme" => "neutral",
            "themeVariables" => %{"primaryColor" => "#e2e2e2"}
          }
        }
      )

    assert mermaid =~ "---\nconfig:"
    assert mermaid =~ "\\23foo\\2a\\26\\21"
    assert mermaid =~ "\\7ed3\\675f"

    assert BeamWeaver.Runnable.Graph.Renderer.api_url("graph TD\nA-->B",
             base_url: "https://custom.mermaid.com",
             background_color: "white"
           ) =~ "https://custom.mermaid.com/img/"

    assert BeamWeaver.Runnable.Graph.Renderer.api_url("graph TD\nA-->B",
             background_color: "white"
           ) =~ "bgColor=%21white"

    assert BeamWeaver.Runnable.Graph.Renderer.api_url("graph TD\nA-->B",
             background_color: "#ffffff"
           ) =~ "bgColor=%23ffffff"

    assert {:ok, {:rendered, _mermaid, url}} =
             BeamWeaver.Runnable.Graph.Renderer.to_png(graph,
               renderer: fn mermaid, url -> {:rendered, mermaid, url} end,
               base_url: "https://custom.mermaid.com"
             )

    assert url =~ "https://custom.mermaid.com/img/"

    single = BeamWeaver.Runnable.Graph.single(Runnable.passthrough())
    assert {_id, %{label: "Passthrough"}} = BeamWeaver.Runnable.Graph.first_node(single)
    assert {_id, %{label: "Passthrough"}} = BeamWeaver.Runnable.Graph.last_node(single)

    trim_graph = %BeamWeaver.Runnable.Graph{
      nodes: %{"input" => %{label: "Input"}, "run" => %{label: "Run"}},
      edges: [{"input", "run"}]
    }

    trimmed = BeamWeaver.Runnable.Graph.trim_first_node(trim_graph)
    refute Map.has_key?(trimmed.nodes, "input")
    assert trimmed.edges == []
  end

  test "with_types overrides schemas and wrappers expose config specs" do
    runnable =
      Runnable.passthrough()
      |> Runnable.with_types(input: %{"type" => "string"}, output: %{"type" => "number"})

    assert Runnable.input_schema(runnable) == %{"type" => "string"}
    assert Runnable.output_schema(runnable) == %{"type" => "number"}

    configured =
      %BeamWeaver.Models.FakeChatModel{}
      |> Runnable.configure(response: [id: "response"])
      |> Runnable.alternatives(:model, %{other: Runnable.passthrough()})
      |> Runnable.with_history(history: BeamWeaver.Core.ChatHistory.ETS.new())

    ids = configured |> Runnable.config_specs() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["model", "response", "session_id"]

    history =
      Runnable.passthrough()
      |> Runnable.with_history(
        history: BeamWeaver.Core.ChatHistory.ETS.new(),
        input_messages_key: :input,
        history_messages_key: :history
      )

    assert %{
             "title" => "RunnableWithChatHistoryInput",
             "type" => "object",
             "properties" => %{"input" => _}
           } = Runnable.input_schema(history)

    assert Runnable.output_schema(history) == %{
             "title" => "RunnableWithChatHistoryOutput",
             "type" => "object"
           }

    typed_history =
      Runnable.passthrough()
      |> Runnable.with_types(output: %{"type" => "string"})
      |> Runnable.with_history(history: BeamWeaver.Core.ChatHistory.ETS.new())

    assert Runnable.output_schema(typed_history) == %{"type" => "string"}
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
