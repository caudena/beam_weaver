defmodule BeamWeaver.Provider.Response do
  @moduledoc """
  Normalized provider response envelope used internally for tracing metadata.

  Public chat model APIs still return `BeamWeaver.Core.Message`; the normalized
  envelope is copied onto `usage_metadata` and `response_metadata` so traces and
  stream events can consume one stable shape across providers.

  Provider clients own response-header decoding. Core preserves
  `response_metadata.headers` only when the client already supplied an
  atom-keyed, allowlisted decoded header map; raw/full HTTP transport headers
  must stay in debug-only metadata and are not interpreted here.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.Profile

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
            raw: nil

  @type t :: %__MODULE__{}

  @doc """
  Builds a normalized envelope from a provider message.
  """
  @spec from_message(term(), Message.t(), keyword()) :: t()
  def from_message(model, %Message{} = message, opts \\ []) do
    provider = provider(model, message, opts)
    headers = normalize_headers(message.response_metadata)

    %__MODULE__{
      message: message,
      usage: normalize_usage(message.usage_metadata, message.response_metadata),
      limits: normalize_limits(model, message.response_metadata),
      model: normalize_model(model, message, provider),
      reasoning: normalize_reasoning(model, message, opts),
      tooling: normalize_tooling(message, message.response_metadata),
      safety: normalize_safety(message.response_metadata),
      grounding: normalize_grounding(message.response_metadata),
      transport: normalize_transport(message.response_metadata),
      headers: headers,
      provider_metadata: provider_metadata(provider, message.response_metadata),
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
        provider_metadata: response.provider_metadata
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

  defp normalize_usage(nil, response_metadata) do
    case raw_usage(response_metadata) do
      nil -> %{}
      usage -> normalize_usage(usage, %{})
    end
  end

  defp normalize_usage(usage, _response_metadata) when is_map(usage) do
    usage = usage_key_map(usage)
    input_details = usage |> Map.get(:input_token_details, %{}) |> usage_key_map()
    output_details = usage |> Map.get(:output_token_details, %{}) |> usage_key_map()

    input = first_number(usage, [:input_tokens, :prompt_tokens])
    output = first_number(usage, [:output_tokens, :completion_tokens])
    total = first_number(usage, [:total_tokens, :total]) || sum_present(input, output)

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      cache_read_tokens: first_number(input_details, [:cache_read, :cache_read_tokens, :cache_read_input_tokens]),
      cache_creation_tokens: first_number(input_details, [:cache_creation, :cache_creation_tokens]),
      reasoning_tokens: first_number(output_details, [:reasoning, :reasoning_tokens, :thinking_tokens]),
      input_token_details: input_details,
      output_token_details: output_details,
      service_tier: Map.get(usage, :service_tier),
      inference_geo: Map.get(usage, :inference_geo)
    }
    |> reject_empty_values()
  end

  defp normalize_usage(_usage, _response_metadata), do: %{}

  defp public_usage(nil, normalized), do: normalized
  defp public_usage(%{} = usage, _normalized) when map_size(usage) == 0, do: usage
  defp public_usage(usage, _normalized), do: usage

  defp raw_usage(response_metadata) when is_map(response_metadata) do
    response_metadata[:usage] || response_metadata[:token_usage]
  end

  defp raw_usage(_metadata), do: nil

  defp normalize_limits(model, response_metadata) do
    profile = Map.get(model, :profile)

    %{
      max_input_tokens: profile_value(profile, :max_input_tokens),
      max_output_tokens: profile_value(profile, :max_output_tokens),
      requested_max_output_tokens: first_number(model, [:max_output_tokens, :max_completion_tokens, :max_tokens])
    }
    |> Map.merge(existing_limits(response_metadata))
    |> reject_empty_values()
  end

  defp normalize_model(model, %Message{} = message, provider) do
    metadata = message.response_metadata || %{}
    profile = Map.get(model, :profile)

    %{
      provider: provider,
      model_provider: provider,
      requested_model: Map.get(model, :model),
      model: metadata[:model] || profile_value(profile, :id),
      model_name: metadata[:model_name] || metadata[:model] || Map.get(model, :model),
      model_version: metadata[:model_version],
      profile_id: profile_value(profile, :id),
      tokenizer: profile_value(profile, :tokenizer),
      api: metadata[:api]
    }
    |> reject_empty_values()
  end

  defp normalize_reasoning(model, %Message{} = message, opts) do
    usage = normalize_usage(message.usage_metadata, message.response_metadata)
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
    hosted_usage = hosted_tool_usage(metadata)

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

    %{
      citations: metadata[:citations],
      grounding_metadata: grounding_metadata,
      url_context_metadata: metadata[:url_context_metadata],
      web_search_queries: web_search_queries(grounding_metadata)
    }
    |> reject_empty_values()
  end

  defp web_search_queries(raw) when is_map(raw) do
    raw["web_search_queries"] || raw["webSearchQueries"]
  end

  defp web_search_queries(_metadata), do: nil

  defp normalize_transport(metadata) when is_map(metadata) do
    transport = if is_map(metadata[:transport]), do: metadata[:transport], else: %{}

    %{
      request_id: metadata[:request_id] || transport[:request_id] || transport["request_id"] || metadata[:id],
      response_id: metadata[:id],
      status: metadata[:status]
    }
    |> reject_empty_values()
  end

  defp provider_metadata(nil, metadata), do: %{raw: metadata}

  defp provider_metadata(provider, metadata) do
    %{provider: provider, raw: metadata}
  end

  defp provider(model, message, opts) do
    Keyword.get(opts, :provider) ||
      profile_value(Map.get(model, :profile), :provider) ||
      Map.get(message.response_metadata || %{}, :model_provider) ||
      Map.get(message.response_metadata || %{}, :provider) ||
      Map.get(model, :provider)
  end

  defp reasoning_content(%Message{} = message) do
    if is_binary(message.metadata[:reasoning_content]) do
      message.metadata[:reasoning_content]
    else
      message
      |> Message.content_blocks()
      |> case do
        {:ok, blocks} ->
          blocks
          |> Enum.flat_map(fn
            %{type: :reasoning, reasoning: text} when is_binary(text) -> [text]
            _block -> []
          end)
          |> Enum.join("")
          |> empty_to_nil()

        _error ->
          nil
      end
    end
  end

  defp thought_signatures(%Message{} = message) do
    message
    |> Message.content_blocks()
    |> case do
      {:ok, blocks} ->
        blocks
        |> Enum.flat_map(fn
          %{type: type} = block when type in [:reasoning, :text] -> thought_signature_values(block)
          _block -> []
        end)
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.uniq()

      _error ->
        []
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
    file_search_call: true,
    image_generation_call: true,
    mcp_approval_request: true,
    mcp_call: true,
    mcp_list_tools: true,
    server_tool_call: true,
    tool_search_call: true,
    web_search_call: true
  }

  @hosted_result_block_types %{
    custom_tool_call_output: true,
    server_tool_result: true,
    tool_search_output: true
  }

  @hosted_summary_keys [:type, :id, :call_id, :tool_call_id, :name, :status, :provider_type]

  defp hosted_tool_calls(%Message{} = message) do
    (message.server_tool_calls ++ hosted_content_blocks(message, @hosted_content_block_types))
    |> Enum.map(&hosted_tool_summary/1)
    |> Enum.reject(&(&1 == %{}))
    |> Enum.uniq()
  end

  defp hosted_tool_results(%Message{} = message) do
    (message.server_tool_results ++ hosted_content_blocks(message, @hosted_result_block_types))
    |> Enum.map(&hosted_tool_summary/1)
    |> Enum.reject(&(&1 == %{}))
    |> Enum.uniq()
  end

  defp hosted_content_blocks(%Message{} = message, types) do
    message
    |> Message.content_blocks()
    |> case do
      {:ok, blocks} ->
        Enum.filter(blocks, fn
          %{type: type} -> Map.has_key?(types, type)
          _block -> false
        end)

      _error ->
        []
    end
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
  end

  defp hosted_tool_summary(_block), do: %{}

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
    %{
      input_tokens: first_number(usage, ["input_tokens"]),
      output_tokens: first_number(usage, ["output_tokens"]),
      total_tokens: first_number(usage, ["total_tokens"]),
      input_token_details: static_tool_usage_details(Map.get(usage, "input_tokens_details")),
      output_token_details: static_tool_usage_details(Map.get(usage, "output_tokens_details"))
    }
    |> reject_empty_values()
  end

  defp normalize_image_gen_usage(_usage), do: %{}

  defp normalize_web_search_usage(%{} = usage) do
    %{
      num_requests: first_number(usage, ["num_requests"])
    }
    |> reject_empty_values()
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

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp metadata_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp metadata_value(_map, _key), do: nil

  defp normalize_headers(metadata) when is_map(metadata) do
    metadata
    |> Map.get(:headers, %{})
    |> atom_keyed_map()
  end

  defp normalize_headers(_metadata), do: %{}

  defp atom_keyed_map(headers) when is_map(headers) do
    headers
    |> Enum.filter(fn {key, _value} -> is_atom(key) end)
    |> Map.new()
  end

  defp atom_keyed_map(_headers), do: %{}

  defp existing_limits(metadata) when is_map(metadata) do
    case metadata[:limits] do
      limits when is_map(limits) -> limits
      _limits -> %{}
    end
  end

  defp existing_limits(_metadata), do: %{}

  defp effort_from_config(config) when is_list(config), do: Keyword.get(config, :effort)
  defp effort_from_config(config) when is_map(config), do: Map.get(config, :effort)
  defp effort_from_config(_config), do: nil

  defp profile_value(%Profile{} = profile, key), do: Map.get(profile, key)
  defp profile_value(_profile, _key), do: nil

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
  defp usage_key("input_tokens"), do: :input_tokens
  defp usage_key("prompt_tokens"), do: :prompt_tokens
  defp usage_key("output_tokens"), do: :output_tokens
  defp usage_key("completion_tokens"), do: :completion_tokens
  defp usage_key("total_tokens"), do: :total_tokens
  defp usage_key("total"), do: :total
  defp usage_key("input_token_details"), do: :input_token_details
  defp usage_key("input_tokens_details"), do: :input_token_details
  defp usage_key("prompt_token_details"), do: :input_token_details
  defp usage_key("prompt_tokens_details"), do: :input_token_details
  defp usage_key("output_token_details"), do: :output_token_details
  defp usage_key("output_tokens_details"), do: :output_token_details
  defp usage_key("completion_token_details"), do: :output_token_details
  defp usage_key("completion_tokens_details"), do: :output_token_details
  defp usage_key("cache_read"), do: :cache_read
  defp usage_key("cache_read_tokens"), do: :cache_read_tokens
  defp usage_key("cache_read_input_tokens"), do: :cache_read_input_tokens
  defp usage_key("cache_creation"), do: :cache_creation
  defp usage_key("cache_creation_tokens"), do: :cache_creation_tokens
  defp usage_key("cache_creation_input_tokens"), do: :cache_creation_input_tokens
  defp usage_key("ephemeral_5m_input_tokens"), do: :ephemeral_5m_input_tokens
  defp usage_key("ephemeral_1h_input_tokens"), do: :ephemeral_1h_input_tokens
  defp usage_key("reasoning"), do: :reasoning
  defp usage_key("reasoning_tokens"), do: :reasoning_tokens
  defp usage_key("thinking_tokens"), do: :thinking_tokens
  defp usage_key("service_tier"), do: :service_tier
  defp usage_key("inference_geo"), do: :inference_geo
  defp usage_key(_key), do: nil

  defp put_if_absent(map, _key, nil), do: map
  defp put_if_absent(map, _key, ""), do: map

  defp put_if_absent(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      "" -> Map.put(map, key, value)
      _existing -> map
    end
  end

  defp reject_empty_values(map) when is_map(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      _entry -> false
    end)
  end
end
