defmodule BeamWeaver.Tracing.Exporters.WeaveScope do
  @moduledoc """
  Native WeaveScope trace exporter.

  This exporter emits BeamWeaver observations directly to WeaveScope's native
  ingestion endpoint.
  """

  @behaviour BeamWeaver.Tracing.Exporter

  require Logger

  alias BeamWeaver.Config
  alias BeamWeaver.Tracing.Run
  alias BeamWeaver.Tracing.ValueEncoder

  @default_endpoint "http://localhost:4000"
  @default_error_body_limit 8_192
  @internal_response_keys ~w(_beamweaver_response_headers _beamweaver_response_header_metadata _beamweaver_provider_headers)

  @impl true
  def export(event, %Run{} = run, opts) do
    export_batch([{event, run, opts}], opts)
  end

  @spec export_batch([{atom(), Run.t(), keyword()}], keyword()) ::
          :ok | {:rejected, [map()]} | {:error, term()}
  def export_batch([], _opts), do: :ok

  def export_batch(items, opts) when is_list(items) do
    endpoint = Config.option(opts, :endpoint, [:weave_scope, :endpoint], @default_endpoint)
    api_key = Config.option(opts, :api_key, [:weave_scope, :api_key])
    transport = Keyword.get(opts, :transport, Req)

    if blank?(api_key) or blank?(endpoint) do
      :ok
    else
      url = endpoint |> String.trim_trailing("/") |> Kernel.<>("/api/v1/observations/batch")

      events =
        Enum.map(items, fn {event, %Run{} = run, item_opts} -> to_event(event, run, Keyword.merge(opts, item_opts)) end)

      case transport.post(
             url,
             json: %{"events" => events},
             headers: headers(api_key),
             finch_private: %{
               beam_weaver_exporter: :weave_scope,
               operation: :batch,
               url: url,
               event_count: length(events)
             },
             retry: false
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          case rejected_results(body) do
            [] -> :ok
            rejected -> {:rejected, rejected}
          end

        {:ok, response} ->
          error = response_error(response, opts)
          log_export_failure(url, length(events), error)
          {:error, error}

        {:error, reason} ->
          log_export_failure(url, length(events), reason)
          {:error, reason}
      end
    end
  rescue
    exception -> {:error, exception}
  end

  @doc false
  @spec to_event(atom(), Run.t(), keyword()) :: map()
  def to_event(event, %Run{} = run, opts \\ []) do
    metadata =
      run.metadata
      |> library_metadata()
      |> ValueEncoder.encode()
      |> scrub_export_value()

    context_metadata = (run.context_metadata || %{}) |> ValueEncoder.encode() |> scrub_export_value()
    inputs = run.inputs |> ValueEncoder.encode() |> scrub_export_value()
    outputs = run.outputs |> ValueEncoder.encode() |> scrub_export_value()
    usage = (run.usage || %{}) |> ValueEncoder.encode() |> scrub_export_value()
    error = run.error |> ValueEncoder.encode() |> scrub_export_value()
    response_metadata = metadata_value(metadata, "response_metadata") || %{}
    response_usage = metadata_value(response_metadata, "usage") || %{}

    %{
      "operation" => operation(event),
      "observation_id" => run.id,
      "trace_id" => run.trace_id || run.id,
      "parent_observation_id" => run.parent_id,
      "name" => run.name,
      "kind" => observation_kind(run.kind),
      "run_type" => native_run_type(run.kind),
      "status" => event_status(event, run.status),
      "start_time" => DateTime.to_iso8601(run.started_at),
      "end_time" => maybe_iso8601(run.ended_at),
      "event_version" => event_version(event, run),
      "tags" => ValueEncoder.encode(library_tags(run.tags)),
      "metadata" => metadata,
      "context_metadata" => context_metadata,
      "inputs" => inputs,
      "outputs" => outputs,
      "usage" => usage,
      "error" => error,
      "environment" => metadata_value(metadata, "environment") || metadata_value(context_metadata, "environment"),
      "version" =>
        metadata_value(metadata, "version") || metadata_value(context_metadata, "version") || configured_version(opts),
      "model_provider" =>
        metadata_value(metadata, "provider") || metadata_value(metadata, "model_provider") ||
          metadata_value(context_metadata, "provider") || metadata_value(context_metadata, "model_provider"),
      "model_name" =>
        metadata_value(metadata, "model") || metadata_value(metadata, "model_name") ||
          metadata_value(context_metadata, "model"),
      "request_id" => metadata_value(metadata, "request_id") || metadata_value(context_metadata, "request_id"),
      "finish_reason" => metadata_value(metadata, "finish_reason") || metadata_value(context_metadata, "finish_reason"),
      "service_tier" =>
        metadata_value(usage, "service_tier") || metadata_value(metadata, "service_tier") ||
          metadata_value(response_metadata, "service_tier") || metadata_value(response_usage, "service_tier") ||
          metadata_value(context_metadata, "service_tier"),
      "inference_geo" =>
        metadata_value(usage, "inference_geo") || metadata_value(metadata, "inference_geo") ||
          metadata_value(response_metadata, "inference_geo") || metadata_value(response_usage, "inference_geo") ||
          metadata_value(context_metadata, "inference_geo"),
      "custom_fields" => metadata_value(metadata, "custom_fields") || metadata_value(context_metadata, "custom_fields"),
      "scores" => metadata_value(metadata, "scores") || metadata_value(context_metadata, "scores")
    }
    |> BeamWeaver.MapShape.reject_nil_or_empty()
  end

  defp operation(:started), do: "start"
  defp operation(:ok), do: "finish"
  defp operation(:error), do: "error"
  defp operation(event), do: to_string(event)

  defp log_export_failure(url, event_count, reason) do
    Logger.debug(fn ->
      "BeamWeaver WeaveScope export failed endpoint=#{inspect(url)} event_count=#{event_count} error=#{inspect(reason)}"
    end)
  end

  defp observation_kind(kind) when is_atom(kind), do: observation_kind(Atom.to_string(kind))

  defp observation_kind(kind) when is_binary(kind) do
    case kind do
      "graph" -> "agent"
      "model" -> "generation"
      "llm" -> "generation"
      "workflow" -> "chain"
      value when value in ~w(event span generation agent tool chain retriever evaluator embedding guardrail) -> value
      _other -> "span"
    end
  end

  defp native_run_type(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp native_run_type(kind), do: to_string(kind)

  defp event_status(:started, _status), do: "running"
  defp event_status(:ok, _status), do: "success"
  defp event_status(:error, _status), do: "error"
  defp event_status(_event, :ok), do: "success"
  defp event_status(_event, status) when status in [:running, :error], do: Atom.to_string(status)
  defp event_status(_event, status) when status in ["success", "ok"], do: "success"
  defp event_status(_event, status) when status in ["running", "error", "pending"], do: status
  defp event_status(_event, _status), do: "pending"

  defp event_version(event, %Run{} = run) do
    timestamp = if event == :started, do: run.started_at, else: run.ended_at || run.started_at
    DateTime.to_unix(timestamp, :microsecond) * 10 + lifecycle_rank(event)
  end

  @doc false
  def lifecycle_rank(:started), do: 1
  def lifecycle_rank(:ok), do: 2
  def lifecycle_rank(:error), do: 3
  def lifecycle_rank(_event), do: 0

  defp configured_version(opts) do
    case Config.option(opts, :version, [:weave_scope, :version]) do
      value when value in [nil, ""] ->
        app = Config.option(opts, :otp_app, [:weave_scope, :otp_app], :beam_weaver)
        if version = Application.spec(app, :vsn) || Application.spec(:beam_weaver, :vsn), do: to_string(version)

      value ->
        to_string(value)
    end
  end

  defp library_metadata(metadata) when is_map(metadata) do
    Map.put(metadata, :beam_weaver_version, beam_weaver_version())
  end

  defp library_metadata(_metadata), do: %{beam_weaver_version: beam_weaver_version()}

  defp scrub_export_value(value, path \\ [])

  defp scrub_export_value(value, path) when is_map(value) do
    value
    |> drop_duplicate_header_containers(path)
    |> Enum.reject(fn {key, _value} -> to_string(key) in @internal_response_keys end)
    |> Map.new(fn {key, value} -> {key, scrub_export_value(value, [key | path])} end)
  end

  defp scrub_export_value(value, path) when is_list(value) do
    Enum.map(value, &scrub_export_value(&1, path))
  end

  defp scrub_export_value(value, _path), do: value

  defp drop_duplicate_header_containers(value, path) do
    if path_key?(List.first(path), :transport) or provider_metadata_raw_path?(path),
      do: Map.drop(value, [:headers, "headers"]),
      else: value
  end

  defp provider_metadata_raw_path?([raw_key, provider_metadata_key | _path]) do
    path_key?(raw_key, :raw) and path_key?(provider_metadata_key, :provider_metadata)
  end

  defp provider_metadata_raw_path?(_path), do: false

  defp path_key?(key, expected), do: key in [expected, Atom.to_string(expected)]

  defp library_tags(tags) do
    tags
    |> List.wrap()
    |> Kernel.++(["beam_weaver:#{beam_weaver_version()}"])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp beam_weaver_version, do: to_string(Application.spec(:beam_weaver, :vsn) || "unknown")

  defp metadata_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp metadata_value(_map, _key), do: nil

  defp maybe_iso8601(nil), do: nil
  defp maybe_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "beam-weaver/#{beam_weaver_version()} weavescope-exporter"}
    ]
  end

  defp rejected_results(%{"results" => results}) when is_list(results) do
    Enum.filter(results, &(Map.get(&1, "status") == "rejected"))
  end

  defp rejected_results(_body), do: []

  defp response_error(%{status: status, body: body}, opts) do
    limit = Keyword.get(opts, :error_body_limit, @default_error_body_limit)
    {:http_error, status, body_preview(body, limit)}
  end

  defp response_error(response, _opts), do: {:unexpected_response, inspect(response)}

  defp body_preview(body, limit) when is_binary(body), do: String.slice(body, 0, limit)

  defp body_preview(body, limit),
    do: body |> inspect(limit: :infinity, printable_limit: limit) |> String.slice(0, limit)

  defp blank?(value), do: value in [nil, ""]
end
