defmodule BeamWeaver.Provider.Response do
  @moduledoc """
  Normalized provider response envelope: a reply's usage, limits, model,
  reasoning, tooling, safety, grounding and transport metadata.

  Applications that persist provider replies themselves call
  `normalize_execution_result/3`. It returns the normalized message, its
  `BeamWeaver.Provider.Outcome`, and a provider-native replay projection to
  store next to the message (see `BeamWeaver.Provider.Replay`).

  Chat model APIs return `BeamWeaver.Core.Message`; the normalized envelope is
  copied onto `usage_metadata` and `response_metadata` so traces and stream
  events can consume one stable shape across providers.

  Provider clients own response-header decoding. Core preserves
  `response_metadata.headers` only when the client already supplied an
  atom-keyed, allowlisted decoded header map; raw/full HTTP transport headers
  must stay in debug-only metadata and are not interpreted here.
  """

  import BeamWeaver.Provider.ChatCompletionsWire, only: [metadata_value: 2]

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.Identity
  alias BeamWeaver.MapShape
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Provider.Outcome
  alias BeamWeaver.Provider.Replay
  alias BeamWeaver.Provider.Validation

  defstruct message: nil,
            usage: %{},
            limits: %{},
            model: %{},
            reasoning: %{},
            tooling: %{},
            safety: %{},
            grounding: %{},
            transport: %{},
            headers: %{},
            provider_metadata: %{},
            outcome: nil,
            replay: nil,
            raw: nil

  @type t :: %__MODULE__{}

  @doc """
  Builds a normalized envelope from a provider message.
  """
  @spec from_message(term(), Message.t(), keyword()) :: t()
  def from_message(model, %Message{} = message, opts \\ []) do
    provider = provider(model, message, opts)
    headers = normalize_headers(message.response_metadata)
    usage = normalize_usage(message.usage_metadata, message.response_metadata)

    %__MODULE__{
      message: message,
      usage: usage,
      limits: normalize_limits(model, message.response_metadata),
      model: normalize_model(model, message, provider),
      reasoning: normalize_reasoning(model, message, usage, opts),
      tooling: normalize_tooling(message, message.response_metadata),
      safety: normalize_safety(message.response_metadata),
      grounding: normalize_grounding(message.response_metadata),
      transport: normalize_transport(message.response_metadata),
      headers: headers,
      provider_metadata: provider_metadata(provider, message.response_metadata),
      outcome: Outcome.classify(message),
      replay: replay_projection(message, provider, model, opts),
      raw: message.response_metadata
    }
  end

  @doc """
  Applies normalized metadata back to the response message.
  """
  @spec apply_to_message(t()) :: Message.t()
  def apply_to_message(%__MODULE__{message: %Message{} = message} = response) do
    metadata =
      message.response_metadata
      |> Map.merge(%{
        usage: response.usage,
        limits: response.limits,
        model: response.model,
        reasoning: response.reasoning,
        tooling: response.tooling,
        safety: response.safety,
        grounding: response.grounding,
        transport: response.transport,
        headers: response.headers,
        provider_metadata: response.provider_metadata,
        outcome: outcome_map(response.outcome)
      })
      |> put_if_absent(:request_id, response.transport[:request_id])
      |> reject_empty_values()

    %{
      message
      | usage_metadata: public_usage(message.usage_metadata, response.usage),
        response_metadata: metadata
    }
  end

  @doc """
  Convenience wrapper used by `BeamWeaver.Core.ChatModel`.
  """
  @spec normalize_message(term(), Message.t(), keyword()) :: Message.t()
  def normalize_message(model, %Message{} = message, opts \\ []) do
    model
    |> from_message(message, opts)
    |> apply_to_message()
  end

  @doc """
  Normalizes and bounds a provider response before it enters runtime state.
  """
  @spec normalize_message_result(term(), Message.t(), keyword()) ::
          {:ok, Message.t()} | {:error, BeamWeaver.Core.Error.t()}
  def normalize_message_result(model, %Message{} = message, opts \\ []) do
    with :ok <- Message.validate(message),
         {:ok, _measurement} <- Validation.measure(message, opts),
         normalized = normalize_message(model, message, opts),
         true <- length(normalized.tool_calls) <= Keyword.get(opts, :max_tool_calls, 256),
         {:ok, _measurement} <- Validation.measure(normalized, opts) do
      {:ok, normalized}
    else
      false ->
        {:error,
         BeamWeaver.Core.Error.new(
           :invalid_provider_response,
           "provider response has too many tool calls"
         )}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Returns the normalized message together with its durable execution outcome
  and provider-native replay projection.
  """
  @spec normalize_execution_result(term(), Message.t(), keyword()) ::
          {:ok, %{message: Message.t(), outcome: Outcome.t(), replay: map() | nil}}
          | {:error, BeamWeaver.Core.Error.t()}
  def normalize_execution_result(model, %Message{} = message, opts \\ []) do
    with {:ok, normalized} <- normalize_message_result(model, message, opts),
         {:ok, replay} <- execution_replay(normalized, model, opts) do
      response = from_message(model, normalized, Keyword.put(opts, :normalized_replay, replay))

      execution_message = %{normalized | usage_metadata: response.usage}

      {:ok, %{message: execution_message, outcome: response.outcome, replay: replay}}
    end
  end

  defp execution_replay(%Message{role: :assistant} = message, model, opts) do
    Replay.project(message, replay_binding(provider(model, message, opts), model, opts))
  end

  defp execution_replay(%Message{}, _model, _opts), do: {:ok, nil}

  defp replay_projection(%Message{role: :assistant} = message, provider, model, opts) do
    case Keyword.fetch(opts, :normalized_replay) do
      {:ok, replay} ->
        replay

      :error ->
        case Replay.project(message, replay_binding(provider, model, opts)) do
          {:ok, projection} -> projection
          {:error, _error} -> nil
        end
    end
  end

  defp replay_projection(_message, _provider, _model, _opts), do: nil

  defp replay_binding(provider, model, opts) do
    Keyword.get(opts, :replay_binding, %{
      provider: provider,
      model: Identity.identifier(model),
      profile: model_profile_value(model, :id)
    })
  end

  defp outcome_map(%Outcome{} = outcome), do: Map.from_struct(outcome)
  defp outcome_map(_outcome), do: %{}

  defp normalize_usage(nil, response_metadata) do
    case raw_usage(response_metadata) do
      nil -> %{}
      usage -> normalize_usage(usage, response_metadata)
    end
  end

  defp normalize_usage(usage, response_metadata) when is_map(usage) do
    raw_message_usage = usage
    usage = usage_key_map(usage)
    input_details = usage |> Map.get(:input_token_details, %{}) |> usage_key_map()
    output_details = usage |> Map.get(:output_token_details, %{}) |> usage_key_map()

    input = first_number(usage, [:input_tokens, :prompt_tokens])
    output = first_number(usage, [:output_tokens, :completion_tokens])
    total = first_number(usage, [:total_tokens, :total]) || sum_present(input, output)

    cache_read =
      first_number(usage, [:cache_read_tokens, :cache_read_input_tokens]) ||
        first_number(input_details, [:cache_read, :cache_read_tokens, :cache_read_input_tokens])

    cache_write =
      first_number(usage, [
        :cache_write_tokens,
        :cache_creation_tokens,
        :cache_creation_input_tokens
      ]) ||
        first_number(input_details, [
          :cache_creation,
          :cache_creation_tokens,
          :cache_creation_input_tokens,
          :cache_write,
          :cache_write_tokens
        ])

    %{
      input_tokens: input,
      initial_input_tokens: first_number(usage, [:initial_input_tokens]),
      context_tokens: first_number(usage, [:context_tokens]),
      output_tokens: output,
      total_tokens: total,
      cache_read_tokens: cache_read,
      cache_write_tokens: cache_write,
      cache_creation_tokens: cache_write,
      reasoning_tokens: first_number(output_details, [:reasoning, :reasoning_tokens, :thinking_tokens]),
      input_token_details: input_details,
      output_token_details: output_details,
      service_tier: Map.get(usage, :service_tier) || metadata_value(response_metadata, :service_tier),
      inference_geo: Map.get(usage, :inference_geo) || metadata_value(response_metadata, :inference_geo),
      server_tool_use:
        hosted_usage_counts(raw_message_usage, response_metadata, :server_tool_use, [
          :web_search_requests,
          :web_fetch_requests,
          :code_execution_requests
        ]),
      server_side_tool_usage_details:
        hosted_usage_counts(raw_message_usage, response_metadata, :server_side_tool_usage_details, [
          :web_search_calls,
          :x_search_calls,
          :x_posts_fetched,
          :x_users_fetched,
          :code_interpreter_calls,
          :file_search_calls
        ])
    }
    |> reject_empty_values()
  end

  defp normalize_usage(_usage, _response_metadata), do: %{}

  defp public_usage(nil, normalized), do: normalized
  defp public_usage(usage, _normalized), do: usage

  defp raw_usage(response_metadata) when is_map(response_metadata) do
    response_metadata[:usage] || response_metadata[:token_usage]
  end

  defp raw_usage(_metadata), do: nil

  defp hosted_usage_counts(usage, response_metadata, field, keys) do
    source =
      metadata_value(usage, field) ||
        response_metadata |> raw_usage() |> metadata_value(field)

    if is_map(source) do
      keys
      |> Enum.reduce(%{}, fn key, acc ->
        case metadata_value(source, key) do
          count when is_integer(count) and count >= 0 -> Map.put(acc, key, count)
          _other -> acc
        end
      end)
      |> MapShape.empty_to_nil()
    end
  end

  defp normalize_limits(model, response_metadata) do
    %{
      max_input_tokens: model_profile_value(model, :max_input_tokens),
      max_output_tokens: model_profile_value(model, :max_output_tokens),
      requested_max_output_tokens: first_number(model, [:max_output_tokens, :max_completion_tokens, :max_tokens])
    }
    |> Map.merge(existing_limits(response_metadata))
    |> reject_empty_values()
  end

  defp normalize_model(model, %Message{} = message, provider) do
    metadata = message.response_metadata || %{}
    model_identifier = Identity.identifier(model)

    %{
      provider: provider,
      model_provider: provider,
      requested_model: model_identifier,
      model: metadata[:model] || model_profile_value(model, :id),
      model_name: metadata[:model_name] || metadata[:model] || model_identifier,
      model_version: metadata[:model_version],
      profile_id: model_profile_value(model, :id),
      tokenizer: model_profile_value(model, :tokenizer),
      api: metadata[:api]
    }
    |> reject_empty_values()
  end

  defp normalize_reasoning(model, %Message{} = message, usage, opts) do
    metadata = message.response_metadata || %{}

    %{
      requested_effort:
        Keyword.get(opts, :effort) || Keyword.get(opts, :reasoning_effort) ||
          Map.get(model, :effort) || Map.get(model, :reasoning_effort) ||
          effort_from_config(Keyword.get(opts, :output_config)) ||
          effort_from_config(Map.get(model, :output_config)) ||
          effort_from_config(Map.get(model, :reasoning)),
      requested_thinking: Keyword.get(opts, :thinking) || Map.get(model, :thinking),
      thinking_level: Keyword.get(opts, :thinking_level) || Map.get(model, :thinking_level),
      thinking_budget: Keyword.get(opts, :thinking_budget) || Map.get(model, :thinking_budget),
      include_thoughts: Keyword.get(opts, :include_thoughts) || Map.get(model, :include_thoughts),
      context: metadata[:reasoning_context] || metadata_value(metadata[:reasoning], :context),
      tokens: usage[:reasoning_tokens],
      content: reasoning_content(message),
      thought_signatures: thought_signatures(message),
      raw: metadata[:reasoning]
    }
    |> reject_empty_values()
  end

  defp normalize_tooling(%Message{} = message, metadata) do
    user_calls = message.tool_calls
    hosted_calls = hosted_tool_calls(message)
    hosted_results = hosted_tool_results(message)
    hosted_usage = hosted_tool_usage(metadata) |> infer_hosted_search_usage(hosted_calls)

    %{
      user: %{call_count: length(user_calls), calls: user_calls},
      hosted: %{
        call_count: length(hosted_calls),
        result_count: length(hosted_results),
        calls: hosted_calls,
        results: hosted_results,
        usage: hosted_usage
      },
      tool_call_count: length(user_calls),
      server_tool_call_count: length(message.server_tool_calls),
      server_tool_result_count: length(message.server_tool_results),
      tool_calls: user_calls
    }
    |> reject_empty_values()
  end

  defp normalize_safety(metadata) when is_map(metadata) do
    %{
      finish_reason: metadata[:finish_reason],
      stop_reason: metadata[:stop_reason],
      safety_ratings: metadata[:safety_ratings],
      prompt_feedback: metadata[:prompt_feedback]
    }
    |> reject_empty_values()
  end

  defp normalize_grounding(metadata) when is_map(metadata) do
    grounding_metadata = metadata[:grounding_metadata]
    query_counts = google_grounding_query_counts(grounding_metadata)

    %{
      citations: metadata[:citations],
      grounding_metadata: grounding_metadata,
      url_context_metadata: metadata[:url_context_metadata],
      web_search_queries: web_search_queries(grounding_metadata),
      web_search_query_count: if(query_counts.search > 0, do: query_counts.search),
      maps_query_count: if(query_counts.maps > 0, do: query_counts.maps),
      maps_grounded_prompt_count: if(query_counts.maps_prompts > 0, do: query_counts.maps_prompts),
      mixed_grounding?: if(query_counts.mixed?, do: true)
    }
    |> reject_empty_values()
  end

  defp web_search_queries(raw) when is_map(raw) do
    raw["web_search_queries"] || raw["webSearchQueries"]
  end

  defp web_search_queries(_metadata), do: nil

  defp google_grounding_query_counts(%{} = grounding_metadata) do
    queries = List.wrap(web_search_queries(grounding_metadata))
    chunks = grounding_metadata["groundingChunks"] || grounding_metadata["grounding_chunks"] || []
    maps? = Enum.any?(chunks, fn chunk -> is_map(chunk) and Map.has_key?(chunk, "maps") end)
    web? = Enum.any?(chunks, fn chunk -> is_map(chunk) and Map.has_key?(chunk, "web") end)

    cond do
      queries == [] -> %{search: 0, maps: 0, maps_prompts: 0, mixed?: false}
      maps? and web? -> %{search: 0, maps: 0, maps_prompts: 0, mixed?: true}
      maps? -> %{search: 0, maps: length(queries), maps_prompts: 1, mixed?: false}
      true -> %{search: length(queries), maps: 0, maps_prompts: 0, mixed?: false}
    end
  end

  defp google_grounding_query_counts(_metadata),
    do: %{search: 0, maps: 0, maps_prompts: 0, mixed?: false}

  defp normalize_transport(metadata) when is_map(metadata) do
    transport = if is_map(metadata[:transport]), do: metadata[:transport], else: %{}

    %{
      request_id: metadata[:request_id] || transport[:request_id] || transport["request_id"] || metadata[:id],
      response_id: metadata[:id],
      status: metadata[:status]
    }
    |> reject_empty_values()
  end

  defp provider_metadata(provider, metadata), do: MapShape.put_present(%{raw: metadata}, :provider, provider)

  defp provider(model, message, opts) do
    Keyword.get(opts, :provider) ||
      model_profile_value(model, :provider) ||
      Map.get(message.response_metadata || %{}, :model_provider) ||
      Map.get(message.response_metadata || %{}, :provider) ||
      Identity.provider(model)
  end

  defp reasoning_content(%Message{} = message) do
    if is_binary(message.metadata[:reasoning_content]) do
      message.metadata[:reasoning_content]
    else
      message
      |> content_blocks()
      |> Enum.flat_map(fn
        %{type: :reasoning, reasoning: text} when is_binary(text) -> [text]
        _block -> []
      end)
      |> Enum.join("")
      |> MapShape.empty_to_nil()
    end
  end

  defp thought_signatures(%Message{} = message) do
    message
    |> content_blocks()
    |> Enum.flat_map(fn
      %{type: type} = block when type in [:reasoning, :text] -> thought_signature_values(block)
      _block -> []
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp content_blocks(message) do
    case Message.content_blocks(message) do
      {:ok, blocks} -> blocks
      _error -> []
    end
  end

  defp thought_signature_values(%{} = block) do
    [
      Map.get(block, :thought_signature),
      Map.get(block, "thought_signature"),
      Map.get(block, :signature),
      Map.get(block, "signature"),
      metadata_value(Map.get(block, :metadata), :thought_signature)
    ]
  end

  @hosted_content_block_types %{
    code_interpreter_call: true,
    file_search_call: true,
    image_generation_call: true,
    mcp_approval_request: true,
    mcp_call: true,
    mcp_list_tools: true,
    shell_call: true,
    server_tool_call: true,
    tool_search_call: true,
    web_search_call: true
  }

  @hosted_result_block_types %{
    custom_tool_call_output: true,
    server_tool_result: true,
    shell_call_output: true,
    tool_search_output: true
  }

  @hosted_summary_keys [:type, :id, :call_id, :tool_call_id, :container_id, :name, :status, :provider_type]

  defp hosted_tool_calls(%Message{} = message),
    do: hosted_summaries(message.server_tool_calls, message, @hosted_content_block_types)

  defp hosted_tool_results(%Message{} = message),
    do: hosted_summaries(message.server_tool_results, message, @hosted_result_block_types)

  defp hosted_summaries(items, message, types) do
    blocks = message |> content_blocks() |> Enum.filter(&(is_map(&1) and Map.has_key?(types, Map.get(&1, :type))))

    (items ++ blocks)
    |> Enum.map(&hosted_tool_summary/1)
    |> Enum.reject(&(&1 == %{}))
    |> Enum.uniq()
  end

  defp hosted_tool_summary(%{} = block) do
    @hosted_summary_keys
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(block, key) || Map.get(block, to_string(key)) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, key, value)
      end
    end)
    |> maybe_put_action_type(block)
  end

  defp hosted_tool_summary(_block), do: %{}

  defp maybe_put_action_type(summary, block) do
    action = Map.get(block, :action) || Map.get(block, "action")

    case metadata_value(action, :type) do
      type when is_binary(type) and type != "" ->
        Map.put(summary, :action_type, type)

      type when is_atom(type) and not is_nil(type) ->
        Map.put(summary, :action_type, Atom.to_string(type))

      _other ->
        summary
    end
  end

  defp infer_hosted_search_usage(usage, calls) do
    if is_integer(get_in(usage, [:web_search, :num_requests])) do
      usage
    else
      requests =
        Enum.count(calls, fn call ->
          call[:type] in [:web_search_call, "web_search_call"] and call[:action_type] == "search"
        end)

      if requests > 0 do
        Map.update(usage, :web_search, %{num_requests: requests}, &Map.put(&1, :num_requests, requests))
      else
        usage
      end
    end
  end

  defp hosted_tool_usage(metadata) when is_map(metadata) do
    metadata
    |> raw_provider_response()
    |> tool_usage()
  end

  defp raw_provider_response(metadata) when is_map(metadata) do
    metadata[:raw_provider_response] ||
      metadata["raw_provider_response"] ||
      get_in(metadata, [:provider_metadata, :raw, :raw_provider_response]) ||
      get_in(metadata, ["provider_metadata", "raw", "raw_provider_response"]) ||
      metadata
  end

  defp tool_usage(%{} = response) do
    response
    |> Map.get("tool_usage")
    |> normalize_tool_usage()
  end

  defp tool_usage(_response), do: %{}

  defp normalize_tool_usage(%{} = usage) do
    %{
      image_gen: normalize_image_gen_usage(Map.get(usage, "image_gen")),
      web_search: normalize_web_search_usage(Map.get(usage, "web_search"))
    }
    |> reject_empty_values()
  end

  defp normalize_tool_usage(_usage), do: %{}

  defp normalize_image_gen_usage(%{} = usage) do
    normalized =
      %{
        input_tokens: first_number(usage, ["input_tokens"]),
        output_tokens: first_number(usage, ["output_tokens"]),
        total_tokens: first_number(usage, ["total_tokens"]),
        input_token_details: static_tool_usage_details(Map.get(usage, "input_tokens_details")),
        output_token_details: static_tool_usage_details(Map.get(usage, "output_tokens_details"))
      }
      |> reject_empty_values()

    if positive_image_generation_usage?(normalized), do: normalized, else: %{}
  end

  defp normalize_image_gen_usage(_usage), do: %{}

  defp positive_image_generation_usage?(usage) do
    Enum.any?([:input_tokens, :output_tokens, :total_tokens], fn key ->
      is_number(usage[key]) and usage[key] > 0
    end)
  end

  defp normalize_web_search_usage(%{} = usage) do
    case first_number(usage, ["num_requests"]) do
      count when is_number(count) and count > 0 -> %{num_requests: count}
      _other -> %{}
    end
  end

  defp normalize_web_search_usage(_usage), do: %{}

  defp static_tool_usage_details(%{} = details) do
    %{
      image_tokens: first_number(details, ["image_tokens"]),
      text_tokens: first_number(details, ["text_tokens"])
    }
    |> reject_empty_values()
  end

  defp static_tool_usage_details(_details), do: %{}

  defp normalize_headers(%{headers: headers}) when is_map(headers), do: Map.filter(headers, &is_atom(elem(&1, 0)))
  defp normalize_headers(_metadata), do: %{}

  defp existing_limits(%{limits: %{} = limits}), do: limits
  defp existing_limits(_metadata), do: %{}

  defp effort_from_config(config) when is_list(config), do: Keyword.get(config, :effort)
  defp effort_from_config(config) when is_map(config), do: Map.get(config, :effort)
  defp effort_from_config(_config), do: nil

  defp profile_value(%Profile{} = profile, key), do: Map.get(profile, key)
  defp profile_value(_profile, _key), do: nil

  defp model_profile_value(model, key), do: model_profile_value(model, key, 0)

  defp model_profile_value(_model, _key, depth) when depth >= 8, do: nil

  defp model_profile_value(model, key, depth) when is_map(model) do
    profile_value(Map.get(model, :profile), key) ||
      case Map.get(model, :model) do
        nested when is_map(nested) -> model_profile_value(nested, key, depth + 1)
        _nested -> nil
      end
  end

  defp model_profile_value(_model, _key, _depth), do: nil

  defp first_number(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) or is_float(value) -> value
        value when is_binary(value) -> parse_number(value)
        _value -> nil
      end
    end)
  end

  defp parse_number(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp sum_present(nil, nil), do: nil
  defp sum_present(left, nil), do: left
  defp sum_present(nil, right), do: right
  defp sum_present(left, right), do: left + right

  # Provider usage arrives as JSON: its known keys become atoms, and every
  # spelling of the token details one name.
  @usage_keys Map.merge(
                Map.new(
                  ~w(input_tokens initial_input_tokens context_tokens prompt_tokens output_tokens completion_tokens total_tokens total input_token_details
                     output_token_details cache_read cache_read_tokens cache_read_input_tokens cache_creation
                     cache_creation_tokens cache_creation_input_tokens cache_write cache_write_tokens
                     ephemeral_5m_input_tokens ephemeral_1h_input_tokens reasoning reasoning_tokens thinking_tokens
                     service_tier inference_geo)a,
                  &{Atom.to_string(&1), &1}
                ),
                %{
                  "input_tokens_details" => :input_token_details,
                  "prompt_token_details" => :input_token_details,
                  "prompt_tokens_details" => :input_token_details,
                  "output_tokens_details" => :output_token_details,
                  "completion_token_details" => :output_token_details,
                  "completion_tokens_details" => :output_token_details
                }
              )

  defp usage_key_map(map) when is_map(map) do
    map
    |> Enum.flat_map(fn
      {key, value} ->
        case usage_key(key) do
          nil -> []
          normalized_key -> [{normalized_key, usage_key_value(value)}]
        end
    end)
    |> Map.new()
  end

  defp usage_key_map(_value), do: %{}

  defp usage_key_value(value) when is_map(value), do: usage_key_map(value)
  defp usage_key_value(value) when is_list(value), do: Enum.map(value, &usage_key_value/1)
  defp usage_key_value(value), do: value

  defp usage_key(key) when is_atom(key), do: key
  defp usage_key(key), do: Map.get(@usage_keys, key)

  defp put_if_absent(map, _key, nil), do: map
  defp put_if_absent(map, _key, ""), do: map

  defp put_if_absent(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      "" -> Map.put(map, key, value)
      _existing -> map
    end
  end

  defp reject_empty_values(map), do: MapShape.compact(map, [nil, :empty_list, :empty_map])
end
