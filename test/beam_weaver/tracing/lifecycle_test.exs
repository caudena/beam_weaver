defmodule BeamWeaver.Tracing.LifecycleTest do
  use ExUnit.Case

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Context
  alias BeamWeaver.Tracing.Run
  alias BeamWeaver.Tracing.Runner

  @uuidv7_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  setup do
    Tracing.reset()
    Context.clear()

    on_exit(fn ->
      Tracing.reset()
      Context.clear()
    end)

    :ok
  end

  test "generated trace run IDs are UUIDv7" do
    run = Run.new("generated")

    assert run.id =~ @uuidv7_regex
    assert run.trace_id == run.id
  end

  test "records run lifecycle with redacted inputs, outputs, metadata, and usage" do
    {:ok, run} =
      Tracing.start_run("openai request",
        kind: :model,
        tags: [:openai, "responses"],
        inputs: %{"prompt" => "hello", "api_key" => "plain-secret"},
        metadata: %{"request_id" => "req_123", "authorization" => "Bearer live-token"},
        exporter: BeamWeaver.Tracing.TestExporter,
        exporter_opts: [test_pid: self()]
      )

    assert_receive {:trace_export, :started, %Run{id: run_id}}
    assert run_id == run.id

    assert {:ok, finished} =
             Tracing.finish_run(run,
               outputs: %{"text" => "ok", "secret" => "plain-output-secret"},
               usage: %{"input_tokens" => 4, "api_key" => "plain-usage-secret"},
               exporter: BeamWeaver.Tracing.TestExporter,
               exporter_opts: [test_pid: self()]
             )

    assert_receive {:trace_export, :ok, %Run{id: ^run_id, status: :ok}}
    assert finished.status == :ok
    assert finished.ended_at
    assert finished.tags == ["openai", "responses"]

    stored = inspect(finished)

    refute stored =~ "plain-secret"
    refute stored =~ "live-token"
    refute stored =~ "plain-output-secret"
    refute stored =~ "plain-usage-secret"
    assert stored =~ "hello"
    assert stored =~ "ok"
    assert stored =~ BeamWeaver.Transport.Redactor.redacted()
  end

  test "records failed runs without leaking exception secrets" do
    {:ok, run} = Tracing.start_run("tool call")
    exception = RuntimeError.exception("failed with sk-live-secret")

    assert {:ok, failed} = Tracing.fail_run(run, exception)
    assert failed.status == :error
    assert failed.error.type =~ "RuntimeError"
    refute inspect(failed) =~ "sk-live-secret"
    assert inspect(failed) =~ BeamWeaver.Transport.Redactor.redacted()
  end

  test "records struct inputs without crashing the runtime trace path" do
    {:ok, run} =
      Tracing.start_run("model call",
        kind: :model,
        inputs: [Message.user("hello")]
      )

    assert [%{role: :user, content: "hello"}] = run.inputs
  end

  test "with_run marks a raised exception as failed and reraises it" do
    assert_raise RuntimeError, "boom", fn ->
      Tracing.with_run(
        "failing operation",
        [exporter: BeamWeaver.Tracing.TestExporter, exporter_opts: [test_pid: self()]],
        fn ->
          raise "boom"
        end
      )
    end

    assert_receive {:trace_export, :started, %Run{name: "failing operation"}}
    assert_receive {:trace_export, :error, %Run{name: "failing operation"} = failed}
    assert failed.status == :error
  end

  test "runner centralizes finish fail raise and catch lifecycle" do
    exporter_opts = [exporter: BeamWeaver.Tracing.TestExporter, exporter_opts: [test_pid: self()]]

    assert {:ok, :done} =
             Runner.run("runner success", [kind: :tool], exporter_opts, fn -> {:ok, :done} end, fn
               run, {:ok, value} = ok ->
                 Tracing.finish_run(run, exporter_opts ++ [outputs: %{value: value}])
                 ok
             end)

    assert_receive {:trace_export, :started, %Run{name: "runner success"}}
    assert_receive {:trace_export, :ok, %Run{name: "runner success", status: :ok}}

    assert {:error, :bad} =
             Runner.run("runner tagged error", [], exporter_opts, fn -> {:error, :bad} end, fn
               run, {:error, reason} = error ->
                 Tracing.fail_run(run, reason, exporter_opts)
                 error
             end)

    assert_receive {:trace_export, :started, %Run{name: "runner tagged error"}}
    assert_receive {:trace_export, :error, %Run{name: "runner tagged error", status: :error}}

    assert_raise RuntimeError, "boom", fn ->
      Runner.run("runner raise", [], exporter_opts, fn -> raise "boom" end, fn _run, result ->
        result
      end)
    end

    assert_receive {:trace_export, :started, %Run{name: "runner raise"}}
    assert_receive {:trace_export, :error, %Run{name: "runner raise", status: :error}}

    try do
      Runner.run("runner catch", [], exporter_opts, fn -> throw(:boom) end, fn _run, result ->
        result
      end)
    catch
      :throw, :boom -> :ok
    end

    assert_receive {:trace_export, :started, %Run{name: "runner catch"}}
    assert_receive {:trace_export, :error, %Run{name: "runner catch", status: :error}}
  end

  test "with_chain_group records a chain-kind grouped run" do
    result =
      Tracing.with_chain_group("grouped chain", [metadata: %{source: :test}], fn ->
        assert Tracing.capture_context().run_id
        :ok
      end)

    assert result == :ok

    [%Run{name: "grouped chain"} = run] =
      BeamWeaver.Tracing.Store.list()

    assert run.kind == :chain
    assert run.status == :ok
    assert run.metadata.source == :test
  end

  test "dispatch_event emits telemetry with current trace context" do
    handler_id = {__MODULE__, self(), make_ref()}

    :telemetry.attach(
      handler_id,
      [:beam_weaver, :tracing, :event],
      &__MODULE__.handle_telemetry/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, run} = Tracing.start_run("stream observer", kind: :model)

    assert :ok =
             Tracing.dispatch_event("LLM New Token", %{token: "hi"},
               tags: [:stream],
               metadata: %{node: :model}
             )

    assert_receive {:tracing_event, [:beam_weaver, :tracing, :event], %{count: 1}, metadata}

    assert metadata.event == "llm_new_token"
    assert metadata.payload == %{token: "hi"}
    assert metadata.run_id == run.id
    assert metadata.trace_id == run.trace_id
    assert metadata.tags == ["stream"]
    assert metadata.metadata == %{node: :model}
  end

  test "exporter failures do not break tracing calls" do
    assert {:ok, run} =
             Tracing.start_run("exporter failure", exporter: BeamWeaver.Tracing.FailingExporter)

    assert {:ok, %Run{status: :ok}} =
             Tracing.finish_run(run, exporter: BeamWeaver.Tracing.FailingExporter)
  end

  def handle_telemetry(event, measurements, metadata, test_pid) do
    send(test_pid, {:tracing_event, event, measurements, metadata})
  end
end

defmodule BeamWeaver.Tracing.TestExporter do
  @behaviour BeamWeaver.Tracing.Exporter

  @impl true
  def export(event, run, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:trace_export, event, run})
    :ok
  end
end

defmodule BeamWeaver.Tracing.FailingExporter do
  @behaviour BeamWeaver.Tracing.Exporter

  @impl true
  def export(_event, _run, _opts) do
    raise "export failed"
  end
end
