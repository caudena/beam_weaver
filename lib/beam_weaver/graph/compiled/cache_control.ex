defmodule BeamWeaver.Graph.Compiled.CacheControl do
  @moduledoc false

  alias BeamWeaver.Cache
  alias BeamWeaver.Core.Error

  def clear_cache(compiled, opts) do
    cache = Keyword.get(opts, :cache, compiled.cache)
    namespace = Keyword.get(opts, :namespace)

    cond do
      Cache.adapter?(cache) ->
        Cache.clear(cache, namespace)

      cache in [nil, false, %{}] ->
        :ok

      true ->
        {:error,
         Error.new(:invalid_cache, "graph cache must be a BeamWeaver.Cache adapter", %{
           cache: inspect(cache)
         })}
    end
  end
end
