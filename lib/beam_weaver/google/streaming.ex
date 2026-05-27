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
    text =
      responses
      |> Enum.flat_map(&get_in(&1, ["candidates", Access.at(0), "content", "parts"]))
      |> Enum.flat_map(fn
        %{"text" => text} when is_binary(text) -> [text]
        _part -> []
      end)
      |> Enum.join("")

    final = List.last(responses) || %{}
    candidate = get_in(final, ["candidates", Access.at(0)]) || %{}
    content = %{"role" => "model", "parts" => if(text == "", do: [], else: [%{"text" => text}])}

    final
    |> Map.put("candidates", [Map.put(candidate, "content", content)])
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
