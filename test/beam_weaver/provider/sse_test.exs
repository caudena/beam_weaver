defmodule BeamWeaver.Provider.SSETest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Provider.SSE

  test "process_chunk handles split CRLF boundaries and data prefixes" do
    {events, buffer} = SSE.process_chunk("", "event: message\r")
    assert events == []

    {events, buffer} = SSE.process_chunk(buffer, "\ndata")
    assert events == []

    {events, buffer} = SSE.process_chunk(buffer, ": {\"ok\":true}\r\n\r\n")
    assert buffer == ""
    assert events == [%{"event" => "message", "data" => %{"ok" => true}}]
  end

  test "process_chunk buffers partial JSON until the event terminator arrives" do
    {events, buffer} = SSE.process_chunk("", "data: {\"delta\":\"hel")
    assert events == []

    {events, buffer} = SSE.process_chunk(buffer, "lo\"}\n\n")
    assert buffer == ""
    assert events == [%{"event" => nil, "data" => %{"delta" => "hello"}}]
  end

  test "process_chunk joins multiple data lines and skips DONE sentinels" do
    body = """
    event: split
    data: {"items":[1,
    data: 2]}

    data: [DONE]

    """

    assert {[%{"event" => "split", "data" => %{"items" => [1, 2]}}], ""} =
             SSE.process_chunk("", body)
  end

  test "events ignores invalid leftover buffers" do
    assert SSE.events("data: {not-json") == []
  end
end
