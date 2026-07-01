defmodule BeamWeaver.Tracing.LifecycleTest do
  use ExUnit.Case

  alias BeamWeaver.Anthropic
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Google
  alias BeamWeaver.Moonshot
  alias BeamWeaver.OpenAI
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Context
  alias BeamWeaver.Tracing.Run
  alias BeamWeaver.Tracing.Runner
  alias BeamWeaver.XAI
  alias BeamWeaver.ZAI

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

  test "uses WeaveScope queue as default exporter when WeaveScope config is complete" do
    original_tracing = Application.get_env(:beam_weaver, :tracing)
    original_weave_scope = Application.get_env(:beam_weaver, :weave_scope)

    on_exit(fn ->
      Application.put_env(:beam_weaver, :tracing, original_tracing)
      Application.put_env(:beam_weaver, :weave_scope, original_weave_scope)
    end)

    Application.put_env(:beam_weaver, :tracing, [])
    Application.put_env(:beam_weaver, :weave_scope, api_key: "ws_test", endpoint: "http://weavescope.local")

    assert Tracing.configured_exporter() == BeamWeaver.Tracing.Exporters.WeaveScope.Queue
    assert Tracing.exporter_configured?()

    Application.put_env(:beam_weaver, :tracing, exporter: BeamWeaver.Tracing.Exporters.Noop)
    assert Tracing.configured_exporter() == BeamWeaver.Tracing.Exporters.Noop

    Application.put_env(:beam_weaver, :tracing, [])
    Application.put_env(:beam_weaver, :weave_scope, api_key: nil, endpoint: "http://weavescope.local")

    refute Tracing.exporter_configured?()
  end

  test "model traces preserve provider-specific invocation params without client config" do
    cases = [
      {
        OpenAI.ChatModel.new(
          model: "gpt-5.5",
          api_key: "sk-nope",
          endpoint: "https://example.invalid",
          temperature: 0.2,
          max_output_tokens: 512,
          service_tier: :flex,
          prompt_cache_key: "openai-cache"
        ),
        [reasoning: %{effort: "low"}, instructions: "raw prompt text"],
        %{
          temperature: 0.2,
          max_output_tokens: 512,
          service_tier: :flex,
          prompt_cache_key: "openai-cache",
          reasoning: %{effort: "low"}
        }
      },
      {
        Anthropic.ChatModel.new(
          model: "claude-haiku-4-5-20251001",
          api_key: "sk-ant-nope",
          thinking: %{type: "enabled", budget_tokens: 1_024},
          top_k: 40,
          stop_sequences: ["done"]
        ),
        [],
        %{thinking: %{type: "enabled", budget_tokens: 1_024}, top_k: 40, stop_sequences: ["done"]}
      },
      {
        Google.ChatModel.new(
          model: "gemini-3.5-flash",
          api_key: "google-nope",
          thinking_budget: 2_048,
          thinking_level: :high,
          candidate_count: 2
        ),
        [],
        %{thinking_budget: 2_048, thinking_level: :high, candidate_count: 2}
      },
      {
        XAI.ChatModel.new(
          model: "grok-4.3",
          api_key: "xai-nope",
          x_grok_conv_id: "xai-conv",
          prompt_cache_key: "xai-cache",
          reasoning_effort: :low,
          search_parameters: %{mode: "auto"}
        ),
        [],
        %{
          x_grok_conv_id: "xai-conv",
          prompt_cache_key: "xai-cache",
          reasoning_effort: :low,
          search_parameters: %{mode: "auto"}
        }
      },
      {
        Moonshot.ChatModel.new(
          model: "kimi-k2.6",
          api_key: "moonshot-nope",
          stream_usage: false,
          prompt_cache_key: "cache-1"
        ),
        [],
        %{stream_usage: false, prompt_cache_key: "cache-1"}
      },
      {
        ZAI.ChatModel.new(
          model: "glm-5.2",
          api_key: "zai-nope",
          do_sample: true,
          tool_stream: true,
          request_id: "req-1"
        ),
        [],
        %{do_sample: true, tool_stream: true, request_id: "req-1"}
      }
    ]

    for {model, opts, expected_params} <- cases do
      Tracing.reset()
      Context.clear()

      assert {:ok, %Message{content: "ok"}} =
               BeamWeaver.Core.ChatModel.trace_call(
                 model,
                 [Message.user("hello")],
                 opts ++ [exporter: BeamWeaver.Tracing.TestExporter, exporter_opts: [test_pid: self()]],
                 fn -> {:ok, Message.assistant("ok")} end
               )

      assert_receive {:trace_export, :started, %Run{kind: :model}}
      assert_receive {:trace_export, :ok, %Run{kind: :model} = run}

      for {key, value} <- expected_params do
        assert Map.get(run.metadata.invocation_params, key) == value
      end

      assert run.metadata.invocation_params.model == run.metadata.model_name
      assert run.metadata.invocation_params.model_name == run.metadata.model_name
      refute Map.has_key?(run.metadata.invocation_params, :api_key)
      refute Map.has_key?(run.metadata.invocation_params, :endpoint)
      refute Map.has_key?(run.metadata.invocation_params, :transport)
      refute Map.has_key?(run.metadata.invocation_params, :metadata)
      refute Map.has_key?(run.metadata.invocation_params, :instructions)
    end

    Tracing.reset()
    Context.clear()
  end

  test "model trace usage keeps provider pricing and token detail fields" do
    model = Anthropic.ChatModel.new(model: "claude-sonnet-5", api_key: "anthropic-nope")

    assert {:ok, %Message{content: "ok"}} =
             BeamWeaver.Core.ChatModel.trace_call(
               model,
               [Message.user("hello")],
               [
                 exporter: BeamWeaver.Tracing.TestExporter,
                 exporter_opts: [test_pid: self()]
               ],
               fn ->
                 {:ok,
                  Message.assistant("ok",
                    usage_metadata: %{
                      input_tokens: 100,
                      output_tokens: 20,
                      total_tokens: 120,
                      input_token_details: %{cache_read: 80, cache_creation: 10},
                      output_token_details: %{thinking_tokens: 12},
                      service_tier: "batch",
                      inference_geo: "us"
                    }
                  )}
               end
             )

    assert_receive {:trace_export, :started, %Run{kind: :model}}
    assert_receive {:trace_export, :ok, %Run{kind: :model} = run}

    assert run.usage.input_tokens == 100
    assert run.usage.output_tokens == 20
    assert run.usage.cache_read_tokens == 80
    assert run.usage.cache_creation_tokens == 10
    assert run.usage.thinking_tokens == 12
    assert run.usage.service_tier == "batch"
    assert run.usage.inference_geo == "us"
    assert run.metadata.usage_metadata.service_tier == "batch"
    assert run.metadata.usage_metadata.inference_geo == "us"
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
