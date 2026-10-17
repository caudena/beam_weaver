defprotocol BeamWeaver.Adapter.Sweepable do
  @moduledoc """
  Optional capability for adapters that can remove expired records.

  This keeps cleanup out of required runtime behaviours while still giving
  facades a uniform way to call sweeps when an adapter supports them.
  """

  @fallback_to_any true

  @spec sweep_expired(term(), keyword()) ::
          {:ok, non_neg_integer()} | :ok | {:error, BeamWeaver.Core.Error.t()}
  def sweep_expired(adapter, opts)
end

defimpl BeamWeaver.Adapter.Sweepable, for: BeamWeaver.Cache.ETS do
  def sweep_expired(cache, opts), do: BeamWeaver.Cache.ETS.sweep_expired(cache, opts)
end

defimpl BeamWeaver.Adapter.Sweepable, for: BeamWeaver.Cache.Ecto do
  def sweep_expired(cache, opts), do: BeamWeaver.Cache.Ecto.sweep_expired(cache, opts)
end

defimpl BeamWeaver.Adapter.Sweepable, for: BeamWeaver.Memory.ETS do
  def sweep_expired(store, opts), do: BeamWeaver.Memory.ETS.sweep_expired(store, opts)
end

defimpl BeamWeaver.Adapter.Sweepable, for: BeamWeaver.Memory.Ecto do
  def sweep_expired(store, opts), do: BeamWeaver.Memory.Ecto.sweep_expired(store, opts)
end

defimpl BeamWeaver.Adapter.Sweepable, for: Any do
  alias BeamWeaver.Core.Error

  def sweep_expired(adapter, _opts) do
    {:error,
     Error.new(:unsupported_operation, "adapter does not support sweeping expired records", %{
       adapter: inspect(adapter)
     })}
  end
end
