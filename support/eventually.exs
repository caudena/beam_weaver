defmodule BeamWeaver.TestSupport.Eventually do
  @moduledoc false

  @doc """
  Polls `predicate` until it returns a truthy value or `timeout` milliseconds
  pass, and returns whether it ever did.

  Use `assert eventually(fn -> ... end)` for state that settles asynchronously,
  instead of sleeping for a fixed time and hoping it was long enough.
  """
  def eventually(predicate, timeout \\ 5_000) when is_function(predicate, 0) do
    poll(predicate, System.monotonic_time(:millisecond) + timeout)
  end

  defp poll(predicate, deadline) do
    cond do
      predicate.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        poll(predicate, deadline)
    end
  end
end
