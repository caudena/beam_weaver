defmodule BeamWeaver.Core.IDTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ID

  @max_uuidv7_ms 281_474_976_710_655

  test "uuidv7 returns version 7 UUID strings" do
    assert ID.uuidv7() =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  test "uuidv7 lays out fields according to RFC 9562" do
    timestamp = 1_700_000_000_123
    uuid = ID.uuidv7(timestamp)

    <<unix_ts_ms::48, version::4, _rand_a::12, variant::2, _rand_b::62>> = uuid_bytes(uuid)

    assert unix_ts_ms == timestamp
    assert version == 7
    assert variant == 0b10
  end

  test "uuidv7 preserves the maximum 48-bit millisecond timestamp" do
    uuid = ID.uuidv7(@max_uuidv7_ms)

    <<unix_ts_ms::48, version::4, _rand_a::12, variant::2, _rand_b::62>> = uuid_bytes(uuid)

    assert unix_ts_ms == @max_uuidv7_ms
    assert version == 7
    assert variant == 0b10
  end

  test "uuidv7 preserves timestamp ordering across different millisecond values" do
    first = ID.uuidv7(1_700_000_000_000)
    second = ID.uuidv7(1_700_000_000_001)

    assert first < second
  end

  test "uuidv7 accepts nanosecond timestamps and preserves the millisecond prefix" do
    nanoseconds = 1_700_000_000_123_456_789
    uuid = ID.uuidv7(nanoseconds)

    assert uuid |> String.replace("-", "") |> String.slice(0, 12) |> String.to_integer(16) ==
             1_700_000_000_123
  end

  test "uuidv7 is monotonic within one process" do
    ids = Enum.map(1..1_000, fn _ -> ID.uuidv7() end)

    assert ids == Enum.sort(ids)
    assert Enum.uniq(ids) == ids
  end

  defp uuid_bytes(uuid) do
    uuid
    |> String.replace("-", "")
    |> Base.decode16!(case: :mixed)
  end
end
