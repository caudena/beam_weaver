defmodule BeamWeaver.Tracing.Exporters.LangSmith do
  @moduledoc """
  LangSmith-compatible trace exporter.

  The exporter keeps BeamWeaver tracing backend-neutral: local tracing records
  remain `BeamWeaver.Tracing.Run` structs, and this module translates them at
  the exporter boundary.
  """

  @behaviour BeamWeaver.Tracing.Exporter

  alias BeamWeaver.Config
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Tracing.Exporters.LangSmith.ValueEncoder
  alias BeamWeaver.Tracing.Run
  import Bitwise

  @default_endpoint "https://api.smith.langchain.com"
  @default_error_body_limit 8_192
  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

  @impl true
  def export(event, %Run{} = run, opts) do
    endpoint = Config.option(opts, :endpoint, [:langsmith, :endpoint], @default_endpoint)
    api_key = Config.option(opts, :api_key, [:langsmith, :api_key])
    project = Config.option(opts, :project, [:langsmith, :project], "default")
    transport = Keyword.get(opts, :transport, Req)

    if is_nil(api_key) or api_key == "" do
      :ok
    else
      url = endpoint |> String.trim_trailing("/") |> Kernel.<>("/runs")
      headers = [{"x-api-key", api_key}, {"content-type", "application/json"}]
      payload = to_payload(event, run, project)
      operation = langsmith_operation_override(opts) || default_langsmith_export_operation(event)

      case send_run_payload(transport, operation, url, payload, headers) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: 409}} ->
          :ok

        {:ok, %{status: 404}} when operation == :patch ->
          create_missing_run(transport, url, payload, headers, opts)

        {:ok, response} ->
          {:error, langsmith_response_error(response, opts)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    exception -> {:error, exception}
  end

  @spec export_batch([{atom(), Run.t(), keyword()}], keyword()) :: :ok | {:error, term()}
  def export_batch([], _opts), do: :ok

  def export_batch([{event, run, item_opts}], opts),
    do: export(event, run, Keyword.merge(opts, item_opts))

  def export_batch(items, opts) when is_list(items) do
    endpoint = Config.option(opts, :endpoint, [:langsmith, :endpoint], @default_endpoint)
    api_key = Config.option(opts, :api_key, [:langsmith, :api_key])
    project = Config.option(opts, :project, [:langsmith, :project], "default")
    transport = Keyword.get(opts, :transport, Req)

    if is_nil(api_key) or api_key == "" do
      :ok
    else
      url = endpoint |> String.trim_trailing("/") |> Kernel.<>("/runs/batch")
      headers = [{"x-api-key", api_key}, {"content-type", "application/json"}]

      payload = to_batch_payload(items, project)

      case transport.post(url, json: payload, headers: headers) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: 409}} ->
          :ok

        {:ok, %{status: 404}} ->
          export_individually(items, opts)

        {:ok, response} ->
          {:error, langsmith_response_error(response, opts)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    exception -> {:error, exception}
  end

  @doc false
  def to_payload(event, %Run{} = run, project) do
    id = langsmith_id(run.id)
    trace_id = langsmith_id(run.trace_id || run.id)

    %{
      id: id,
      trace_id: trace_id,
      parent_run_id: langsmith_id(run.parent_id),
      dotted_order: dotted_order(run, id),
      name: run.name,
      run_type: langsmith_run_type(run.kind),
      start_time: DateTime.to_iso8601(run.started_at),
      end_time: maybe_iso8601(run.ended_at),
      status: langsmith_status(event, run.status),
      error: langsmith_error(run.error),
      events: langsmith_events(event, run) |> ValueEncoder.encode(),
      extra: langsmith_extra(run),
      tags: (run.tags || []) |> ValueEncoder.encode(),
      session_name: project
    }
    |> maybe_put_raw_encoded(:serialized, langsmith_serialized(run))
    |> maybe_put_encoded(:inputs, langsmith_inputs(run))
    |> maybe_put_encoded(:outputs, langsmith_outputs(run))
  end

  @doc false
  def to_batch_payload(items, project) when is_list(items) do
    items
    |> Enum.reduce({[], MapSet.new()}, fn {event, %Run{} = run, item_opts}, {ops, seen_ids} ->
      seen? = MapSet.member?(seen_ids, run.id)
      operation = langsmith_batch_operation(event, item_opts, seen?)
      payload = to_payload(event, run, project)

      {[{operation, payload} | ops], MapSet.put(seen_ids, run.id)}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> coalesce_batch_operations()
    |> Enum.reduce(%{}, fn
      {_operation, []}, acc ->
        acc

      {operation, payloads}, acc ->
        Map.put(acc, operation, payloads)
    end)
  end

  defp coalesce_batch_operations(operations) do
    {post_order, posts, patches} =
      Enum.reduce(operations, {[], %{}, []}, fn
        {:post, payload}, {post_order, posts, patches} ->
          id = payload.id

          post_order =
            if Map.has_key?(posts, id), do: post_order, else: [id | post_order]

          {post_order, Map.update(posts, id, payload, &merge_payload(&1, payload)), patches}

        {:patch, payload}, {post_order, posts, patches} ->
          id = payload.id

          if Map.has_key?(posts, id) do
            {post_order, Map.update!(posts, id, &merge_payload(&1, payload)), patches}
          else
            {post_order, posts, [payload | patches]}
          end
      end)

    %{
      post: post_order |> Enum.reverse() |> Enum.map(&Map.fetch!(posts, &1)),
      patch: Enum.reverse(patches)
    }
  end

  defp merge_payload(base, update) do
    Map.merge(base, reject_nil_values(update))
  end

  defp langsmith_batch_operation(event, item_opts, seen?) do
    case langsmith_operation_override(item_opts) do
      operation when operation in [:post, :patch] -> operation
      nil -> default_langsmith_batch_operation(event, seen?)
    end
  end

  defp langsmith_operation_override(item_opts) do
    case Keyword.get(item_opts, :langsmith_operation) do
      operation when operation in [:post, :patch] -> operation
      "post" -> :post
      "patch" -> :patch
      _other -> nil
    end
  end

  defp default_langsmith_batch_operation(:started, _seen?), do: :post
  defp default_langsmith_batch_operation(_event, _seen?), do: :patch

  defp default_langsmith_export_operation(:started), do: :post
  defp default_langsmith_export_operation(_event), do: :patch

  defp send_run_payload(transport, :post, url, payload, headers) do
    transport.post(url, json: payload, headers: headers)
  end

  defp send_run_payload(transport, :patch, url, payload, headers) do
    transport.patch("#{url}/#{payload.id}", json: payload, headers: headers)
  end

  defp create_missing_run(transport, url, payload, headers, opts) do
    case transport.post(url, json: payload, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 409}} -> :ok
      {:ok, response} -> {:error, langsmith_response_error(response, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp langsmith_run_type(:model), do: "llm"
  defp langsmith_run_type(:tool), do: "tool"
  defp langsmith_run_type(:graph), do: "chain"
  defp langsmith_run_type(:agent), do: "chain"
  defp langsmith_run_type(_kind), do: "chain"

  defp dotted_order(%Run{} = run, id) do
    dotted_order(run, id, [])
  end

  defp dotted_order(%Run{} = run, id, visited) do
    visited = [run.id | visited]

    parent =
      metadata_value(run.metadata, :parent_dotted_order) ||
        metadata_value(run.metadata, :langsmith_parent_dotted_order) ||
        parent_dotted_order(run, visited)

    [parent, dotted_order_segment(run.started_at, id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(".")
  end

  defp parent_dotted_order(%Run{parent_id: nil}, _visited), do: nil

  defp parent_dotted_order(%Run{parent_id: parent_id} = run, visited) do
    if parent_id in visited do
      inferred_parent_dotted_order(run)
    else
      case BeamWeaver.Tracing.get_run(parent_id) do
        {:ok, %Run{} = parent} ->
          dotted_order(parent, langsmith_id(parent.id), visited)

        :error ->
          inferred_parent_dotted_order(run)
      end
    end
  end

  defp inferred_parent_dotted_order(%Run{parent_id: nil}), do: nil

  defp inferred_parent_dotted_order(%Run{parent_id: parent_id, started_at: started_at}) do
    dotted_order_segment(started_at, langsmith_id(parent_id))
  end

  defp dotted_order_segment(%DateTime{} = started_at, id) do
    started_at
    |> dotted_order_timestamp()
    |> Kernel.<>(id)
  end

  defp dotted_order_timestamp(%DateTime{} = datetime) do
    unix_microsecond = DateTime.to_unix(datetime, :microsecond)
    unix_second = div(unix_microsecond, 1_000_000)
    microsecond = rem(unix_microsecond, 1_000_000)
    {:ok, utc} = DateTime.from_unix(unix_second, :second)

    Calendar.strftime(utc, "%Y%m%dT%H%M%S") <>
      String.pad_leading(Integer.to_string(microsecond), 6, "0") <> "Z"
  end

  defp langsmith_status(:started, _status), do: "pending"
  defp langsmith_status(:ok, _status), do: "success"
  defp langsmith_status(:error, _status), do: "error"
  defp langsmith_status(_event, :running), do: "pending"
  defp langsmith_status(_event, :ok), do: "success"
  defp langsmith_status(_event, :error), do: "error"

  defp langsmith_events(event, %Run{} = run) do
    start_event = %{name: "start", time: DateTime.to_iso8601(run.started_at)}

    terminal_event =
      cond do
        is_nil(run.ended_at) ->
          nil

        event == :error or run.status == :error ->
          %{name: "error", time: DateTime.to_iso8601(run.ended_at)}

        true ->
          %{name: "end", time: DateTime.to_iso8601(run.ended_at)}
      end

    [start_event, terminal_event]
    |> Enum.reject(&is_nil/1)
  end

  defp langsmith_extra(%Run{} = run) do
    %{
      metadata: run |> langsmith_metadata() |> ValueEncoder.encode(),
      usage: (run.usage || %{}) |> ValueEncoder.encode(),
      beam_weaver_kind: ValueEncoder.encode(run.kind),
      invocation_params: run.metadata |> metadata_value(:invocation_params) |> ValueEncoder.encode(),
      model_provider:
        run.metadata
        |> metadata_first_value([:model_provider, :provider])
        |> ValueEncoder.encode(),
      model_name:
        run.metadata
        |> metadata_first_value([:model_name, :model])
        |> ValueEncoder.encode(),
      retriever: run.metadata |> metadata_value(:retriever) |> ValueEncoder.encode(),
      vectorstore:
        run.metadata
        |> metadata_first_value([:vectorstore, :vector_store])
        |> ValueEncoder.encode(),
      tool_call_id: run |> langsmith_tool_call_id() |> ValueEncoder.encode()
    }
    |> reject_nil_values()
  end

  defp langsmith_serialized(%Run{kind: :tool} = run) do
    %{
      name: metadata_value(run.metadata, :tool_name) || run.name,
      description: metadata_value(run.metadata, :description)
    }
    |> reject_nil_values()
  end

  defp langsmith_serialized(_run), do: nil

  defp langsmith_inputs(%Run{kind: :model, inputs: inputs}) when is_map(inputs) do
    case message_entry(inputs) do
      {:ok, key, messages} -> Map.put(inputs, key, langchain_message_batches(messages))
      :error -> inputs
    end
  end

  defp langsmith_inputs(%Run{inputs: inputs}), do: inputs

  defp langsmith_outputs(%Run{kind: :model, outputs: outputs}) when is_map(outputs) do
    with {:ok, _key, messages} <- message_entry(outputs),
         false <- has_generation_output?(outputs) do
      Map.put(outputs, :generations, langsmith_generations(messages))
    else
      _other -> outputs
    end
  end

  defp langsmith_outputs(%Run{kind: :tool, outputs: outputs} = run) when is_map(outputs) do
    case output_entry(outputs) do
      {:ok, key, output} -> Map.put(outputs, key, langsmith_tool_output(run, output))
      :error -> outputs
    end
  end

  defp langsmith_outputs(%Run{outputs: outputs}), do: outputs

  defp message_entry(payload) do
    cond do
      Map.has_key?(payload, :messages) -> {:ok, :messages, Map.fetch!(payload, :messages)}
      Map.has_key?(payload, "messages") -> {:ok, "messages", Map.fetch!(payload, "messages")}
      true -> :error
    end
  end

  defp has_generation_output?(outputs) do
    Map.has_key?(outputs, :generations) or Map.has_key?(outputs, "generations")
  end

  defp langchain_message_batches(messages) do
    messages
    |> normalize_message_batches()
    |> Enum.map(fn batch -> Enum.map(batch, &langchain_message_or_value/1) end)
  end

  defp langsmith_generations(messages) do
    messages
    |> langchain_message_batches()
    |> Enum.map(fn batch -> Enum.map(batch, &%{message: &1}) end)
  end

  defp normalize_message_batches(messages) when is_list(messages) do
    if Enum.all?(messages, &is_list/1) do
      messages
    else
      [messages]
    end
  end

  defp normalize_message_batches(message), do: [[message]]

  defp langchain_message_or_value(%Message{} = message), do: langchain_message(message)
  defp langchain_message_or_value(%{"lc" => _lc} = message), do: message
  defp langchain_message_or_value(%{lc: _lc} = message), do: message
  defp langchain_message_or_value(message), do: message

  defp langchain_message(%Message{} = message) do
    %{
      "lc" => 1,
      "type" => "constructor",
      "id" => ["langchain", "schema", "messages", langchain_message_class(message.role)],
      "kwargs" => langchain_message_kwargs(message)
    }
  end

  defp langchain_message_class(:assistant), do: "AIMessage"
  defp langchain_message_class(:system), do: "SystemMessage"
  defp langchain_message_class(:tool), do: "ToolMessage"
  defp langchain_message_class(:user), do: "HumanMessage"
  defp langchain_message_class(_role), do: "ChatMessage"

  defp langchain_message_type(:assistant), do: "ai"
  defp langchain_message_type(:system), do: "system"
  defp langchain_message_type(:tool), do: "tool"
  defp langchain_message_type(:user), do: "human"
  defp langchain_message_type(role), do: role

  defp langchain_message_kwargs(%Message{} = message) do
    %{
      "content" => langchain_value(message.content),
      "type" => langchain_message_type(message.role),
      "id" => message.id,
      "name" => message.name,
      "response_metadata" => langchain_value(message.response_metadata),
      "usage_metadata" => langchain_value(message.usage_metadata),
      "tool_calls" => langchain_value(message.tool_calls),
      "tool_call_id" => message.tool_call_id,
      "artifact" => langchain_value(tool_message_artifact(message)),
      "status" => langchain_value(message.status),
      "additional_kwargs" => langchain_additional_kwargs(message)
    }
    |> reject_nil_or_empty_values()
  end

  defp langchain_additional_kwargs(%Message{} = message) do
    %{
      server_tool_calls: message.server_tool_calls,
      server_tool_results: message.server_tool_results,
      metadata: message.metadata
    }
    |> reject_nil_or_empty_values()
    |> langchain_value()
  end

  defp langchain_value(nil), do: nil
  defp langchain_value(value), do: value |> ValueEncoder.encode() |> string_key_maps()

  defp string_key_maps(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {langchain_key(key), string_key_maps(nested)} end)
  end

  defp string_key_maps(value) when is_list(value), do: Enum.map(value, &string_key_maps/1)
  defp string_key_maps(value), do: value

  defp langchain_key(key) when is_binary(key), do: key
  defp langchain_key(key) when is_atom(key), do: Atom.to_string(key)
  defp langchain_key(key), do: to_string(key)

  defp output_entry(outputs) do
    cond do
      Map.has_key?(outputs, :output) -> {:ok, :output, Map.fetch!(outputs, :output)}
      Map.has_key?(outputs, "output") -> {:ok, "output", Map.fetch!(outputs, "output")}
      true -> :error
    end
  end

  defp langsmith_tool_output(%Run{} = run, %Message{role: :tool} = message) do
    %{
      content: message.content,
      type: "tool",
      name: message.name || metadata_value(run.metadata, :tool_name) || run.name,
      id: message.id,
      tool_call_id: message.tool_call_id || langsmith_tool_call_id(run),
      artifact: tool_message_artifact(message),
      status: tool_message_status(message),
      additional_kwargs: %{},
      response_metadata: message.response_metadata || %{}
    }
    |> reject_nil_values()
  end

  defp langsmith_tool_output(%Run{} = run, output) do
    %{
      content: tool_output_content(output),
      type: "tool",
      name: metadata_value(run.metadata, :tool_name) || run.name,
      tool_call_id: langsmith_tool_call_id(run),
      status: "success",
      additional_kwargs: %{},
      response_metadata: %{}
    }
    |> reject_nil_values()
  end

  defp tool_message_status(%Message{} = message) do
    message.status ||
      metadata_value(message.metadata, :status) ||
      "success"
  end

  defp tool_message_artifact(%Message{artifacts: []}), do: nil
  defp tool_message_artifact(%Message{artifacts: [artifact]}), do: artifact
  defp tool_message_artifact(%Message{artifacts: artifacts}), do: artifacts

  defp tool_output_content(output) when is_binary(output), do: output

  defp tool_output_content(output) when is_list(output) do
    if Enum.all?(output, &(is_binary(&1) or is_map(&1))) do
      output
    else
      json_string(output)
    end
  end

  defp tool_output_content(output), do: json_string(output)

  defp json_string(output) do
    case output |> ValueEncoder.encode() |> BeamWeaver.JSON.encode() do
      {:ok, json} -> json
      {:error, _reason} -> inspect(output, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp langsmith_tool_call_id(%Run{kind: :tool, metadata: metadata}),
    do: metadata_value(metadata, :tool_call_id)

  defp langsmith_tool_call_id(_run), do: nil

  defp maybe_iso8601(nil), do: nil
  defp maybe_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp maybe_put_raw_encoded(payload, _key, nil), do: payload

  defp maybe_put_raw_encoded(payload, key, value) do
    Map.put(payload, key, ValueEncoder.encode(value))
  end

  defp maybe_put_encoded(payload, _key, nil), do: payload

  defp maybe_put_encoded(payload, key, value) do
    Map.put(payload, key, value |> wrap_value() |> ValueEncoder.encode())
  end

  defp wrap_value(nil), do: %{}
  defp wrap_value(value) when is_map(value), do: value
  defp wrap_value(value), do: %{value: value}

  defp langsmith_error(nil), do: nil
  defp langsmith_error(error) when is_binary(error), do: error

  defp langsmith_error(error) do
    error = ValueEncoder.encode(error)

    case BeamWeaver.JSON.encode(error) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(error, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp metadata_value(nil, _key), do: nil

  defp metadata_value(metadata, key) when is_map(metadata) do
    cond do
      Map.has_key?(metadata, key) ->
        Map.fetch!(metadata, key)

      is_atom(key) and Map.has_key?(metadata, Atom.to_string(key)) ->
        Map.fetch!(metadata, Atom.to_string(key))

      true ->
        nil
    end
  end

  defp metadata_first_value(metadata, keys) do
    Enum.find_value(keys, &metadata_value(metadata, &1))
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp langsmith_metadata(%Run{} = run) do
    %{
      beam_weaver_run_id: run.id,
      beam_weaver_trace_id: run.trace_id
    }
    |> Map.merge(run.metadata || %{})
    |> maybe_put_new(:ls_integration, langsmith_integration(run))
    |> maybe_put_new(:ls_message_format, langsmith_message_format(run))
    |> maybe_put(:usage_metadata, usage_metadata(run))
  end

  defp langsmith_integration(%Run{kind: :model}), do: "langchain_chat_model"
  defp langsmith_integration(%Run{kind: kind}) when kind in [:graph, :agent], do: "langgraph"
  defp langsmith_integration(_run), do: nil

  defp langsmith_message_format(%Run{kind: :model}), do: "langchain"
  defp langsmith_message_format(_run), do: nil

  defp usage_metadata(%Run{usage: usage}) when is_map(usage) and map_size(usage) > 0, do: usage
  defp usage_metadata(_run), do: nil

  defp langsmith_id(nil), do: nil

  defp langsmith_id(id) do
    id = to_string(id)

    if Regex.match?(@uuid_regex, id) do
      String.downcase(id)
    else
      deterministic_uuid(id)
    end
  end

  defp deterministic_uuid(id) do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> =
      :crypto.hash(:sha256, "beam_weaver:langsmith:" <> id)

    c = (c &&& 0x0FFF) ||| 0x5000
    d = (d &&& 0x3FFF) ||| 0x8000

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      c,
      d,
      e
    ])
    |> IO.iodata_to_binary()
    |> String.downcase()
  end

  defp langsmith_response_error(%{status: status} = response, opts) do
    details =
      %{}
      |> maybe_put(:response_body, response_body(response, opts))

    if map_size(details) == 0 do
      {:langsmith_status, status}
    else
      {:langsmith_status, status, details}
    end
  end

  defp response_body(response, opts) do
    response
    |> Map.get(:body)
    |> normalize_response_body(Keyword.get(opts, :error_body_limit, @default_error_body_limit))
  end

  defp normalize_response_body(nil, _limit), do: nil

  defp normalize_response_body(body, limit) when is_binary(body) do
    truncate_body(body, limit)
  end

  defp normalize_response_body(%{} = body, _limit), do: ValueEncoder.encode(body)
  defp normalize_response_body(body, _limit) when is_list(body), do: ValueEncoder.encode(body)

  defp normalize_response_body(body, limit) do
    body
    |> inspect(limit: :infinity, printable_limit: limit)
    |> truncate_body(limit)
  end

  defp truncate_body(body, limit) when is_integer(limit) and limit > 0 do
    if byte_size(body) > limit do
      binary_part(body, 0, limit) <> "...[truncated]"
    else
      body
    end
  end

  defp truncate_body(body, _limit), do: body

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_new(map, _key, nil), do: map
  defp maybe_put_new(map, key, value), do: Map.put_new(map, key, value)

  defp reject_nil_or_empty_values(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, empty} when empty == %{} or empty == [] -> true
      _entry -> false
    end)
  end

  defp export_individually(items, opts) do
    Enum.reduce_while(items, :ok, fn {event, run, item_opts}, :ok ->
      case export(event, run, Keyword.merge(opts, item_opts)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
