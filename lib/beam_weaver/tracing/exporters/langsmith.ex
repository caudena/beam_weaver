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
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Tracing.Exporters.LangSmith.ValueEncoder
  alias BeamWeaver.Tracing.Run
  import Bitwise

  @default_endpoint "https://api.smith.langchain.com"
  @default_error_body_limit 8_192
  @multipart_fields [:inputs, :outputs, :events, :extra, :serialized]
  @multipart_default_fields [:outputs, :events, :extra]
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
      headers = [{"x-api-key", api_key}, {"content-type", "application/json"}, user_agent_header()]
      payload = to_payload(event, run, project)
      operation = langsmith_operation_override(opts) || default_langsmith_export_operation(event)

      case send_run_payload(transport, operation, url, payload, headers, project) do
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

  def export_batch(items, opts) when is_list(items) do
    endpoint = Config.option(opts, :endpoint, [:langsmith, :endpoint], @default_endpoint)
    api_key = Config.option(opts, :api_key, [:langsmith, :api_key])
    project = Config.option(opts, :project, [:langsmith, :project], "default")
    transport = Keyword.get(opts, :transport, Req)

    if is_nil(api_key) or api_key == "" do
      :ok
    else
      url = endpoint |> String.trim_trailing("/") |> Kernel.<>("/runs/multipart")
      headers = [{"x-api-key", api_key}, user_agent_header()]
      operations = to_batch_operations(items, project)
      {body, multipart_headers} = to_multipart_body(operations)

      case transport.post(
             url,
             body: body,
             headers: multipart_headers ++ headers,
             finch_private: langsmith_finch_private(:multipart, url, project, operations)
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: 409}} ->
          :ok

        {:ok, %{status: 404}} ->
          export_batch_json(items, opts)

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
      name: langsmith_run_name(run),
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
    |> to_batch_operations(project)
    |> coalesce_batch_operations()
    |> Enum.reduce(%{}, fn
      {_operation, []}, acc ->
        acc

      {operation, payloads}, acc ->
        Map.put(acc, operation, payloads)
    end)
  end

  @doc false
  def to_batch_operations(items, project) when is_list(items) do
    items
    |> Enum.reduce({[], MapSet.new()}, fn {event, %Run{} = run, item_opts}, {ops, seen_ids} ->
      seen? = MapSet.member?(seen_ids, run.id)
      operation = langsmith_batch_operation(event, item_opts, seen?)
      payload = to_payload(event, run, project)

      {[{operation, payload} | ops], MapSet.put(seen_ids, run.id)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc false
  def to_multipart_body(operations) when is_list(operations) do
    boundary = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    body =
      operations
      |> Enum.flat_map(fn {operation, payload} -> multipart_run_parts(operation, payload) end)
      |> Enum.map_join("", fn {name, value} -> multipart_json_part(boundary, name, value) end)
      |> Kernel.<>("--#{boundary}--\r\n")

    {body, [{"content-type", "multipart/form-data; boundary=#{boundary}"}, {"accept", "application/json"}]}
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

  defp send_run_payload(transport, :post, url, payload, headers, project) do
    transport.post(
      url,
      json: payload,
      headers: headers,
      finch_private: langsmith_finch_private(:post, url, project, [{:post, payload}])
    )
  end

  defp send_run_payload(transport, :patch, url, payload, headers, project) do
    patch_url = "#{url}/#{payload.id}"

    transport.patch(
      patch_url,
      json: payload,
      headers: headers,
      finch_private: langsmith_finch_private(:patch, patch_url, project, [{:patch, payload}])
    )
  end

  defp create_missing_run(transport, url, payload, headers, opts) do
    project = Config.option(opts, :project, [:langsmith, :project], "default")

    case transport.post(
           url,
           json: payload,
           headers: headers,
           finch_private: langsmith_finch_private(:post, url, project, [{:post, payload}])
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 409}} -> :ok
      {:ok, response} -> {:error, langsmith_response_error(response, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp export_batch_json(items, opts) do
    endpoint = Config.option(opts, :endpoint, [:langsmith, :endpoint], @default_endpoint)
    api_key = Config.option(opts, :api_key, [:langsmith, :api_key])
    project = Config.option(opts, :project, [:langsmith, :project], "default")
    transport = Keyword.get(opts, :transport, Req)

    url = endpoint |> String.trim_trailing("/") |> Kernel.<>("/runs/batch")
    headers = [{"x-api-key", api_key}, {"content-type", "application/json"}, user_agent_header()]
    payload = to_batch_payload(items, project)
    operations = to_batch_operations(items, project)

    case transport.post(
           url,
           json: payload,
           headers: headers,
           finch_private: langsmith_finch_private(:batch, url, project, operations)
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 409}} -> :ok
      {:ok, %{status: 404}} -> export_individually(items, opts)
      {:ok, response} -> {:error, langsmith_response_error(response, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp langsmith_run_type(:model), do: "llm"
  defp langsmith_run_type(:tool), do: "tool"
  defp langsmith_run_type(:graph), do: "chain"
  defp langsmith_run_type(:agent), do: "chain"
  defp langsmith_run_type(_kind), do: "chain"

  defp langsmith_run_name(%Run{kind: :tool} = run), do: langsmith_tool_run_name(run)
  defp langsmith_run_name(%Run{name: name}), do: name

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
      invocation_params: run |> langsmith_invocation_params() |> empty_map_to_nil() |> ValueEncoder.encode(),
      model_provider:
        run.metadata
        |> metadata_first_value([:model_provider, :provider])
        |> normalize_model_provider()
        |> ValueEncoder.encode(),
      model_name:
        run.metadata
        |> metadata_first_value([:model_name, :model])
        |> normalize_model_name()
        |> ValueEncoder.encode(),
      retriever: run.metadata |> metadata_value(:retriever) |> ValueEncoder.encode(),
      vectorstore:
        run.metadata
        |> metadata_first_value([:vectorstore, :vector_store])
        |> ValueEncoder.encode(),
      tool_call_id: run |> langsmith_tool_call_id() |> ValueEncoder.encode(),
      runtime: langsmith_runtime()
    }
    |> reject_nil_values()
  end

  defp langsmith_invocation_params(%Run{} = run) do
    params =
      run.metadata
      |> metadata_value(:invocation_params)
      |> normalize_invocation_params()

    provider =
      run.metadata
      |> metadata_first_value([:model_provider, :provider, :ls_provider])
      |> normalize_model_provider()

    tool_schemas =
      run.metadata
      |> metadata_value(:tool_definitions)
      |> langsmith_invocation_tools()

    params
    |> drop_metadata_keys([:structured_output, "structured_output"])
    |> maybe_put(:_type, langsmith_invocation_type(provider))
    |> maybe_put(
      :model,
      metadata_first_value(params, [:model, :model_name]) ||
        metadata_first_value(run.metadata, [:model, :model_name])
    )
    |> maybe_put(
      :model_name,
      metadata_first_value(params, [:model_name, :model]) ||
        metadata_first_value(run.metadata, [:model_name, :model])
    )
    |> maybe_put(:tools, tool_schemas || metadata_value(params, :tools))
    |> maybe_put(
      :response_format,
      metadata_value(params, :response_format) || metadata_value(params, :structured_output)
    )
    |> reject_nil_or_empty_values()
  end

  defp normalize_invocation_params(params) when is_map(params), do: params
  defp normalize_invocation_params(_params), do: %{}

  defp langsmith_invocation_type(provider) when provider in ["openai", "xai", "moonshot", "kimi"], do: "openai-chat"
  defp langsmith_invocation_type("anthropic"), do: "anthropic-chat"
  defp langsmith_invocation_type("google"), do: "google-genai-chat"
  defp langsmith_invocation_type(_provider), do: nil

  defp langsmith_invocation_tools(nil), do: nil
  defp langsmith_invocation_tools([]), do: nil

  defp langsmith_invocation_tools(tool_definitions) do
    tool_definitions
    |> List.wrap()
    |> Enum.map(&langsmith_invocation_tool/1)
    |> reject_nil_or_empty_list()
  end

  defp langsmith_invocation_tool(%{"type" => "function", "function" => function} = tool)
       when is_map(function),
       do: tool

  defp langsmith_invocation_tool(%{type: "function", function: function} = tool)
       when is_map(function),
       do: string_key_maps(tool)

  defp langsmith_invocation_tool(%{} = definition) do
    name = metadata_value(definition, :name)

    if is_nil(name) do
      nil
    else
      function =
        %{
          "name" => to_string(name),
          "description" => metadata_value(definition, :description),
          "parameters" => metadata_value(definition, :input_schema) || metadata_value(definition, :parameters) || %{}
        }
        |> maybe_put("strict", metadata_value(definition, :strict))
        |> reject_nil_values()
        |> string_key_maps()

      %{"type" => "function", "function" => function}
    end
  end

  defp langsmith_invocation_tool(_definition), do: nil

  defp reject_nil_or_empty_list(values) do
    values = Enum.reject(values, &nil_or_empty?/1)
    if values == [], do: nil, else: values
  end

  defp langsmith_serialized(%Run{kind: :model} = run) do
    provider =
      run.metadata
      |> metadata_first_value([:model_provider, :provider, :ls_provider])
      |> normalize_model_provider()
      |> normalize_provider_namespace()

    %{
      "lc" => 1,
      "type" => "constructor",
      "id" => ["langchain", "chat_models", provider, run.name],
      "kwargs" => langsmith_model_kwargs(run),
      "name" => run.name
    }
  end

  defp langsmith_serialized(%Run{kind: :tool} = run) do
    %{
      name: langsmith_tool_run_name(run),
      description: langsmith_tool_run_description(run)
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

  defp langsmith_inputs(%Run{kind: kind, inputs: inputs}) when is_map(inputs) and kind in [:graph, :agent] do
    inputs = strip_runtime_state(inputs)

    case message_entry(inputs) do
      {:ok, key, messages} -> Map.put(inputs, key, langsmith_messages(messages))
      :error -> inputs
    end
  end

  defp langsmith_inputs(%Run{inputs: inputs}) when is_map(inputs) do
    case message_entry(inputs) do
      {:ok, key, messages} -> Map.put(inputs, key, langsmith_messages(messages))
      :error -> inputs
    end
  end

  defp langsmith_inputs(%Run{inputs: inputs}), do: inputs

  defp langsmith_outputs(%Run{kind: :model, outputs: outputs} = run) when is_map(outputs) do
    case message_entry(outputs) do
      {:ok, _key, messages} ->
        messages = strip_structured_output_tool_calls(run, messages)

        %{
          generations: langsmith_generations(run, messages),
          llm_output: langsmith_llm_output(run, messages),
          run: nil,
          type: "LLMResult"
        }
        |> reject_nil_values()

      :error ->
        outputs
    end
  end

  defp langsmith_outputs(%Run{kind: :tool, outputs: outputs} = run) when is_map(outputs) do
    case output_entry(outputs) do
      {:ok, key, output} -> Map.put(outputs, key, langsmith_tool_output(run, output))
      :error -> outputs
    end
  end

  defp langsmith_outputs(%Run{kind: kind, outputs: outputs}) when is_map(outputs) and kind in [:graph, :agent] do
    outputs = strip_runtime_state(outputs)

    case message_entry(outputs) do
      {:ok, key, messages} -> Map.put(outputs, key, langsmith_messages(messages))
      :error -> outputs
    end
  end

  defp langsmith_outputs(%Run{outputs: outputs}) when is_map(outputs) do
    case message_entry(outputs) do
      {:ok, key, messages} -> Map.put(outputs, key, langsmith_messages(messages))
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

  defp langchain_message_batches(messages) do
    messages
    |> normalize_message_batches()
    |> Enum.map(fn batch -> Enum.map(batch, &langchain_message_or_value/1) end)
  end

  defp langsmith_generations(%Run{} = run, messages) do
    messages
    |> langchain_message_batches()
    |> Enum.map(fn batch ->
      batch
      |> Enum.with_index()
      |> Enum.map(fn {message, index} -> langsmith_generation(run, message, index) end)
    end)
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
    message = langsmith_sanitized_message(message)

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
      "content" => langchain_value(langsmith_message_content(message.content)),
      "type" => langchain_message_type(message.role),
      "id" => message.id,
      "name" => message.name,
      "response_metadata" => langchain_value(langsmith_response_metadata(message.response_metadata)),
      "usage_metadata" => langchain_value(message.usage_metadata),
      "tool_calls" => langchain_tool_calls(message.tool_calls),
      "tool_call_id" => message.tool_call_id,
      "artifact" => langchain_value(tool_message_artifact(message)),
      "status" => langchain_value(message.status),
      "additional_kwargs" => langchain_additional_kwargs(message),
      "invalid_tool_calls" => invalid_tool_calls(message)
    }
    |> reject_langchain_message_empty(message.role)
  end

  defp langchain_additional_kwargs(%Message{} = message) do
    %{
      server_tool_calls: message.server_tool_calls,
      server_tool_results: message.server_tool_results
    }
    |> reject_nil_or_empty_values()
    |> Map.merge(assistant_provider_additional_kwargs(message))
    |> langchain_value()
  end

  defp assistant_provider_additional_kwargs(%Message{role: :assistant, metadata: metadata})
       when is_map(metadata) do
    %{
      parsed: metadata_value(metadata, :parsed),
      refusal: metadata_value(metadata, :refusal)
    }
  end

  defp assistant_provider_additional_kwargs(_message), do: %{}

  defp invalid_tool_calls(%Message{role: :assistant}), do: []
  defp invalid_tool_calls(_message), do: nil

  defp reject_langchain_message_empty(map, role) do
    Map.reject(map, fn
      {_key, nil} -> true
      {key, empty} when empty == %{} or empty == [] -> not keep_empty_langchain_field?(role, key)
      _entry -> false
    end)
  end

  defp keep_empty_langchain_field?(:assistant, key),
    do: key in ["additional_kwargs", "invalid_tool_calls"]

  defp keep_empty_langchain_field?(_role, _key), do: false

  defp langchain_tool_calls([]), do: nil
  defp langchain_tool_calls(nil), do: nil

  defp langchain_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&langchain_tool_call/1)
    |> langchain_value()
  end

  defp langchain_tool_call(call) when is_map(call) do
    %{
      "name" => langsmith_tool_call_name(call),
      "args" => langsmith_tool_call_args(call),
      "id" => metadata_first_value(call, [:call_id, :tool_call_id, :id, :provider_id]),
      "type" => metadata_value(call, :type) || "tool_call"
    }
    |> reject_nil_values()
  end

  defp strip_structured_output_tool_calls(%Run{} = run, messages) do
    case structured_output_tool_names(run) do
      [] -> messages
      names -> strip_structured_output_tool_calls(messages, MapSet.new(names))
    end
  end

  defp strip_structured_output_tool_calls(messages, names) when is_list(messages) do
    Enum.map(messages, &strip_structured_output_tool_calls(&1, names))
  end

  defp strip_structured_output_tool_calls(%Message{role: :assistant} = message, names) do
    tool_calls =
      message.tool_calls
      |> List.wrap()
      |> Enum.reject(&structured_output_tool_name?(&1, names))

    content = strip_structured_output_content(message.content, names)

    %{message | content: content, tool_calls: tool_calls}
  end

  defp strip_structured_output_tool_calls(message, _names), do: message

  defp strip_structured_output_content(content, names) when is_list(content) do
    Enum.reject(content, fn
      block when is_map(block) ->
        metadata_value(block, :type) in ["function_call", :function_call, "tool_call", :tool_call] and
          structured_output_tool_name?(block, names)

      _block ->
        false
    end)
  end

  defp strip_structured_output_content(content, _names), do: content

  defp langsmith_sanitized_message(%Message{} = message) do
    message
    |> strip_structured_output_tool_calls(MapSet.new(message_structured_output_tool_names(message)))
    |> strip_provider_tool_content_blocks()
  end

  defp message_structured_output_tool_names(%Message{metadata: metadata, response_metadata: response_metadata}) do
    metadata_names =
      metadata
      |> structured_output_tool_names_from_metadata()

    response_metadata_names =
      response_metadata
      |> structured_output_tool_names_from_metadata()

    Enum.uniq(metadata_names ++ response_metadata_names)
  end

  defp structured_output_tool_names_from_metadata(metadata) do
    case metadata_value(metadata, :structured_output_tool_names) do
      names when is_list(names) -> Enum.map(names, &to_string/1)
      name when is_binary(name) -> [name]
      name when is_atom(name) -> [Atom.to_string(name)]
      _other -> []
    end
  end

  defp strip_provider_tool_content_blocks(%Message{role: :assistant, content: content} = message) do
    %{message | content: reject_provider_tool_content_blocks(content)}
  end

  defp strip_provider_tool_content_blocks(message), do: message

  defp reject_provider_tool_content_blocks(content) when is_list(content) do
    Enum.reject(content, &provider_tool_content_block?/1)
  end

  defp reject_provider_tool_content_blocks(content), do: content

  defp provider_tool_content_block?(block) when is_map(block) do
    metadata_value(block, :type) in ["function_call", :function_call, "tool_call", :tool_call]
  end

  defp provider_tool_content_block?(_block), do: false

  defp structured_output_tool_names(%Run{metadata: metadata}) do
    case metadata_value(metadata, :structured_output_tool_names) do
      names when is_list(names) -> Enum.map(names, &to_string/1)
      name when is_binary(name) -> [name]
      name when is_atom(name) -> [Atom.to_string(name)]
      _other -> []
    end
  end

  defp structured_output_tool_name?(call_or_block, names) when is_map(call_or_block) do
    case metadata_value(call_or_block, :name) do
      nil -> false
      name -> MapSet.member?(names, to_string(name))
    end
  end

  defp structured_output_tool_name?(_call_or_block, _names), do: false

  defp langchain_value(nil), do: nil
  defp langchain_value(value), do: value |> ValueEncoder.encode() |> string_key_maps()

  defp langsmith_message_content(content) when is_list(content) do
    Enum.map(content, &drop_provider_trace_keys/1)
  end

  defp langsmith_message_content(content), do: content

  defp langsmith_response_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {key, _value} -> provider_response_metadata_key?(key) end)
    |> Map.new(fn {key, value} -> {key, drop_provider_trace_keys(value)} end)
  end

  defp langsmith_response_metadata(metadata), do: metadata

  defp provider_response_metadata_key?(key)
       when key in [
              :raw_provider_block,
              "raw_provider_block",
              :raw_provider_response,
              "raw_provider_response",
              :provider_metadata,
              "provider_metadata",
              :output,
              "output",
              :tooling,
              "tooling",
              :tools,
              "tools"
            ],
       do: true

  defp provider_response_metadata_key?(_key), do: false

  defp drop_provider_trace_keys(%_struct{} = value), do: value

  defp drop_provider_trace_keys(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> provider_trace_key?(key) end)
    |> Map.new(fn {key, nested} -> {key, drop_provider_trace_keys(nested)} end)
  end

  defp drop_provider_trace_keys(value) when is_list(value), do: Enum.map(value, &drop_provider_trace_keys/1)
  defp drop_provider_trace_keys(value), do: value

  defp provider_trace_key?(key)
       when key in [
              :raw_provider_block,
              "raw_provider_block",
              :raw_provider_response,
              "raw_provider_response",
              :provider_metadata,
              "provider_metadata"
            ],
       do: true

  defp provider_trace_key?(_key), do: false

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
      name: langsmith_tool_message_name(run, message),
      id: message.id,
      tool_call_id: message.tool_call_id || langsmith_tool_call_id(run),
      artifact: tool_message_artifact(message),
      status: tool_message_status(message),
      additional_kwargs: %{},
      response_metadata: langsmith_response_metadata(message.response_metadata || %{})
    }
    |> reject_nil_values()
  end

  defp langsmith_tool_output(%Run{} = run, %Command{} = command) do
    case command_tool_message(command) do
      %Message{} = message -> langsmith_tool_output(run, message)
      nil -> langsmith_tool_output(run, command_to_public_output(command))
    end
  end

  defp langsmith_tool_output(%Run{} = run, output) do
    %{
      content: tool_output_content(output),
      type: "tool",
      name: langsmith_tool_run_name(run),
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

  defp command_tool_message(%Command{update: update}) when is_map(update) do
    update
    |> metadata_value(:messages)
    |> List.wrap()
    |> Enum.find(&match?(%Message{role: :tool}, &1))
  end

  defp command_tool_message(_command), do: nil

  defp command_to_public_output(%Command{update: update}) when is_map(update) do
    update
    |> Map.take([:messages, "messages"])
  end

  defp command_to_public_output(command), do: command

  defp langsmith_generation(%Run{} = run, %{"lc" => _lc} = message, index) do
    %{
      text: langchain_generation_text(message),
      generation_info: langchain_generation_info(message),
      type: "ChatGeneration",
      message: put_generated_message_id(message, run, index)
    }
  end

  defp langsmith_generation(%Run{} = run, %{lc: _lc} = message, index) do
    message
    |> string_key_maps()
    |> then(&langsmith_generation(run, &1, index))
  end

  defp langsmith_generation(%Run{} = run, message, index) do
    langsmith_generation(run, langchain_message_or_value(message), index)
  end

  defp put_generated_message_id(%{"kwargs" => kwargs} = message, %Run{} = run, index)
       when is_map(kwargs) do
    put_in(message, ["kwargs", "id"], Map.get(kwargs, "id") || "lc_run--#{langsmith_id(run.id)}-#{index}")
  end

  defp put_generated_message_id(message, _run, _index), do: message

  defp langchain_generation_text(%{"kwargs" => %{"content" => content}}), do: message_text(content)
  defp langchain_generation_text(_message), do: ""

  defp langchain_generation_info(%{"kwargs" => %{"response_metadata" => metadata}})
       when is_map(metadata) do
    %{
      finish_reason:
        metadata["finish_reason"] || metadata[:finish_reason] || metadata["stop_reason"] ||
          metadata[:stop_reason],
      logprobs: metadata["logprobs"] || metadata[:logprobs]
    }
  end

  defp langchain_generation_info(_message), do: %{}

  defp langsmith_llm_output(%Run{} = run, messages) do
    messages
    |> normalize_message_batches()
    |> List.first([])
    |> List.first()
    |> case do
      %Message{} = message -> llm_output_model_metadata(run, message)
      _other -> llm_output_model_metadata(run, nil)
    end
  end

  defp llm_output_model_metadata(%Run{} = run, %Message{} = message) do
    metadata = message.response_metadata || %{}

    %{}
    |> maybe_put(:token_usage, token_usage(metadata_value(metadata, :token_usage), message.usage_metadata))
    |> maybe_put(
      :model_provider,
      normalize_model_provider(
        metadata_first_value(metadata, [:model_provider, :provider]) ||
          metadata_first_value(run.metadata, [:model_provider, :provider, :ls_provider])
      )
    )
    |> maybe_put(
      :model_name,
      normalize_model_name(
        metadata_first_value(metadata, [:model_name, :model]) ||
          metadata_first_value(run.metadata, [:model_name, :model, :ls_model_name])
      )
    )
    |> maybe_put(:system_fingerprint, metadata_value(metadata, :system_fingerprint))
    |> maybe_put(:id, metadata_first_value(metadata, [:id, :request_id]))
    |> reject_nil_values()
  end

  defp llm_output_model_metadata(%Run{} = run, _message) do
    %{}
    |> maybe_put(
      :model_provider,
      run.metadata
      |> metadata_first_value([:model_provider, :provider, :ls_provider])
      |> normalize_model_provider()
    )
    |> maybe_put(
      :model_name,
      run.metadata
      |> metadata_first_value([:model_name, :model, :ls_model_name])
      |> normalize_model_name()
    )
    |> reject_nil_values()
  end

  defp token_usage(provider_usage, _usage_metadata) when is_map(provider_usage) and map_size(provider_usage) > 0,
    do: provider_usage

  defp token_usage(_provider_usage, usage_metadata) when is_map(usage_metadata) do
    %{}
    |> maybe_put(:prompt_tokens, metadata_first_value(usage_metadata, [:prompt_tokens, :input_tokens]))
    |> maybe_put(:completion_tokens, metadata_first_value(usage_metadata, [:completion_tokens, :output_tokens]))
    |> maybe_put(:total_tokens, metadata_value(usage_metadata, :total_tokens))
    |> maybe_put(
      :prompt_tokens_details,
      metadata_first_value(usage_metadata, [:prompt_tokens_details, :input_token_details])
    )
    |> maybe_put(
      :completion_tokens_details,
      metadata_first_value(usage_metadata, [:completion_tokens_details, :output_token_details])
    )
    |> maybe_put(:prompt_cost, metadata_first_value(usage_metadata, [:prompt_cost, :input_cost]))
    |> maybe_put(:completion_cost, metadata_first_value(usage_metadata, [:completion_cost, :output_cost]))
    |> maybe_put(:total_cost, metadata_value(usage_metadata, :total_cost))
    |> reject_nil_values()
    |> empty_map_to_nil()
  end

  defp token_usage(_provider_usage, _usage_metadata), do: nil

  defp empty_map_to_nil(value) when value == %{}, do: nil
  defp empty_map_to_nil(value), do: value

  defp langsmith_messages(messages) do
    messages
    |> List.wrap()
    |> Enum.map(&langsmith_message_or_value/1)
  end

  defp langsmith_message_or_value(%Message{} = message), do: langsmith_message(message)
  defp langsmith_message_or_value(message), do: message

  defp langsmith_message(%Message{} = message) do
    message = langsmith_sanitized_message(message)

    %{
      content: langchain_value(langsmith_message_content(message.content)),
      additional_kwargs: langchain_additional_kwargs(message) || %{},
      response_metadata: langchain_value(langsmith_response_metadata(message.response_metadata || %{})),
      type: langchain_message_type(message.role),
      name: langsmith_message_name(message),
      id: message.id,
      tool_call_id: message.tool_call_id,
      tool_calls: langchain_tool_calls(message.tool_calls),
      invalid_tool_calls: invalid_tool_calls(message),
      usage_metadata: langchain_value(message.usage_metadata),
      artifact: langchain_value(tool_message_artifact(message)),
      status: langchain_value(message.status)
    }
    |> reject_nil_values()
  end

  defp message_text(content) when is_binary(content), do: content

  defp message_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{type: :text, text: text} when is_binary(text) -> text
      text when is_binary(text) -> text
      other -> json_string(other)
    end)
    |> Enum.join("")
  end

  defp message_text(_content), do: ""

  defp json_string(output) do
    case output |> ValueEncoder.encode() |> BeamWeaver.JSON.encode() do
      {:ok, json} -> json
      {:error, _reason} -> inspect(output, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp langsmith_tool_call_id(%Run{kind: :tool, metadata: metadata}),
    do: metadata_first_value(metadata, [:call_id, :tool_call_id, :id, :provider_id])

  defp langsmith_tool_call_id(_run), do: nil

  defp langsmith_tool_call_name(call) when is_map(call) do
    name = metadata_value(call, :name)

    if task_subagent_name(call), do: subagent_tool_name(task_subagent_name(call)), else: name
  end

  defp langsmith_tool_call_args(call) when is_map(call) do
    if task_subagent_name(call), do: %{}, else: metadata_value(call, :args) || %{}
  end

  defp langsmith_tool_run_name(%Run{} = run) do
    base = metadata_value(run.metadata, :tool_name) || run.name

    if task_tool_name?(base) and run_subagent_name(run) do
      subagent_tool_name(run_subagent_name(run))
    else
      base
    end
  end

  defp langsmith_tool_run_description(%Run{} = run) do
    if run_subagent_name(run) do
      "Run the #{run_subagent_name(run)} subagent with verification."
    else
      metadata_value(run.metadata, :description)
    end
  end

  defp langsmith_tool_message_name(%Run{} = run, %Message{} = message) do
    base = message.name || metadata_value(run.metadata, :tool_name) || run.name

    cond do
      message_subagent_name(message) -> subagent_tool_name(message_subagent_name(message))
      task_tool_name?(base) and run_subagent_name(run) -> subagent_tool_name(run_subagent_name(run))
      true -> base
    end
  end

  defp langsmith_message_name(%Message{role: :tool} = message) do
    if message_subagent_name(message), do: subagent_tool_name(message_subagent_name(message)), else: message.name
  end

  defp langsmith_message_name(%Message{} = message), do: message.name

  defp task_subagent_name(call) when is_map(call) do
    args = metadata_value(call, :args) || %{}
    name = metadata_value(call, :name)

    if task_tool_name?(name) do
      metadata_value(args, :subagent_name) || metadata_value(args, :subagent_type)
    end
  end

  defp task_tool_name?(name) when is_binary(name), do: name == "task"
  defp task_tool_name?(name) when is_atom(name), do: Atom.to_string(name) == "task"
  defp task_tool_name?(_name), do: false

  defp run_subagent_name(%Run{} = run) do
    metadata_value(run.inputs, :subagent_name) ||
      metadata_value(run.inputs, :subagent_type) ||
      metadata_value(run.metadata, :subagent_name) ||
      metadata_value(run.metadata, :subagent_type)
  end

  defp message_subagent_name(%Message{metadata: metadata}) do
    metadata_value(metadata, :subagent_name) || metadata_value(metadata, :subagent_type)
  end

  defp subagent_tool_name(name) when is_binary(name), do: "run_#{name}"
  defp subagent_tool_name(name) when is_atom(name), do: "run_#{name}"
  defp subagent_tool_name(name), do: "run_#{to_string(name)}"

  defp maybe_iso8601(nil), do: nil
  defp maybe_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp maybe_put_raw_encoded(payload, _key, nil), do: payload

  defp maybe_put_raw_encoded(payload, key, value) do
    Map.put(payload, key, ValueEncoder.encode(value))
  end

  defp maybe_put_encoded(payload, _key, nil), do: payload

  defp maybe_put_encoded(payload, key, value) do
    Map.put(payload, key, value |> sanitize_langsmith_payload() |> wrap_value() |> ValueEncoder.encode())
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

  defp drop_metadata_keys(metadata, keys) when is_map(metadata) do
    keys = keys |> Enum.map(&to_string/1) |> MapSet.new()

    Map.reject(metadata, fn {key, _value} -> MapSet.member?(keys, to_string(key)) end)
  end

  defp drop_metadata_keys(_metadata, _keys), do: %{}

  defp normalize_model_provider(nil), do: nil
  defp normalize_model_provider(provider) when is_binary(provider), do: provider
  defp normalize_model_provider(provider) when is_atom(provider), do: Atom.to_string(provider)

  defp normalize_model_provider(provider) when is_map(provider) do
    provider
    |> metadata_first_value([:model_provider, :provider, :ls_provider])
    |> normalize_model_provider()
  end

  defp normalize_model_provider(provider), do: to_string(provider)

  defp normalize_model_name(nil), do: nil
  defp normalize_model_name(name) when is_binary(name), do: name
  defp normalize_model_name(name) when is_atom(name), do: Atom.to_string(name)

  defp normalize_model_name(name) when is_map(name) do
    name
    |> metadata_first_value([:model_name, :model, :requested_model, :profile_id, :id])
    |> normalize_model_name()
  end

  defp normalize_model_name(name), do: to_string(name)

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp reject_nil_or_empty_values(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, empty} when empty == %{} or empty == [] -> true
      _entry -> false
    end)
  end

  defp nil_or_empty?(nil), do: true
  defp nil_or_empty?(%{} = map), do: map_size(map) == 0
  defp nil_or_empty?([]), do: true
  defp nil_or_empty?(_value), do: false

  defp langsmith_metadata(%Run{} = run) do
    %{
      beam_weaver_run_id: run.id,
      beam_weaver_trace_id: run.trace_id
    }
    |> Map.merge(run.metadata || %{})
    |> maybe_put_new(:ls_integration, langsmith_integration(run))
    |> maybe_put_new(:ls_message_format, langsmith_message_format(run))
    |> maybe_put(:usage_metadata, usage_metadata(run))
    |> sanitize_langsmith_metadata()
  end

  defp sanitize_langsmith_metadata(%_struct{} = value), do: value

  defp sanitize_langsmith_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {key, _value} -> provider_trace_key?(key) or internal_trace_key?(key) end)
    |> Map.new(fn
      {key, value} when key in [:response_metadata, "response_metadata"] ->
        {key, langsmith_response_metadata(value)}

      {key, value} ->
        {key, sanitize_langsmith_metadata(value)}
    end)
  end

  defp sanitize_langsmith_metadata(value) when is_list(value),
    do: Enum.map(value, &sanitize_langsmith_metadata/1)

  defp sanitize_langsmith_metadata(value), do: value

  defp sanitize_langsmith_payload(%_struct{} = value), do: value

  defp sanitize_langsmith_payload(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> provider_trace_key?(key) or internal_trace_key?(key) end)
    |> Map.new(fn
      {key, nested} when key in [:response_metadata, "response_metadata"] ->
        {key, langsmith_response_metadata(nested)}

      {key, nested} ->
        {key, sanitize_langsmith_payload(nested)}
    end)
  end

  defp sanitize_langsmith_payload(value) when is_list(value),
    do: Enum.map(value, &sanitize_langsmith_payload/1)

  defp sanitize_langsmith_payload(value), do: value

  defp strip_runtime_state(%_struct{} = value), do: value

  defp strip_runtime_state(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> runtime_state_key?(key) end)
    |> Map.new(fn {key, nested} -> {key, strip_runtime_state(nested)} end)
  end

  defp strip_runtime_state(value) when is_list(value), do: Enum.map(value, &strip_runtime_state/1)
  defp strip_runtime_state(value), do: value

  defp runtime_state_key?(key)
       when key in [
              :subagent_outputs,
              "subagent_outputs",
              :subagent_cache,
              "subagent_cache",
              :tool_set,
              "tool_set",
              :remaining_steps,
              "remaining_steps",
              :thread_tool_call_count,
              "thread_tool_call_count",
              :run_tool_call_count,
              "run_tool_call_count",
              :usage,
              "usage"
            ],
       do: true

  defp runtime_state_key?(_key), do: false

  defp internal_trace_key?(key)
       when key in [
              :__node_outputs__,
              "__node_outputs__",
              :__edge_runs__,
              "__edge_runs__",
              :tool_definitions,
              "tool_definitions"
            ],
       do: true

  defp internal_trace_key?(_key), do: false

  defp langsmith_integration(%Run{kind: :model, metadata: metadata}) do
    case metadata_first_value(metadata, [:model_provider, :provider, :ls_provider]) do
      provider when provider in [:openai, "openai", :xai, "xai"] -> "langchain_openai"
      provider when provider in [:google, "google", :gemini, "gemini"] -> "langchain_google_genai"
      provider when provider in [:anthropic, "anthropic"] -> "langchain_anthropic"
      _other -> "langchain_chat_model"
    end
  end

  defp langsmith_integration(%Run{kind: kind}) when kind in [:graph, :agent], do: "langgraph"
  defp langsmith_integration(_run), do: nil

  defp langsmith_message_format(%Run{kind: :model}), do: "langchain"
  defp langsmith_message_format(_run), do: nil

  defp usage_metadata(%Run{usage: usage}) when is_map(usage) and map_size(usage) > 0, do: usage
  defp usage_metadata(_run), do: nil

  defp langsmith_runtime do
    %{
      sdk: "beam_weaver",
      sdk_version: Application.spec(:beam_weaver, :vsn) |> to_string(),
      library: "beam_weaver",
      runtime: "elixir",
      runtime_version: System.version(),
      otp_release: System.otp_release()
    }
  end

  defp user_agent_header do
    {"user-agent", "beam-weaver/#{beam_weaver_version()} langsmith-elixir"}
  end

  defp langsmith_finch_private(operation, url, project, operations) do
    [
      beam_weaver: %{
        provider: :langsmith,
        operation: operation,
        method: langsmith_http_method(operation),
        url: redact_url(url),
        project: project,
        run_count: length(operations),
        post_count: Enum.count(operations, &match?({:post, _payload}, &1)),
        patch_count: Enum.count(operations, &match?({:patch, _payload}, &1))
      }
    ]
  end

  defp langsmith_http_method(:patch), do: :patch
  defp langsmith_http_method(_operation), do: :post

  defp redact_url(url) when is_binary(url) do
    uri = URI.parse(url)

    %URI{uri | query: nil}
    |> URI.to_string()
  end

  defp redact_url(url), do: to_string(url)

  defp beam_weaver_version do
    Application.spec(:beam_weaver, :vsn)
    |> to_string()
  end

  defp langsmith_model_kwargs(%Run{} = run) do
    params = metadata_value(run.metadata, :invocation_params) || %{}

    %{}
    |> maybe_put(
      "model_name",
      normalize_model_name(
        metadata_first_value(params, [:model_name, :model]) ||
          metadata_first_value(run.metadata, [:model_name, :model])
      )
    )
    |> maybe_put("temperature", metadata_value(params, :temperature))
    |> maybe_put("max_tokens", metadata_first_value(params, [:max_tokens, :max_completion_tokens, :max_output_tokens]))
    |> maybe_put("stream", metadata_value(params, :stream))
    |> reject_nil_values()
  end

  defp normalize_provider_namespace(nil), do: "base"
  defp normalize_provider_namespace(:xai), do: "openai"
  defp normalize_provider_namespace("xai"), do: "openai"
  defp normalize_provider_namespace(:moonshot), do: "openai"
  defp normalize_provider_namespace("moonshot"), do: "openai"
  defp normalize_provider_namespace(:kimi), do: "openai"
  defp normalize_provider_namespace("kimi"), do: "openai"
  defp normalize_provider_namespace(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp normalize_provider_namespace(provider), do: to_string(provider)

  defp multipart_run_parts(operation, payload) do
    id = Map.fetch!(payload, :id)

    base =
      payload
      |> Map.drop(@multipart_fields)
      |> reject_nil_values()
      |> Map.delete(:status)
      |> maybe_put_multipart_placeholders(operation)

    field_prefix = "#{operation}.#{id}"

    [{field_prefix, base}] ++
      Enum.flat_map(@multipart_fields, fn field ->
        case Map.fetch(payload, field) do
          {:ok, value} -> [{"#{field_prefix}.#{field}", value || %{}}]
          :error when field in @multipart_default_fields -> [{"#{field_prefix}.#{field}", %{}}]
          :error -> []
        end
      end)
  end

  defp maybe_put_multipart_placeholders(base, :post), do: Map.put_new(base, :replicas, [])
  defp maybe_put_multipart_placeholders(base, :patch), do: Map.put_new(base, :session_id, nil)
  defp maybe_put_multipart_placeholders(base, _operation), do: base

  defp multipart_json_part(boundary, name, value) do
    json = BeamWeaver.JSON.encode!(ValueEncoder.encode(value))

    "--#{boundary}\r\n" <>
      "Content-Disposition: form-data; name=\"#{name}\"\r\n" <>
      "Content-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(json)}\r\n\r\n" <>
      json <> "\r\n"
  end

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

  defp export_individually(items, opts) do
    Enum.reduce_while(items, :ok, fn {event, run, item_opts}, :ok ->
      case export(event, run, Keyword.merge(opts, item_opts)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
