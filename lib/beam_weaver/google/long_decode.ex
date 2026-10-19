defmodule BeamWeaver.Google.LongDecode do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Google.Messages
  alias BeamWeaver.Google.Streaming
  alias BeamWeaver.Provider.StreamValidator
  alias BeamWeaver.Stream, as: BWStream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  def enabled?(model, opts), do: Keyword.get(opts, :automatic_continuation, model == "gemini-4-argon") == true

  # A single outer producer owns all hops. The inner HTTP stream monitors its
  # consumer, so halting the outer stream also cancels an in-flight request.
  def stream(open, body, opts) do
    retries = Keyword.get(opts, :max_continuation_retries, 2)

    with :ok <- validate_retries(retries),
         {:ok, original} <- original_body(body),
         {:ok, first} <- open.(body) do
      state = %{
        original: original,
        token: original["continuationToken"],
        seen: MapSet.new(List.wrap(original["continuationToken"])),
        hops: [],
        retries: retries,
        remaining_retries: retries,
        validation: StreamValidator.new(opts)
      }

      stream =
        BWStream.live_resource(fn sink -> run(first, open, state, sink) end,
          timeout: Keyword.get(opts, :stream_timeout, :infinity),
          producer_supervisor: Keyword.get(opts, :producer_supervisor)
        )

      {:ok,
       Stream.map(stream, fn
         %Envelope{} = envelope -> envelope
         event -> BWStream.envelope(event, metadata: %{provider: :google})
       end)}
    end
  end

  def collect(stream) do
    Enum.reduce_while(stream, {:error, invalid("Gemini stream ended without a final response")}, fn
      %Envelope{event: %Events.Done{result: response}}, _ -> {:cont, {:ok, response}}
      %Envelope{event: %Events.Error{error: error}}, _ -> {:halt, {:error, error}}
      _, result -> {:cont, result}
    end)
  end

  # Raw chunks stay private. Only checkpointed deltas reach the caller, so a
  # reconnect can discard uncommitted output without requiring UI rollback.
  def raw_events(events, state) do
    items =
      for %{"data" => %{} = response} <- events,
          do: BWStream.envelope(%Events.Custom{payload: {:google_decode_chunk, response}})

    {items, state}
  end

  def raw_end(response), do: [BWStream.envelope(%Events.Custom{payload: {:google_decode_end, response}})]

  defp run(stream, open, state, sink) do
    hop = %{responses: [], pending: [], checkpoint: nil, headers: %{}, closed?: false, error: nil, state: state}

    hop =
      Enum.reduce_while(stream, hop, fn
        %Envelope{event: %Events.Custom{payload: {:google_decode_chunk, response}}}, hop ->
          case StreamValidator.push(hop.state.validation, response) do
            {:ok, validation} ->
              state = %{hop.state | validation: validation}
              hop = %{hop | responses: [response | hop.responses], pending: [response | hop.pending], state: state}
              token = candidate(response)["continuationToken"]

              if is_binary(token) and token != "" do
                emit(hop.pending, sink)
                {:cont, %{hop | pending: [], checkpoint: {token, hop.responses}}}
              else
                {:cont, hop}
              end

            {:error, error, _validation} ->
              {:halt, %{hop | error: error}}
          end

        %Envelope{event: %Events.Custom{payload: {:google_decode_end, headers}}}, hop ->
          {:cont, %{hop | closed?: true, headers: headers}}

        %Envelope{event: %Events.Error{error: error}}, hop ->
          {:halt, %{hop | error: error}}

        _, hop ->
          {:cont, hop}
      end)

    response = hop.responses |> Enum.reverse() |> Streaming.merge_responses() |> Map.merge(hop.headers)
    reason = candidate(response)["finishReason"]

    cond do
      hop.error ->
        recover(hop, open, sink, hop.error)

      not hop.closed? or (is_nil(reason) and not blocked?(response)) ->
        recover(
          hop,
          open,
          sink,
          Error.new(:connection, "Gemini stream ended before its terminal response", %{retryable: true})
        )

      reason == "CONTINUATION" ->
        token = candidate(response)["continuationToken"]

        with :ok <- next_token(hop.state, token) do
          emit(hop.pending, sink)

          state = %{
            hop.state
            | hops: [response | hop.state.hops],
              token: token,
              seen: MapSet.put(hop.state.seen, token),
              remaining_retries: hop.state.retries
          }

          resume(open, state, sink)
        end

      true ->
        emit(hop.pending, sink)
        finish([response | hop.state.hops], sink)
    end
  end

  defp recover(hop, open, sink, error) do
    state = hop.state

    if state.remaining_retries > 0 and BeamWeaver.RetryPredicates.transient?(error) do
      state = %{state | remaining_retries: state.remaining_retries - 1}

      case hop.checkpoint do
        {token, responses} ->
          with :ok <- next_token(state, token) do
            response = responses |> Enum.reverse() |> Streaming.merge_responses()

            resume(
              open,
              %{state | hops: [response | state.hops], token: token, seen: MapSet.put(state.seen, token)},
              sink
            )
          end

        nil ->
          resume(open, state, sink)
      end
    else
      {:error, error}
    end
  end

  defp resume(open, state, sink) do
    body = if state.token, do: Map.put(state.original, "continuationToken", state.token), else: state.original

    case open.(body) do
      {:ok, stream} -> run(stream, open, state, sink)
      {:error, error} -> {:error, error}
    end
  end

  defp finish(hops, sink) do
    response = merge_hops(Enum.reverse(hops))

    with {:ok, message} <- Messages.response_to_message(response) do
      sink.(BWStream.envelope(%Events.Message{message: message}, metadata: %{provider: :google}))

      sink.(
        BWStream.envelope(%Events.Done{result: response, usage: response["usageMetadata"]},
          metadata: %{provider: :google}
        )
      )

      :ok
    end
  end

  defp emit(responses, sink) do
    events = for response <- Enum.reverse(responses), do: %{"data" => response}
    {items, _} = Streaming.typed_events(events, nil)
    Enum.each(items, sink)
  end

  defp merge_hops(hops) do
    final = List.last(hops)
    # Streaming usage is provisional until the hop commits. In particular,
    # Google's final prompt count can exceed the count in its first chunk.
    initial_input = get_in(hd(hops), ["usageMetadata", "promptTokenCount"])
    parts = Enum.flat_map(hops, &(get_in(candidate(&1), ["content", "parts"]) || []))
    content = Map.put(candidate(final)["content"] || %{"role" => "model"}, "parts", parts)
    usage = Enum.reduce(hops, %{}, &sum_usage(&2, &1["usageMetadata"] || %{}))
    usage = if is_integer(initial_input), do: Map.put(usage, "initialPromptTokenCount", initial_input), else: usage

    final
    |> Map.put("candidates", [Map.put(candidate(final), "content", content)])
    |> Map.put("usageMetadata", usage)
  end

  # Counts are cumulative within a hop; only its last usage snapshot is summed.
  # Modality breakdowns are arrays, so combine counts by their modality too.
  defp sum_usage(left, right) do
    Map.merge(left, right, fn
      key, a, b when is_number(a) and is_number(b) ->
        if key == "tokenCount" or String.ends_with?(key, "TokenCount"), do: a + b, else: b

      _key, a, b when is_list(a) and is_list(b) ->
        (a ++ b)
        |> Enum.group_by(& &1["modality"])
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {_modality, values} -> Enum.reduce(values, %{}, &sum_usage(&2, &1)) end)

      _key, _a, b ->
        b
    end)
  end

  defp candidate(response), do: get_in(response, ["candidates", Access.at(0)]) || %{}

  defp blocked?(response),
    do: get_in(response, ["promptFeedback", "blockReason"]) not in [nil, "", "BLOCK_REASON_UNSPECIFIED"]

  defp next_token(state, token) do
    cond do
      not is_binary(token) or token == "" -> {:error, invalid("Gemini CONTINUATION response has no continuation token")}
      MapSet.member?(state.seen, token) -> {:error, invalid("Gemini repeated a continuation token without advancing")}
      true -> :ok
    end
  end

  defp original_body(body) when is_map(body), do: {:ok, BeamWeaver.MapShape.stringify_keys(body)}

  defp original_body(body) when is_binary(body) do
    case BeamWeaver.JSON.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _ -> {:error, invalid("Gemini continuation requires a JSON object request")}
    end
  end

  defp validate_retries(value) when is_integer(value) and value >= 0, do: :ok

  defp validate_retries(_value),
    do: {:error, Error.new(:invalid_model_option, "max_continuation_retries must be a non-negative integer")}

  defp invalid(message), do: Error.new(:invalid_provider_response, message, %{provider: :google, retryable: false})
end
