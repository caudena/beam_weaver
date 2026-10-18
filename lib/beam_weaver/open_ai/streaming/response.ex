defmodule BeamWeaver.OpenAI.Streaming.Response do
  @moduledoc false

  import BeamWeaver.MapShape, only: [put_present: 3, reject_nil_values: 1]

  alias BeamWeaver.OpenAI.Streaming.Lifecycle.State
  alias BeamWeaver.OpenAI.Streaming.Shared
  alias BeamWeaver.Provider.SSE

  @partial_image_fields ~w(partial_image_index partial_image_b64 size quality background output_format)

  @spec response(binary() | term()) :: map()
  def response(body) when is_binary(body) do
    parsed_events = SSE.events(body)

    parsed_events
    |> Shared.terminal_response()
    |> Map.merge(%{"output" => output_items(parsed_events)})
    |> reject_nil_values()
  end

  def response(_body), do: %{"output" => []}

  @spec output_items(binary() | [map()] | term()) :: [map()]
  def output_items(body) when is_binary(body) do
    body
    |> SSE.events()
    |> output_items()
  end

  def output_items(parsed_events) when is_list(parsed_events) do
    reconstructed = reconstruct_output_items(parsed_events)

    if reconstructed == [] do
      completed_output(parsed_events)
    else
      reconstructed
    end
  end

  def output_items(_body), do: []

  @spec partial_images(binary() | term()) :: [map()]
  def partial_images(body) when is_binary(body) do
    body
    |> SSE.events()
    |> Enum.flat_map(fn
      %{
        "data" =>
          %{
            "type" => "response.image_generation_call.partial_image",
            "partial_image_b64" => partial_image_b64
          } = data
      }
      when is_binary(partial_image_b64) ->
        [
          data
          |> Map.take(["item_id", "output_index", "sequence_number" | @partial_image_fields])
          |> reject_nil_values()
        ]

      _event ->
        []
    end)
  end

  def partial_images(_body), do: []

  defp completed_output(parsed_events) do
    parsed_events
    |> Enum.reverse()
    |> Enum.find_value([], fn
      %{"data" => %{"response" => %{"output" => output}}} when is_list(output) ->
        Enum.map(output, &Shared.stringify_keys/1)

      _event ->
        nil
    end)
  end

  defp reconstruct_output_items(parsed_events) do
    parsed_events
    |> Shared.pin_output_indexes()
    |> Enum.reduce(%{items: %{}, item_indexes: %{}}, &apply_output_event/2)
    |> Map.fetch!(:items)
    |> Enum.sort_by(fn {index, _item} -> index end)
    |> Enum.map(fn {_index, item} -> finalize_item(item) end)
  end

  defp apply_output_event(%{"data" => %{"type" => type} = data}, state)
       when type in ["response.output_item.added", "response.output_item.done"],
       do: put_item(state, data["output_index"], data["item"])

  defp apply_output_event(%{"data" => %{"type" => type} = data}, state)
       when type in ["response.content_part.added", "response.content_part.done"],
       do: update_content_part(state, data, data["part"])

  defp apply_output_event(
         %{"data" => %{"type" => "response.output_text.delta", "delta" => delta} = data},
         state
       )
       when is_binary(delta) do
    update_content_part(state, data, fn part ->
      part
      |> ensure_text_part()
      |> Map.update("text", delta, &(&1 <> delta))
    end)
  end

  defp apply_output_event(
         %{"data" => %{"type" => "response.output_text.done", "text" => text} = data},
         state
       )
       when is_binary(text) do
    update_content_part(state, data, fn part ->
      part
      |> ensure_text_part()
      |> Map.put("text", text)
    end)
  end

  defp apply_output_event(%{"data" => %{"type" => type} = data}, state)
       when type in ["response.reasoning_summary_part.added", "response.reasoning_summary_part.done"],
       do: update_summary_part(state, data, data["part"])

  defp apply_output_event(
         %{
           "data" =>
             %{
               "type" => type,
               "delta" => delta
             } = data
         },
         state
       )
       when type in ["response.reasoning_summary_text.delta", "response.reasoning_text.delta"] and
              is_binary(delta) do
    update_summary_part(state, data, fn part ->
      part
      |> ensure_summary_part()
      |> Map.update("text", delta, &(&1 <> delta))
    end)
  end

  defp apply_output_event(
         %{
           "data" =>
             %{
               "type" => type,
               "text" => text
             } = data
         },
         state
       )
       when type in ["response.reasoning_summary_text.done", "response.reasoning_text.done"] and
              is_binary(text) do
    update_summary_part(state, data, fn part ->
      part
      |> ensure_summary_part()
      |> Map.put("text", text)
    end)
  end

  defp apply_output_event(
         %{
           "data" =>
             %{
               "type" => "response.function_call_arguments.delta",
               "delta" => delta
             } = data
         },
         state
       )
       when is_binary(delta) do
    update_item(state, item_index(state, data), fn item ->
      item
      |> ensure_item("function_call")
      |> Map.update("arguments", delta, &(&1 <> delta))
    end)
  end

  defp apply_output_event(
         %{
           "data" =>
             %{
               "type" => "response.function_call_arguments.done",
               "arguments" => arguments
             } = data
         },
         state
       )
       when is_binary(arguments) do
    update_item(state, item_index(state, data), fn item ->
      item
      |> ensure_item("function_call")
      |> Map.put("arguments", arguments)
      |> put_present("name", data["name"])
    end)
  end

  defp apply_output_event(
         %{
           "data" =>
             %{
               "type" => "response.image_generation_call.partial_image",
               "partial_image_b64" => partial_image_b64
             } = data
         },
         state
       )
       when is_binary(partial_image_b64) do
    update_item(state, item_index(state, data), fn item ->
      item
      |> ensure_item("image_generation_call")
      |> Map.update("partial_images", [partial_image(data)], fn images ->
        images ++ [partial_image(data)]
      end)
    end)
  end

  defp apply_output_event(_event, state), do: state

  defp put_item(state, index, item) when is_integer(index) and is_map(item) do
    item =
      item
      |> Shared.stringify_keys()
      |> preserve_existing_list(Map.get(state.items, index, %{}), "partial_images")

    state
    |> put_in([:items, index], item)
    |> State.remember_item_index(item["id"], index)
  end

  defp put_item(state, _index, _item), do: state

  defp update_item(state, index, fun) when is_integer(index) and is_function(fun, 1) do
    item =
      state.items
      |> Map.get(index, %{})
      |> fun.()
      |> Shared.stringify_keys()

    state
    |> put_in([:items, index], item)
    |> State.remember_item_index(item["id"], index)
  end

  defp update_item(state, _index, _fun), do: state

  defp partial_image(data), do: data |> Map.take(@partial_image_fields) |> reject_nil_values()

  defp update_content_part(state, data, part), do: update_part(state, data, "message", "content", part)
  defp update_summary_part(state, data, part), do: update_part(state, data, "reasoning", "summary", part)

  defp update_part(state, data, type, key, part) when is_map(part),
    do: update_part(state, data, type, key, fn _current_part -> Shared.stringify_keys(part) end)

  defp update_part(state, data, type, key, fun) when is_function(fun, 1) do
    update_item(state, item_index(state, data), fn item ->
      item = ensure_item(item, type)
      parts = Map.get(item, key, [])
      index = Map.get(data, key <> "_index", 0)

      Map.put(item, key, put_indexed(parts, index, fun.(Enum.at(parts, index) || %{})))
    end)
  end

  defp item_index(_state, %{"output_index" => index}) when is_integer(index), do: index

  defp item_index(state, %{"item_id" => item_id}) when is_binary(item_id) do
    Map.get(state.item_indexes, item_id)
  end

  defp item_index(_state, _data), do: nil

  defp put_indexed(list, index, value) when is_list(list) and is_integer(index) and index >= 0 do
    list
    |> extend_to(index + 1)
    |> List.replace_at(index, value)
  end

  defp put_indexed(list, _index, _value), do: list

  defp extend_to(list, size) when length(list) >= size, do: list
  defp extend_to(list, size), do: list ++ List.duplicate(nil, size - length(list))

  defp ensure_item(item, type), do: Map.put_new(item, "type", type)

  defp ensure_text_part(part) when is_map(part),
    do: part |> Map.put_new("type", "output_text") |> Map.put_new("text", "")

  defp ensure_summary_part(part) when is_map(part),
    do: part |> Map.put_new("type", "summary_text") |> Map.put_new("text", "")

  defp finalize_item(item) do
    item
    |> Map.update("content", nil, &compact_list/1)
    |> Map.update("summary", nil, &compact_list/1)
    |> reject_nil_values()
  end

  defp compact_list(value) when is_list(value), do: Enum.reject(value, &is_nil/1)
  defp compact_list(value), do: value

  defp preserve_existing_list(new_item, existing_item, key) do
    case Map.get(existing_item, key) do
      values when is_list(values) and values != [] -> Map.put(new_item, key, values)
      _missing -> new_item
    end
  end
end
