defmodule BeamWeaver.OpenAI.Streaming.Messages do
  @moduledoc false

  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

  @spec message_chunks(binary() | [map()] | term()) :: [term()]
  def message_chunks(body) when is_binary(body) do
    body
    |> BeamWeaver.OpenAI.Streaming.SSE.events()
    |> message_chunks()
  end

  def message_chunks(parsed_events) when is_list(parsed_events) do
    parsed_events
    |> Enum.reduce(
      %{chunks: [], item_call_ids: %{}, item_names: %{}},
      &apply_message_chunk_event/2
    )
    |> Map.fetch!(:chunks)
    |> Enum.reverse()
  end

  def message_chunks(_body), do: []

  @spec typed_events(binary() | [map()] | term()) :: [BeamWeaver.Stream.Envelope.t()]
  def typed_events(body) when is_binary(body) do
    body
    |> BeamWeaver.OpenAI.Streaming.SSE.events()
    |> typed_events()
  end

  def typed_events(parsed_events) when is_list(parsed_events) do
    chunk_events =
      parsed_events
      |> message_chunks()
      |> Enum.flat_map(&chunk_to_events/1)

    done_events =
      parsed_events
      |> Enum.flat_map(&done_event/1)

    (chunk_events ++ done_events)
    |> Enum.map(&Stream.envelope(&1, metadata: %{provider: :openai}))
  end

  def typed_events(_body), do: []

  defp apply_message_chunk_event(
         %{
           "data" =>
             %{
               "type" => "response.output_item.added",
               "item" => %{"type" => "function_call"} = item
             } = data
         },
         state
       ) do
    item_id = item["id"]
    call_id = item["call_id"] || item_id
    name = item["name"]

    state
    |> put_in([:item_call_ids, item_id], call_id)
    |> put_in([:item_names, item_id], name)
    |> emit_message_chunk(
      Messages.ai_chunk("",
        tool_call_chunks: [
          Messages.tool_call_chunk(id: call_id, index: data["output_index"], name: name, args: "")
        ]
      )
    )
  end

  defp apply_message_chunk_event(
         %{
           "data" =>
             %{
               "type" => "response.function_call_arguments.delta",
               "item_id" => item_id,
               "delta" => delta
             } = data
         },
         state
       )
       when is_binary(delta) do
    call_id = Map.get(state.item_call_ids, item_id, item_id)
    name = Map.get(state.item_names, item_id, data["name"])

    emit_message_chunk(
      state,
      Messages.ai_chunk("",
        tool_call_chunks: [
          Messages.tool_call_chunk(
            id: call_id,
            index: data["output_index"],
            name: name,
            args: delta
          )
        ]
      )
    )
  end

  defp apply_message_chunk_event(
         %{
           "data" => %{
             "type" => "response.output_text.delta",
             "item_id" => item_id,
             "delta" => delta
           }
         },
         state
       )
       when is_binary(delta) do
    emit_message_chunk(state, Messages.ai_chunk(delta, id: item_id))
  end

  defp apply_message_chunk_event(
         %{
           "data" => %{
             "type" => "response.reasoning_summary_text.delta",
             "item_id" => item_id,
             "delta" => delta
           }
         },
         state
       )
       when is_binary(delta) do
    emit_message_chunk(
      state,
      Messages.ai_chunk([%{type: :reasoning, text: delta}], id: item_id)
    )
  end

  defp apply_message_chunk_event(
         %{
           "data" => %{
             "type" => "response.reasoning_summary_text.delta",
             "delta" => delta
           }
         },
         state
       )
       when is_binary(delta) do
    emit_message_chunk(state, Messages.ai_chunk([%{type: :reasoning, text: delta}]))
  end

  defp apply_message_chunk_event(%{"data" => %{"choices" => choices}}, state)
       when is_list(choices) do
    Enum.reduce(choices, state, fn choice, acc ->
      delta = choice["delta"] || %{}

      acc =
        if is_binary(delta["content"]) do
          emit_message_chunk(acc, Messages.ai_chunk(delta["content"]))
        else
          acc
        end

      delta
      |> Map.get("tool_calls", [])
      |> Enum.reduce(acc, fn call, acc ->
        function = call["function"] || %{}

        emit_message_chunk(
          acc,
          Messages.ai_chunk("",
            tool_call_chunks: [
              Messages.tool_call_chunk(
                id: call["id"],
                index: call["index"],
                name: function["name"],
                args: function["arguments"] || ""
              )
            ]
          )
        )
      end)
      |> maybe_emit_unknown_chat_delta(delta)
    end)
  end

  defp apply_message_chunk_event(_event, state), do: state

  defp emit_message_chunk(state, chunk), do: Map.update!(state, :chunks, &[chunk | &1])

  defp maybe_emit_unknown_chat_delta(state, delta) when is_map(delta) do
    unknown = Map.drop(delta, ["content", "tool_calls", "role"])

    if unknown == %{} do
      state
    else
      emit_message_chunk(state, Messages.ai_chunk("", metadata: %{openai_delta: unknown}))
    end
  end

  defp chunk_to_events(%Messages.AIChunk{} = chunk) do
    token_events =
      if is_binary(chunk.content) and chunk.content != "",
        do: [%Events.Token{text: chunk.content}],
        else: []

    tool_call_events =
      Enum.map(chunk.tool_call_chunks || [], &%Events.ToolCallChunk{chunk: &1})

    token_events ++ tool_call_events ++ [%Events.MessageChunk{chunk: chunk}]
  end

  defp chunk_to_events(chunk), do: [%Events.MessageChunk{chunk: chunk}]

  defp done_event(%{"data" => %{"type" => "response.completed", "response" => response}}) do
    [%Events.Done{result: response, usage: response["usage"]}]
  end

  defp done_event(%{"data" => %{"usage" => usage} = data}) when is_map(usage) do
    [%Events.Done{result: data, usage: usage}]
  end

  defp done_event(%{"data" => %{"choices" => choices}}) when is_list(choices) do
    if Enum.any?(choices, &(get_in(&1, ["finish_reason"]) != nil)),
      do: [%Events.Done{result: nil}],
      else: []
  end

  defp done_event(_event), do: []
end
