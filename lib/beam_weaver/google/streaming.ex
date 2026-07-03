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

  @spec typed_events([map()]) :: [Stream.Envelope.t()]
  def typed_events(events) when is_list(events) do
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

  @spec response_from_sse_body(binary() | map()) :: map()
  def response_from_sse_body(body) when is_binary(body) do
    body
    |> SSE.events()
    |> Enum.map(& &1["data"])
    |> merge_responses()
  end

  def response_from_sse_body(%{} = body), do: body

  defp merge_responses([]), do: %{}

  defp merge_responses(responses) do
    parts =
      responses
      |> Enum.flat_map(fn response ->
        get_in(response, ["candidates", Access.at(0), "content", "parts"]) || []
      end)
      |> merge_response_parts()

    final = List.last(responses) || %{}
    candidate = get_in(final, ["candidates", Access.at(0)]) || %{}
    content = %{"role" => "model", "parts" => parts}

    final
    |> Map.put("candidates", [Map.put(candidate, "content", content)])
  end

  defp merge_response_parts(parts) do
    parts
    |> Enum.reduce({[], nil}, fn
      %{"text" => ""}, acc ->
        acc

      %{"text" => text} = part, acc when is_binary(text) ->
        append_response_part(acc, part)

      part, acc when is_map(part) ->
        append_response_part(acc, part)

      _part, acc ->
        acc
    end)
    |> finish_response_parts()
  end

  defp append_response_part({parts, nil}, %{"text" => text} = part),
    do: {parts, {:text, Map.delete(part, "text"), [text]}}

  defp append_response_part({parts, nil}, part), do: {parts, {:part, part}}

  defp append_response_part({parts, previous_part}, %{"text" => text} = part) do
    case previous_part do
      {:text, previous_part, chunks} = pending ->
        if text_part_mergeable?(previous_part, part) do
          {parts, {:text, previous_part, [text | chunks]}}
        else
          {[materialize_response_part(pending) | parts], {:text, Map.delete(part, "text"), [text]}}
        end

      _other ->
        {[materialize_response_part(previous_part) | parts], {:text, Map.delete(part, "text"), [text]}}
    end
  end

  defp append_response_part({parts, previous_part}, part),
    do: {[materialize_response_part(previous_part) | parts], {:part, part}}

  defp finish_response_parts({parts, nil}), do: Enum.reverse(parts)
  defp finish_response_parts({parts, part}), do: Enum.reverse([materialize_response_part(part) | parts])

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

  def final_message_from_sse(body, opts \\ []) do
    body
    |> response_from_sse_body()
    |> Messages.response_to_message(opts)
  end
end
