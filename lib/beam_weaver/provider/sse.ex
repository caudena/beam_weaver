defmodule BeamWeaver.Provider.SSE do
  @moduledoc false

  @spec events(binary() | term()) :: [map()]
  def events(body) when is_binary(body) do
    {events, _buffer} = process_chunk("", body <> "\n\n")
    events
  end

  def events(_body), do: []

  @spec process_chunk(binary(), binary() | term()) :: {[map()], binary()}
  def process_chunk(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    data = normalize_newlines(buffer <> chunk)
    parts = String.split(data, "\n\n", trim: false)

    {events, [remaining]} =
      parts
      |> Enum.split(-1)

    {Enum.flat_map(events, &parse_event/1), remaining}
  end

  def process_chunk(buffer, _chunk) when is_binary(buffer), do: {[], buffer}

  defp parse_event(event) do
    lines = String.split(event, "\n", trim: true)

    event_name =
      lines
      |> Enum.find_value(fn
        "event:" <> event -> String.trim(event)
        _line -> nil
      end)

    data =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&String.trim_leading(&1, "data:"))
      |> Enum.map_join("\n", &String.trim/1)

    if data in ["", "[DONE]"] do
      []
    else
      case BeamWeaver.JSON.decode(data) do
        {:ok, decoded} -> [%{"event" => event_name, "data" => decoded}]
        {:error, _error} -> []
      end
    end
  end

  defp normalize_newlines(data) do
    String.replace(data, "\r\n", "\n")
  end
end
