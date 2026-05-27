defmodule BeamWeaver.OpenAI.MessageParts do
  @moduledoc """
  Shared OpenAI content-block helpers.
  """

  def stringify_keys(map) when is_map(map), do: BeamWeaver.MapShape.stringify_keys(map)

  def stringify_value(value), do: BeamWeaver.MapShape.normalize_value(value)

  def reject_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  def data_url(mime_type, data), do: "data:#{mime_type};base64,#{data}"

  def audio_format("audio/" <> format), do: format
  def audio_format(format) when is_binary(format), do: format
  def audio_format(_format), do: "wav"
end
