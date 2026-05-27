defmodule BeamWeaver.Core.ID do
  @moduledoc """
  ID helpers for generated runtime values.
  """

  import Bitwise

  @type uuid :: String.t()

  @uuidv7_tail_bits 74
  @uuidv7_tail_mask (1 <<< @uuidv7_tail_bits) - 1
  @uuidv7_rand_a_bits 12
  @uuidv7_rand_b_bits 62
  @uuidv7_rand_a_mask (1 <<< @uuidv7_rand_a_bits) - 1
  @uuidv7_rand_b_mask (1 <<< @uuidv7_rand_b_bits) - 1
  @uuidv7_default_state {__MODULE__, :uuidv7_default_state}
  @uuidv7_explicit_state {__MODULE__, :uuidv7_explicit_state}
  @max_uuidv7_ms (1 <<< 48) - 1

  @doc """
  Generates an RFC 9562 UUIDv7 identifier.

  The first 48 bits are the Unix timestamp in milliseconds. The remaining
  UUIDv7 tail is cryptographically random for each new millisecond and uses a
  randomly incremented counter for same-millisecond monotonicity in one process.
  """
  @spec uuidv7() :: uuid()
  def uuidv7 do
    System.system_time(:millisecond)
    |> next_uuidv7_tail(@uuidv7_default_state, true)
    |> encode_uuidv7()
  end

  @doc """
  Generates an RFC 9562 UUIDv7 identifier for a supplied timestamp.

  Values in the current Unix nanosecond range are normalized to milliseconds so
  callers can pass `System.system_time(:nanosecond)` without losing the UUIDv7
  timestamp prefix.
  """
  @spec uuidv7(non_neg_integer()) :: uuid()
  def uuidv7(timestamp) when is_integer(timestamp) and timestamp >= 0 do
    timestamp
    |> normalize_uuidv7_timestamp()
    |> next_uuidv7_tail(@uuidv7_explicit_state, false)
    |> encode_uuidv7()
  end

  defp normalize_uuidv7_timestamp(timestamp) when timestamp > @max_uuidv7_ms,
    do: div(timestamp, 1_000_000)

  defp normalize_uuidv7_timestamp(timestamp), do: timestamp

  defp next_uuidv7_tail(timestamp_ms, key, clamp_to_last?) do
    timestamp_ms = timestamp_ms &&& @max_uuidv7_ms

    {last_timestamp, last_tail} = Process.get(key) || {-1, random_uuidv7_tail()}

    {timestamp_ms, tail} =
      cond do
        timestamp_ms > last_timestamp ->
          {timestamp_ms, random_uuidv7_tail()}

        clamp_to_last? ->
          next_monotonic_uuidv7_tail(last_timestamp, last_tail)

        timestamp_ms == last_timestamp ->
          {timestamp_ms, increment_uuidv7_tail!(last_tail)}

        true ->
          {timestamp_ms, random_uuidv7_tail()}
      end

    Process.put(key, {timestamp_ms, tail})
    {timestamp_ms, tail}
  end

  defp random_uuidv7_tail do
    <<tail::@uuidv7_tail_bits, _rest::6>> = :crypto.strong_rand_bytes(10)
    tail
  end

  defp next_monotonic_uuidv7_tail(timestamp_ms, tail) do
    case increment_uuidv7_tail(tail) do
      {:ok, next_tail} ->
        {timestamp_ms, next_tail}

      :overflow ->
        timestamp_ms = wait_for_next_millisecond(timestamp_ms)
        {timestamp_ms, random_uuidv7_tail()}
    end
  end

  defp increment_uuidv7_tail!(tail) do
    case increment_uuidv7_tail(tail) do
      {:ok, next_tail} ->
        next_tail

      :overflow ->
        raise ArgumentError, "UUIDv7 monotonic counter exhausted for supplied timestamp"
    end
  end

  defp increment_uuidv7_tail(tail) do
    increment = random_uuidv7_increment()

    if tail <= @uuidv7_tail_mask - increment do
      {:ok, tail + increment}
    else
      :overflow
    end
  end

  defp random_uuidv7_increment do
    <<increment::16>> = :crypto.strong_rand_bytes(2)
    increment + 1
  end

  defp wait_for_next_millisecond(last_timestamp_ms) do
    timestamp_ms = System.system_time(:millisecond) &&& @max_uuidv7_ms

    if timestamp_ms > last_timestamp_ms do
      timestamp_ms
    else
      Process.sleep(1)
      wait_for_next_millisecond(last_timestamp_ms)
    end
  end

  defp encode_uuidv7({timestamp, tail}) do
    rand_a = tail >>> @uuidv7_rand_b_bits &&& @uuidv7_rand_a_mask
    rand_b = tail &&& @uuidv7_rand_b_mask

    <<a::32, b::16, c::16, d::16, e::48>> =
      <<timestamp::48, 0x7::4, rand_a::@uuidv7_rand_a_bits, 0b10::2, rand_b::@uuidv7_rand_b_bits>>

    [
      Base.encode16(<<a::32>>, case: :lower),
      Base.encode16(<<b::16>>, case: :lower),
      Base.encode16(<<c::16>>, case: :lower),
      Base.encode16(<<d::16>>, case: :lower),
      Base.encode16(<<e::48>>, case: :lower)
    ]
    |> Enum.join("-")
  end
end
