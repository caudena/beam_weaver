defmodule BeamWeaver.Provider.Response do
  @moduledoc """
  Normalized provider response envelope used internally for tracing metadata.

  Public chat model APIs still return `BeamWeaver.Core.Message`; the normalized
  envelope is copied onto `usage_metadata` and `response_metadata` so traces and
  stream events can consume one stable shape across providers.
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
            provider_metadata: %{},
            raw: nil

  @type t :: %__MODULE__{}

  @doc """
  Builds a normalized envelope from a provider message.
  """
  @spec from_message(term(), Message.t(), keyword()) :: t()
  def from_message(model, %Message{} = message, opts \\ []) do
    provider = provider(model, message, opts)

    %__MODULE__{
      message: message,
      usage: normalize_usage(message.usage_metadata, message.response_metadata),
      limits: normalize_limits(model, message.response_metadata),
      model: normalize_model(model, message, provider),
      reasoning: normalize_reasoning(model, message, opts),
      tooling: normalize_tooling(message),
      safety: normalize_safety(message.response_metadata),
      grounding: normalize_grounding(message.response_metadata),
      transport: normalize_transport(message.response_metadata),
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
        provider_metadata: response.provider_metadata
      })
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
    input = first_number(usage, [:input_tokens, :prompt_tokens])

    output = first_number(usage, [:output_tokens, :completion_tokens])

    total = first_number(usage, [:total_tokens, :total]) || sum_present(input, output)

    input_details = Map.get(usage, :input_token_details) || %{}
    output_details = Map.get(usage, :output_token_details) || %{}

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      cache_read_tokens: first_number(input_details, [:cache_read, :cache_read_tokens]),
      cache_creation_tokens: first_number(input_details, [:cache_creation, :cache_creation_tokens]),
      reasoning_tokens: first_number(output_details, [:reasoning, :reasoning_tokens]),
      input_token_details: atom_key_map(input_details),
      output_token_details: atom_key_map(output_details),
      service_tier: Map.get(usage, :service_tier)
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
    headers = headers(response_metadata)

    %{
      max_input_tokens: profile_value(profile, :max_input_tokens),
      max_output_tokens: profile_value(profile, :max_output_tokens),
      requested_max_output_tokens: first_number(model, [:max_output_tokens, :max_completion_tokens, :max_tokens]),
      rate_limit_requests: header(headers, "x-ratelimit-limit-requests"),
      rate_limit_tokens: header(headers, "x-ratelimit-limit-tokens"),
      remaining_requests: header(headers, "x-ratelimit-remaining-requests"),
      remaining_tokens: header(headers, "x-ratelimit-remaining-tokens"),
      reset_requests: header(headers, "x-ratelimit-reset-requests"),
      reset_tokens: header(headers, "x-ratelimit-reset-tokens"),
      retry_after: header(headers, "retry-after")
    }
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
        Keyword.get(opts, :reasoning_effort) || Map.get(model, :reasoning_effort) ||
          nested_value(Map.get(model, :reasoning), ["effort", :effort]),
      requested_thinking: Keyword.get(opts, :thinking) || Map.get(model, :thinking),
      thinking_level: Keyword.get(opts, :thinking_level) || Map.get(model, :thinking_level),
      thinking_budget: Keyword.get(opts, :thinking_budget) || Map.get(model, :thinking_budget),
      include_thoughts: Keyword.get(opts, :include_thoughts) || Map.get(model, :include_thoughts),
      tokens: usage[:reasoning_tokens],
      content: reasoning_content(message),
      raw: metadata[:reasoning]
    }
    |> reject_empty_values()
  end

  defp normalize_tooling(%Message{} = message) do
    %{
      tool_call_count: length(message.tool_calls || []),
      server_tool_call_count: length(message.server_tool_calls || []),
      server_tool_result_count: length(message.server_tool_results || []),
      tool_calls: message.tool_calls
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

  defp normalize_safety(_metadata), do: %{}

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

  defp normalize_grounding(_metadata), do: %{}

  defp web_search_queries(raw) when is_map(raw) do
    raw["web_search_queries"] || raw["webSearchQueries"]
  end

  defp web_search_queries(_metadata), do: nil

  defp normalize_transport(metadata) when is_map(metadata) do
    headers = headers(metadata)

    %{
      request_id:
        metadata[:request_id] || header(headers, "x-request-id") ||
          header(headers, "request-id") || metadata[:id],
      response_id: metadata[:id],
      status: metadata[:status],
      headers: headers
    }
    |> reject_empty_values()
  end

  defp normalize_transport(_metadata), do: %{}

  defp provider_metadata(nil, metadata), do: %{raw: metadata || %{}}

  defp provider_metadata(provider, metadata) do
    %{provider: provider, raw: metadata || %{}}
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

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp headers(metadata) when is_map(metadata) do
    metadata
    |> Map.get(:headers, %{})
    |> case do
      headers when is_map(headers) ->
        Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), value} end)

      headers when is_list(headers) ->
        headers
        |> BeamWeaver.Transport.Request.normalize_headers()
        |> Map.new()

      _other ->
        %{}
    end
  end

  defp headers(_metadata), do: %{}

  defp header(headers, key) when is_map(headers), do: Map.get(headers, String.downcase(key))

  defp nested_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp nested_value(_value, _keys), do: nil

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

  defp first_number(_map, _keys), do: nil

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

  defp atom_key_map(map) when is_map(map) do
    map
    |> Enum.flat_map(fn
      {key, value} when is_atom(key) -> [{key, atom_key_value(value)}]
      {_key, _value} -> []
    end)
    |> Map.new()
  end

  defp atom_key_map(_value), do: %{}

  defp atom_key_value(value) when is_map(value), do: atom_key_map(value)
  defp atom_key_value(value) when is_list(value), do: Enum.map(value, &atom_key_value/1)
  defp atom_key_value(value), do: value

  defp reject_empty_values(map) when is_map(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      _entry -> false
    end)
  end
end
