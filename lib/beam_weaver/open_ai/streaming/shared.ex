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
