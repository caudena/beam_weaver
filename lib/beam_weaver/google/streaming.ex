defmodule BeamWeaver.Google.Streaming do
  @moduledoc false

  alias BeamWeaver.Core.Messages.AIChunk
  alias BeamWeaver.Google.Messages
  alias BeamWeaver.Provider.SSE
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

  @spec text_deltas([map()]) :: [String.t()]
  def text_deltas(events) when is_list(events) do
    events
    |> Enum.flat_map(&event_parts/1)
    |> Enum.flat_map(fn
      %{"text" => text, "thought" => true} when is_binary(text) -> []
      %{"text" => text} when is_binary(text) -> [text]
      _part -> []
    end)
  end

  def typed_events(events, state) do
    responses = for %{"data" => %{} = response} <- events, do: response
    {typed_parts(events), Enum.reverse(responses, state || [])}
  end

  defp typed_parts(events) do
    events
    |> Enum.flat_map(&event_parts/1)
    |> Enum.flat_map(fn
      %{"text" => text, "thought" => true} when is_binary(text) ->
        [
          Stream.envelope(
            %Events.MessageChunk{
              chunk: %AIChunk{content: [%{type: :reasoning, reasoning: text}]}
            },
            metadata: %{provider: :google, block_type: :reasoning}
          )
        ]

      %{"text" => text} when is_binary(text) ->
        [
          Stream.envelope(%Events.Token{text: text}, metadata: %{provider: :google}),
          Stream.envelope(%Events.MessageChunk{chunk: %AIChunk{content: text}},
            metadata: %{provider: :google}
          )
        ]

      %{"functionCall" => call} when is_map(call) ->
        [
          Stream.envelope(
            %Events.Custom{payload: %{name: :tool_call_delta, payload: call}},
            metadata: %{provider: :google, block_type: :tool_call}
          )
        ]

      part when is_map(part) ->
        [
          Stream.envelope(
            %Events.Custom{payload: %{name: :google_part, payload: part}},
            metadata: %{provider: :google}
          )
        ]

      _part ->
        []
    end)
  end

  def finish_typed_events(state, decode_response) do
    with {:ok, response} <- decode_response.(merge_responses(Enum.reverse(state || []))),
         {:ok, message} <- Messages.response_to_message(response),
         :ok <- validate_complete_response(response) do
      {:ok,
       [
         Stream.envelope(%Events.Message{message: message}, metadata: %{provider: :google}),
         Stream.envelope(%Events.Done{result: response, usage: response["usageMetadata"]},
           metadata: %{provider: :google}
         )
       ]}
    end
  end

  defp validate_complete_response(response) do
    candidate = get_in(response, ["candidates", Access.at(0)]) || %{}
    blocked? = get_in(response, ["promptFeedback", "blockReason"]) not in [nil, "", "BLOCK_REASON_UNSPECIFIED"]

    if is_binary(candidate["finishReason"]) or blocked? do
      :ok
    else
      {:error,
       BeamWeaver.Core.Error.new(:invalid_provider_stream, "Gemini stream ended without a terminal finish reason")}
    end
  end

  @spec response_from_sse_body(binary()) :: map()
  def response_from_sse_body(body) when is_binary(body) do
    body
    |> SSE.events()
    |> Enum.map(& &1["data"])
    |> merge_responses()
  end

  defp merge_responses([]), do: %{}

  defp merge_responses(responses) do
    parts =
      responses
      |> Enum.flat_map(fn response ->
        get_in(response, ["candidates", Access.at(0), "content", "parts"]) || []
      end)
      |> merge_response_parts()

    # Usage-only trailers must not erase the last candidate, finish reason or
    # grounding metadata; those may arrive before the last transport chunk.
    final =
      Enum.reduce(responses, %{}, fn response, acc ->
        Map.merge(acc, Map.delete(response, "candidates"), fn
          "usageMetadata", previous, current when is_map(previous) and is_map(current) ->
            Map.merge(previous, current)

          _key, _previous, current ->
            current
        end)
      end)

    candidate =
      Enum.reduce(responses, %{}, fn response, acc ->
        Map.merge(acc, get_in(response, ["candidates", Access.at(0)]) || %{})
      end)

    content = %{"role" => "model", "parts" => parts}

    final
    |> Map.put("candidates", [Map.put(candidate, "content", content)])
  end

  defp merge_response_parts(parts) do
    parts
    |> Enum.reduce({[], nil}, fn
      %{"text" => ""} = part, acc when map_size(part) == 1 ->
        acc

      part, acc when is_map(part) ->
        append_response_part(acc, part)

      _part, acc ->
        acc
    end)
    |> finish_response_parts()
  end

  # The state holds the parts so far and the part still open, if any.
  defp append_response_part({parts, {:text, previous_part, chunks} = pending}, %{"text" => text} = part) do
    if text_part_mergeable?(previous_part, part),
      do: {parts, {:text, previous_part, [text | chunks]}},
      else: {close_response_part(parts, pending), {:text, Map.delete(part, "text"), [text]}}
  end

  defp append_response_part({parts, pending}, %{"text" => text} = part),
    do: {close_response_part(parts, pending), {:text, Map.delete(part, "text"), [text]}}

  defp append_response_part({parts, pending}, part), do: {close_response_part(parts, pending), {:part, part}}

  defp finish_response_parts({parts, pending}), do: parts |> close_response_part(pending) |> Enum.reverse()

  defp close_response_part(parts, nil), do: parts
  defp close_response_part(parts, pending), do: [materialize_response_part(pending) | parts]

  defp materialize_response_part({:text, part, chunks}) do
    Map.put(part, "text", chunks |> Enum.reverse() |> IO.iodata_to_binary())
  end

  defp materialize_response_part({:part, part}), do: part

  defp text_part_mergeable?(left, right) do
    Map.get(left, "thought") == Map.get(right, "thought") and
      not Map.has_key?(right, "thoughtSignature")
  end

  defp event_parts(%{"data" => %{"candidates" => candidates}}) when is_list(candidates) do
    candidates
    |> Enum.flat_map(fn candidate ->
      get_in(candidate, ["content", "parts"]) || []
    end)
  end

  defp event_parts(_event), do: []
end
