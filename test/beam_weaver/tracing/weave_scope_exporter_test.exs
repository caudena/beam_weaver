defmodule BeamWeaver.Tracing.WeaveScopeExporterTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Tracing.Exporters.WeaveScope
  alias BeamWeaver.Tracing.Exporters.WeaveScope.Queue
  alias BeamWeaver.Tracing.Run

  test "builds native observation payloads with safe BeamWeaver metadata encoding" do
    run =
      Run.new("google:gemini-3.5-flash",
        id: "model-run-1",
        trace_id: "domain-trace-1",
        parent_id: "chain-run-1",
        kind: :model,
        inputs: %{messages: [%{role: :user, content: "Find the ICP"}]},
        metadata: %{
          provider: :google,
          model: "gemini-3.5-flash",
          environment: "trace-prod",
          version: "trace-version-1",
          request_id: "req-123",
          finish_reason: :stop,
          custom_fields: %{"probe_id" => "probe-123"},
          response_format: %{
            strategy: :provider,
            validator: fn value -> {:ok, value} end
          }
        },
        context_metadata: %{
          configurable: %{thread_id: "hubai-domain-thread"},
          user_id: "user-42"
        },
        usage: %{
          input_tokens: 359,
          output_tokens: 2441,
          total_tokens: 2800,
          output_token_details: %{reasoning: 511}
        },
        started_at: ~U[2026-06-04 10:00:00Z]
      )

    run =
      %{
        run
        | status: :ok,
          ended_at: ~U[2026-06-04 10:00:03Z],
          outputs: %{structured_response: %{domain: "example.com"}}
      }

    event = WeaveScope.to_event(:ok, run, environment: "staging")

    assert event["operation"] == "finish"
    assert event["observation_id"] == "model-run-1"
    assert event["trace_id"] == "domain-trace-1"
    assert event["parent_observation_id"] == "chain-run-1"
    assert event["kind"] == "generation"
    assert event["run_type"] == "model"
    assert event["status"] == "success"
    assert event["environment"] == "trace-prod"
    assert event["version"] == "trace-version-1"
    refute Map.has_key?(event, "service" <> "_name")
    assert event["model_provider"] == "google"
    assert event["model_name"] == "gemini-3.5-flash"
    assert event["request_id"] == "req-123"
    assert event["finish_reason"] == "stop"
    assert event["custom_fields"] == %{"probe_id" => "probe-123"}
    assert event["event_version"] == DateTime.to_unix(~U[2026-06-04 10:00:03Z], :microsecond) * 10 + 2
    beam_weaver_version = Application.spec(:beam_weaver, :vsn) |> to_string()

    assert event["usage"][:output_token_details] == %{reasoning: 511}
    assert event["metadata"][:beam_weaver_version] == beam_weaver_version
    assert is_binary(event["metadata"][:response_format][:validator])
    assert "beam_weaver:#{beam_weaver_version}" in event["tags"]

    assert Jason.encode!(event)
  end

  test "does not use exporter options as environment fallback" do
    run =
      Run.new("support_agent",
        id: "run-1",
        trace_id: "trace-1",
        kind: :agent,
        started_at: ~U[2026-06-04 10:00:00Z]
      )

    refute Map.has_key?(WeaveScope.to_event(:started, run, environment: "staging"), "environment")
    refute Map.has_key?(WeaveScope.to_event(:started, run, []), "environment")
  end

  test "normalizes unexpected run statuses to the WeaveScope status contract" do
    run =
      Run.new("support_agent",
        id: "run-1",
        trace_id: "trace-1",
        kind: :agent,
        started_at: ~U[2026-06-04 10:00:00Z]
      )

    malformed = %{run | status: :warning}

    assert WeaveScope.to_event(:ok, malformed)["status"] == "success"
    assert WeaveScope.to_event(:finished, malformed)["status"] == "pending"
  end

  test "returns per-event rejections from WeaveScope batch responses" do
    run =
      Run.new("domain_discovery_agent",
        id: "bad-run",
        trace_id: "trace-1",
        kind: :graph,
        started_at: ~U[2026-06-04 10:00:00Z]
      )

    assert {:rejected, [%{"code" => "invalid_kind", "id" => "bad-run"}]} =
             WeaveScope.export_batch(
               [{:started, run, []}],
               api_key: "ws_test",
               endpoint: "http://weavescope.local",
               transport: BeamWeaver.Tracing.WeaveScopeRejectTransport
             )
  end

  test "queue dead-letters WeaveScope rejections without retrying them" do
    name = :"weavescope_queue_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Queue.start_link(
        name: name,
        api_key: "ws_test",
        endpoint: "http://weavescope.local",
        transport: BeamWeaver.Tracing.WeaveScopeRejectTransport,
        flush_interval: 0,
        retry_delay: 1,
        max_attempts: 3
      )

    run =
      Run.new("domain_discovery_agent",
        id: "bad-run",
        trace_id: "trace-1",
        kind: :graph,
        started_at: ~U[2026-06-04 10:00:00Z]
      )

    Queue.enqueue(pid, :started, run)
    assert Queue.flush(pid) == :ok

    assert [%{reason: :rejected, rejection: %{"code" => "invalid_kind", "id" => "bad-run"}}] =
             Queue.dead_letters(pid)

    GenServer.stop(pid)
  end

  test "queue coalesces buffered lifecycle events for the same observation" do
    {:ok, capture} =
      Agent.start_link(fn -> [] end, name: BeamWeaver.Tracing.WeaveScopeCaptureTransportAgent)

    name = :"weavescope_queue_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Queue.start_link(
        name: name,
        api_key: "ws_test",
        endpoint: "http://weavescope.local",
        transport: BeamWeaver.Tracing.WeaveScopeCaptureTransport,
        flush_interval: 10_000
      )

    run =
      Run.new("domain_discovery_agent",
        id: "agent-run",
        trace_id: "trace-1",
        kind: :graph,
        started_at: ~U[2026-06-04 10:00:00Z]
      )

    finished = %{run | status: :ok, ended_at: ~U[2026-06-04 10:00:02Z], outputs: %{ok: true}}

    Queue.enqueue(pid, :started, run)
    Queue.enqueue(pid, :ok, finished)
    assert Queue.flush(pid) == :ok

    assert [%{"events" => [event]}] = Agent.get(capture, &Enum.reverse/1)
    assert event["observation_id"] == "agent-run"
    assert event["operation"] == "finish"
    assert event["status"] == "success"

    GenServer.stop(pid)
    Agent.stop(capture)
  end
end

defmodule BeamWeaver.Tracing.WeaveScopeRejectTransport do
  def post(_url, _opts) do
    {:ok,
     %{
       status: 202,
       body: %{
         "results" => [
           %{
             "index" => 0,
             "id" => "bad-run",
             "status" => "rejected",
             "code" => "invalid_kind",
             "reason" => "kind is invalid"
           }
         ]
       }
     }}
  end
end

defmodule BeamWeaver.Tracing.WeaveScopeCaptureTransport do
  def post(_url, opts) do
    Agent.update(BeamWeaver.Tracing.WeaveScopeCaptureTransportAgent, &[opts[:json] | &1])
    {:ok, %{status: 202, body: %{"results" => []}}}
  end
end
