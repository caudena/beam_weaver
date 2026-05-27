defmodule BeamWeaver.OpenAI.Streaming.Response do
  @moduledoc false

  alias BeamWeaver.OpenAI.Streaming.Shared
  alias BeamWeaver.OpenAI.Streaming.SSE

  @spec response(binary() | term()) :: map()
  def response(body) when is_binary(body) do
    parsed_events = SSE.events(body)

    parsed_events
    |> Shared.terminal_response()
    |> Map.merge(%{"output" => output_items(parsed_events)})
    |> Shared.reject_nil_values()
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
          %{
            "item_id" => data["item_id"],
            "output_index" => data["output_index"],
            "partial_image_index" => data["partial_image_index"],
            "partial_image_b64" => partial_image_b64
          }
          |> Shared.reject_nil_values()
        ]

      _event ->
        []
    end)
  end

  def partial_images(_body), do: []

  defp completed_output(parsed_events) do
    parsed_events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"data" => %{"response" => %{"output" => output}}} when is_list(output) ->
        Enum.map(output, &Shared.stringify_keys/1)

      _event ->
        nil
    end)
    |> case do
      nil -> []
      output -> output
    end
  end

  defp reconstruct_output_items(parsed_events) do
    parsed_events
    |> Enum.reduce(%{items: %{}, item_indexes: %{}}, &apply_output_event/2)
    |> Map.fetch!(:items)
    |> Enum.sort_by(fn {index, _item} -> index end)
    |> Enum.map(fn {_index, item} -> finalize_item(item) end)
  end

  defp apply_output_event(%{"data" => %{"type" => "response.output_item.added"} = data}, state) do
    put_item(state, data["output_index"], data["item"])
  end

  defp apply_output_event(%{"data" => %{"type" => "response.output_item.done"} = data}, state) do
    put_item(state, data["output_index"], data["item"])
  end

  defp apply_output_event(%{"data" => %{"type" => "response.content_part.added"} = data}, state) do
    update_content_part(state, data, data["part"])
  end

  defp apply_output_event(%{"data" => %{"type" => "response.content_part.done"} = data}, state) do
    update_content_part(state, data, data["part"])
  end

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

  defp apply_output_event(
         %{"data" => %{"type" => "response.reasoning_summary_part.added"} = data},
         state
       ) do
    update_summary_part(state, data, data["part"])
  end

  defp apply_output_event(
         %{"data" => %{"type" => "response.reasoning_summary_part.done"} = data},
         state
       ) do
    update_summary_part(state, data, data["part"])
  end

  defp apply_output_event(
         %{
           "data" =>
             %{
               "type" => "response.reasoning_summary_text.delta",
               "delta" => delta
             } = data
         },
         state
       )
       when is_binary(delta) do
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
               "type" => "response.reasoning_summary_text.done",
               "text" => text
             } = data
         },
         state
       )
       when is_binary(text) do
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
      |> put_optional("name", data["name"])
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
    existing_item =
      state.items
      |> Map.get(index, %{})
      |> Shared.stringify_keys()

    item =
      item
      |> Shared.stringify_keys()
      |> preserve_existing_list(existing_item, "partial_images")

    state
    |> put_in([:items, index], item)
    |> remember_item_index(item["id"], index)
  end

  defp put_item(state, _index, _item), do: state

  defp update_item(state, index, fun) when is_integer(index) and is_function(fun, 1) do
    item =
      state.items
      |> Map.get(index, %{})
      |> Shared.stringify_keys()
      |> fun.()
      |> Shared.stringify_keys()

    state
    |> put_in([:items, index], item)
    |> remember_item_index(item["id"], index)
  end

  defp update_item(state, _index, _fun), do: state

  defp partial_image(data) do
    %{
      "partial_image_index" => data["partial_image_index"],
      "partial_image_b64" => data["partial_image_b64"]
    }
    |> Shared.reject_nil_values()
  end

  defp update_content_part(state, data, part) when is_map(part) do
    update_content_part(state, data, fn _current_part -> Shared.stringify_keys(part) end)
  end

  defp update_content_part(state, data, fun) when is_function(fun, 1) do
    update_item(state, item_index(state, data), fn item ->
      item = ensure_item(item, "message")
      content = Map.get(item, "content", [])
      content_index = Map.get(data, "content_index", 0)

      current_part =
        content
        |> Enum.at(content_index)
        |> empty_map_if_nil()

      Map.put(item, "content", put_indexed(content, content_index, fun.(current_part)))
    end)
  end

  defp update_summary_part(state, data, part) when is_map(part) do
    update_summary_part(state, data, fn _current_part -> Shared.stringify_keys(part) end)
  end

  defp update_summary_part(state, data, fun) when is_function(fun, 1) do
    update_item(state, item_index(state, data), fn item ->
      item = ensure_item(item, "reasoning")
      summary = Map.get(item, "summary", [])
      summary_index = Map.get(data, "summary_index", 0)

      current_part =
        summary
        |> Enum.at(summary_index)
        |> empty_map_if_nil()

      Map.put(item, "summary", put_indexed(summary, summary_index, fun.(current_part)))
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
    |> List.replace_at(index, Shared.stringify_keys(value))
  end

  defp put_indexed(list, _index, _value), do: list

  defp extend_to(list, size) when length(list) >= size, do: list
  defp extend_to(list, size), do: list ++ List.duplicate(nil, size - length(list))

  defp remember_item_index(state, id, index) when is_binary(id) and is_integer(index) do
    put_in(state, [:item_indexes, id], index)
  end

  defp remember_item_index(state, _id, _index), do: state

  defp ensure_item(item, type) when is_map(item) do
    item
    |> Shared.stringify_keys()
    |> Map.put_new("type", type)
  end

  defp ensure_text_part(part) when is_map(part) do
    part
    |> Shared.stringify_keys()
    |> Map.put_new("type", "output_text")
    |> Map.put_new("text", "")
  end

  defp ensure_summary_part(part) when is_map(part) do
    part
    |> Shared.stringify_keys()
    |> Map.put_new("type", "summary_text")
    |> Map.put_new("text", "")
  end

  defp empty_map_if_nil(nil), do: %{}
  defp empty_map_if_nil(value), do: value

  defp finalize_item(item) do
    item
    |> Shared.stringify_keys()
    |> Map.update("content", nil, &compact_list/1)
    |> Map.update("summary", nil, &compact_list/1)
    |> Shared.reject_nil_values()
  end

  defp compact_list(value) when is_list(value), do: Enum.reject(value, &is_nil/1)
  defp compact_list(value), do: value

  defp preserve_existing_list(new_item, existing_item, key) do
    case Map.get(existing_item, key) do
      values when is_list(values) and values != [] -> Map.put(new_item, key, values)
      _missing -> new_item
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
