defmodule BeamWeaver.TestSupport.Conformance.CacheCase do
  @moduledoc """
  Shared ExUnit checks for `BeamWeaver.Cache` adapters.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Cache

      @beamweaver_cache Keyword.fetch!(opts, :cache)

      test "cache stores, reads, deletes, and clears namespaced entries" do
        cache = beamweaver_standard_value(@beamweaver_cache)

        assert :miss = Cache.lookup(cache, :standard, "a")
        assert :ok = Cache.put(cache, :standard, "a", %{value: 1}, metadata: %{source: "case"})
        assert {:hit, %{value: 1}, %{source: "case"}} = Cache.lookup(cache, :standard, "a")
        assert :ok = Cache.delete(cache, :standard, "a")
        assert :miss = Cache.lookup(cache, :standard, "a")

        assert :ok = Cache.put(cache, :standard, "b", "value")
        assert :ok = Cache.clear(cache, :standard)
        assert :miss = Cache.lookup(cache, :standard, "b")
      end

      defp beamweaver_standard_value(value) when is_function(value, 0), do: value.()
      defp beamweaver_standard_value(value), do: value
    end
  end
end
