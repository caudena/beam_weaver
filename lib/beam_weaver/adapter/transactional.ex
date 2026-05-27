defprotocol BeamWeaver.Adapter.Transactional do
  @moduledoc """
  Optional transaction capability for durable adapters.

  Adapters without a durable transaction boundary execute the function directly.
  """

  @fallback_to_any true

  @spec transaction(term(), (-> term()), keyword()) ::
          term() | {:error, BeamWeaver.Core.Error.t()}
  def transaction(adapter, fun, opts)
end

defimpl BeamWeaver.Adapter.Transactional, for: Any do
  def transaction(%{repo: repo}, fun, _opts) when is_function(fun, 0) and not is_nil(repo) do
    BeamWeaver.Adapters.EctoPostgres.transaction(repo, fun)
  end

  def transaction(_adapter, fun, _opts) when is_function(fun, 0), do: fun.()
end
