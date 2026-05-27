defmodule BeamWeaver.Graph.Execution.Cache do
  @moduledoc false

  alias BeamWeaver.Cache
  alias BeamWeaver.CachePolicy

  @spec key(map(), map()) :: {term(), term(), binary(), keyword()} | nil
  def key(%{cache: false}, _run), do: nil
  def key(%{cache: nil}, _run), do: nil

  def key(spec, run) do
    case cache_for(spec, run) do
      nil ->
        nil

      {cache, %CachePolicy{} = policy} ->
        namespace = {:graph_node, policy.namespace, run.compiled.name, spec.name}
        payload = CachePolicy.key(policy, {run.compiled.name, spec.name, run.state})

        {cache, namespace, Cache.stable_key(payload), [ttl: policy.ttl, metadata: policy.metadata]}

      cache ->
        namespace = {:graph_node, run.compiled.name, spec.name}
        payload = {run.compiled.name, spec.name, run.state}
        {cache, namespace, Cache.stable_key(payload), []}
    end
  end

  @spec lookup(term(), term()) :: {:hit, term()} | :miss | {:error, BeamWeaver.Core.Error.t()}
  def lookup(_compiled_cache, nil), do: :miss

  def lookup(_compiled_cache, {cache, namespace, key, opts}) do
    case Cache.lookup(cache, namespace, key, opts) do
      {:hit, value, _metadata} -> {:hit, value}
      other -> other
    end
  end

  @spec put(term(), term(), term()) :: :ok
  def put(_cache, nil, _value), do: :ok

  def put(_compiled_cache, {cache, namespace, key, opts}, value) do
    case Cache.put(cache, namespace, key, value, opts) do
      :ok -> :ok
      {:error, _error} -> :ok
    end
  end

  defp cache_for(%{cache: true}, %{compiled: %{cache: cache}}), do: cache

  defp cache_for(%{cache: %CachePolicy{} = policy}, %{compiled: %{cache: cache}}),
    do: {cache, policy}

  defp cache_for(%{cache: cache}, _run) when cache not in [true, false, nil], do: cache
  defp cache_for(_spec, _run), do: nil
end
