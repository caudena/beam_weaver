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

      payload = %{"events" => events}

      case transport.post(
             url,
             json: payload,
             headers: headers(api_key),
             finch_private: finch_private(:batch, url, payload),
             retry: false
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          rejected = rejected_results(body)

          if rejected == [] do
            :ok
          else
            {:rejected, rejected}
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
      "environment" => environment(metadata, context_metadata),
      "version" => version(metadata, context_metadata, opts)
    }
    |> maybe_put_model_fields(metadata, context_metadata, usage)
    |> maybe_put(
      "custom_fields",
      metadata_value(metadata, "custom_fields") || metadata_value(context_metadata, "custom_fields")
    )
    |> maybe_put(
      "scores",
      metadata_value(metadata, "scores") || metadata_value(context_metadata, "scores")
    )
    |> reject_blank_values()
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

  defp observation_kind(:graph), do: "agent"
  defp observation_kind(:model), do: "generation"
  defp observation_kind(:llm), do: "generation"
  defp observation_kind(:agent), do: "agent"
  defp observation_kind(:workflow), do: "chain"
  defp observation_kind(:chain), do: "chain"
  defp observation_kind(:tool), do: "tool"
  defp observation_kind(:retriever), do: "retriever"
  defp observation_kind(:evaluator), do: "evaluator"
  defp observation_kind(:embedding), do: "embedding"
  defp observation_kind(:guardrail), do: "guardrail"
  defp observation_kind(:event), do: "event"
  defp observation_kind(:span), do: "span"
  defp observation_kind(kind) when is_atom(kind), do: "span"

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

  defp event_version(:started, %Run{started_at: started_at}) do
    lifecycle_version(started_at, 1)
  end

  defp event_version(:ok, %Run{ended_at: ended_at, started_at: started_at}) do
    lifecycle_version(ended_at || started_at, 2)
  end

  defp event_version(:error, %Run{ended_at: ended_at, started_at: started_at}) do
    lifecycle_version(ended_at || started_at, 3)
  end

  defp event_version(_event, %Run{ended_at: ended_at, started_at: started_at}) do
    lifecycle_version(ended_at || started_at, 0)
  end

  defp lifecycle_version(%DateTime{} = datetime, rank) do
    DateTime.to_unix(datetime, :microsecond) * 10 + rank
  end

  defp environment(metadata, context_metadata) do
    metadata_value(metadata, "environment") ||
      metadata_value(context_metadata, "environment")
  end

  defp version(metadata, context_metadata, opts) do
    metadata_value(metadata, "version") ||
      metadata_value(context_metadata, "version") ||
      configured_version(opts)
  end

  defp configured_version(opts) do
    case Config.option(opts, :version, [:weave_scope, :version]) do
      value when value in [nil, ""] ->
        opts
        |> Config.option(:otp_app, [:weave_scope, :otp_app], :beam_weaver)
        |> application_version()

      value ->
        to_string(value)
    end
  end

  defp application_version(app) do
    case Application.spec(app, :vsn) || Application.spec(:beam_weaver, :vsn) do
      nil -> nil
      version -> to_string(version)
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
    |> Enum.reject(fn {key, _value} -> internal_response_key?(key) end)
    |> Map.new(fn {key, value} -> {key, scrub_export_value(value, [key | path])} end)
  end

  defp scrub_export_value(value, path) when is_list(value) do
    Enum.map(value, &scrub_export_value(&1, path))
  end

  defp scrub_export_value(value, _path), do: value

  defp drop_duplicate_header_containers(value, path) when is_map(value) do
    cond do
      path_key?(List.first(path), :transport) ->
        Map.drop(value, [:headers, "headers"])

      provider_metadata_raw_path?(path) ->
        Map.drop(value, [:headers, "headers"])

      true ->
        value
    end
  end

  defp provider_metadata_raw_path?([raw_key, provider_metadata_key | _path]) do
    path_key?(raw_key, :raw) and path_key?(provider_metadata_key, :provider_metadata)
  end

  defp provider_metadata_raw_path?(_path), do: false

  defp path_key?(key, expected) when is_atom(key), do: key == expected
  defp path_key?(key, expected) when is_binary(key), do: key == Atom.to_string(expected)
  defp path_key?(_key, _expected), do: false

  defp internal_response_key?(key) do
    key in [
      :_beamweaver_response_headers,
      "_beamweaver_response_headers",
      :_beamweaver_response_header_metadata,
      "_beamweaver_response_header_metadata",
      :_beamweaver_provider_headers,
      "_beamweaver_provider_headers"
    ]
  end

  defp library_tags(tags) do
    tags
    |> List.wrap()
    |> Kernel.++(["beam_weaver:#{beam_weaver_version()}"])
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp beam_weaver_version do
    Application.spec(:beam_weaver, :vsn)
    |> case do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp maybe_put_model_fields(event, metadata, context_metadata, usage) do
    metadata = metadata || %{}
    context_metadata = context_metadata || %{}
    response_metadata = metadata_value(metadata, "response_metadata") || %{}
    response_usage = metadata_value(response_metadata, "usage") || %{}

    event
    |> maybe_put(
      "model_provider",
      metadata_value(metadata, "provider") || metadata_value(metadata, "model_provider") ||
        metadata_value(context_metadata, "provider") || metadata_value(context_metadata, "model_provider")
    )
    |> maybe_put(
      "model_name",
      metadata_value(metadata, "model") || metadata_value(metadata, "model_name") ||
        metadata_value(context_metadata, "model")
    )
    |> maybe_put("request_id", metadata_value(metadata, "request_id") || metadata_value(context_metadata, "request_id"))
    |> maybe_put(
      "finish_reason",
      metadata_value(metadata, "finish_reason") || metadata_value(context_metadata, "finish_reason")
    )
    |> maybe_put(
      "service_tier",
      metadata_value(usage, "service_tier") || metadata_value(metadata, "service_tier") ||
        metadata_value(response_usage, "service_tier") ||
        metadata_value(context_metadata, "service_tier")
    )
    |> maybe_put(
      "inference_geo",
      metadata_value(usage, "inference_geo") || metadata_value(metadata, "inference_geo") ||
        metadata_value(response_usage, "inference_geo") ||
        metadata_value(context_metadata, "inference_geo")
    )
  end

  defp metadata_value(map, key) when is_map(map) do
    Map.get(map, key) || existing_atom_value(map, key)
  end

  defp metadata_value(_map, _key), do: nil

  defp existing_atom_value(map, key) when is_binary(key) do
    atom_key = String.to_existing_atom(key)
    Map.get(map, atom_key)
  rescue
    ArgumentError -> nil
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_iso8601(nil), do: nil
  defp maybe_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", "application/json"},
      user_agent_header()
    ]
  end

  defp user_agent_header do
    version = Application.spec(:beam_weaver, :vsn) || "unknown"
    {"user-agent", "beam-weaver/#{version} weavescope-exporter"}
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

  defp finch_private(operation, url, payload) do
    %{
      beam_weaver_exporter: :weave_scope,
      operation: operation,
      url: url,
      event_count: length(Map.get(payload, "events", []))
    }
  end

  defp reject_blank_values(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp blank?(value), do: value in [nil, ""]
end
