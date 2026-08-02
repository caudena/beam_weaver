defmodule BeamWeaver.OpenAI.Streaming.Messages do
  @moduledoc false

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error, as: CoreError
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.OpenAI.Streaming.Lifecycle
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
    |> positioned_message_chunks()
    |> Enum.map(fn {_position, chunk} -> chunk end)
  end

  def message_chunks(_body), do: []

  @spec typed_events(binary() | [map()] | term()) :: [BeamWeaver.Stream.Envelope.t()]
  def typed_events(body) when is_binary(body) do
    body
    |> BeamWeaver.OpenAI.Streaming.SSE.events()
    |> typed_events()
  end

  def typed_events(parsed_events) when is_list(parsed_events) do
    message_events =
      parsed_events
      |> positioned_message_chunks()
      |> Enum.flat_map(fn {position, chunk} ->
        chunk
        |> chunk_to_events()
        |> Enum.map(&{position, &1})
      end)

    {event_groups, _remaining_message_events} =
      parsed_events
      |> Enum.with_index()
      |> Enum.map_reduce(message_events, fn {event, position}, pending_message_events ->
        {current_message_events, remaining_message_events} =
          Enum.split_while(pending_message_events, fn {event_position, _event} ->
            event_position == position
          end)

        events =
          Enum.map(current_message_events, fn {_position, event} -> event end) ++
            custom_events(event) ++ done_event(event)

        {events, remaining_message_events}
      end)

    event_groups
    |> List.flatten()
    |> Enum.map(fn event ->
      Stream.envelope(event, metadata: %{provider: :openai})
    end)
  end

  def typed_events(_body), do: []

  defp positioned_message_chunks(parsed_events) do
    parsed_events
    |> Enum.with_index()
    |> Enum.reduce(%{chunks: [], event_index: nil, item_call_ids: %{}, item_names: %{}}, fn
      {event, event_index}, state ->
        apply_message_chunk_event(event, %{state | event_index: event_index})
    end)
    |> Map.fetch!(:chunks)
    |> Enum.reverse()
  end

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
             "type" => type,
             "item_id" => item_id,
             "delta" => delta
           }
         },
         state
       )
       when type in ["response.reasoning_summary_text.delta", "response.reasoning_text.delta"] and
              is_binary(delta) do
    emit_message_chunk(
      state,
      Messages.ai_chunk([ContentBlock.reasoning(delta)], id: item_id)
    )
  end

  defp apply_message_chunk_event(
         %{
           "data" => %{
             "type" => type,
             "delta" => delta
           }
         },
         state
       )
       when type in ["response.reasoning_summary_text.delta", "response.reasoning_text.delta"] and
              is_binary(delta) do
    emit_message_chunk(state, Messages.ai_chunk([ContentBlock.reasoning(delta)]))
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

  defp emit_message_chunk(state, chunk) do
    Map.update!(state, :chunks, &[{state.event_index, chunk} | &1])
  end

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

  defp custom_events(%{"data" => data} = event) when is_map(data) do
    if Lifecycle.typed_custom_event?(data) do
      [%Events.Custom{payload: event, metadata: custom_event_metadata(data)}]
    else
      []
    end
  end

  defp custom_events(_event), do: []

  defp custom_event_metadata(data) do
    item = if is_map(data["item"]), do: data["item"], else: %{}

    %{
      event_type: data["type"],
      item_id: data["item_id"] || item["id"],
      output_index: data["output_index"],
      output_item_type: item["type"],
      sequence_number: data["sequence_number"],
      status: data["status"] || item["status"]
    }
    |> reject_nil_values()
  end

  defp done_event(%{"data" => %{"type" => "response.completed", "response" => response}}) do
    [%Events.Done{result: response, usage: response["usage"]}]
  end

  defp done_event(%{
         "data" => %{"type" => "response.incomplete", "response" => response} = data
       })
       when is_map(response) do
    [
      %Events.Done{
        result: response,
        usage: response["usage"],
        metadata: terminal_metadata(data, response, "incomplete")
      }
    ]
  end

  defp done_event(%{"data" => %{"type" => "response.failed", "response" => response} = data})
       when is_map(response) do
    metadata = terminal_metadata(data, response, "failed")
    provider_error = if is_map(response["error"]), do: response["error"], else: %{}
    message = provider_error["message"] || "Model response failed"

    error =
      CoreError.new(:response_failed, message, %{
        event: data,
        response: response,
        status: metadata.status,
        usage: response["usage"]
      })

    [%Events.Error{error: error, metadata: metadata}]
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

  defp terminal_metadata(data, response, default_status) do
    %{
      event_type: data["type"],
      sequence_number: data["sequence_number"],
      status: response["status"] || default_status,
      usage: response["usage"]
    }
    |> reject_nil_values()
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
