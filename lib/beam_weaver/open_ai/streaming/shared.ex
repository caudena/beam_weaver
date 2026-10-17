defmodule BeamWeaver.OpenAI.Streaming.Shared do
  @moduledoc false

  def terminal_response(parsed_events) do
    parsed_events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"data" => %{"response" => response}} when is_map(response) ->
        stringify_keys(response)

      _event ->
        nil
    end)
    |> case do
      nil -> %{}
      response -> response
    end
  end

  # After several built-in tool calls the API can report a later
  # `output_index` on an item's `done` events than on its `added` event. Each
  # item keeps the first `output_index` it was seen at, so all its events land
  # on one output item and one content block.
  @spec pin_output_indexes([map()]) :: [map()]
  def pin_output_indexes(parsed_events) when is_list(parsed_events) do
    {events, _pinned} =
      Enum.map_reduce(parsed_events, %{}, fn
        %{"data" => %{"output_index" => index} = data} = event, pinned when is_integer(index) ->
          case event_item_id(data) do
            nil ->
              {event, pinned}

            id ->
              pinned = Map.put_new(pinned, id, index)
              {%{event | "data" => %{data | "output_index" => Map.fetch!(pinned, id)}}, pinned}
          end

        event, pinned ->
          {event, pinned}
      end)

    events
  end

  defp event_item_id(%{"item" => %{} = item}), do: Map.get(item, "id") || Map.get(item, :id)
  defp event_item_id(%{"item_id" => id}) when is_binary(id), do: id
  defp event_item_id(_data), do: nil

  def stringify_keys(map) when is_map(map) do
    BeamWeaver.MapShape.stringify_keys(map)
  end

  def stringify_keys(value), do: value

  def stringify_value(value), do: BeamWeaver.MapShape.normalize_value(value)

  def decode_arguments(arguments) when is_binary(arguments) do
    case BeamWeaver.JSON.decode(arguments) do
      {:ok, decoded} -> decoded
      {:error, _error} -> arguments
    end
  end

  def decode_arguments(arguments), do: arguments

  def reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
