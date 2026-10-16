defmodule BeamWeaver.Memory.Store do
  @moduledoc """
  Behaviour for long-term memory stores.

  A store keeps items under a namespace (a list of strings) and a key, shared
  across threads and runs. Applications usually call it through
  `BeamWeaver.Memory`.
  """

  @type store :: struct()
  @type namespace :: [String.t()]
  @type key :: String.t()
  @type item :: BeamWeaver.Memory.Item.t()

  @callback put(store(), namespace(), key(), term(), keyword()) ::
              {:ok, item()} | {:error, term()}
  @callback get(store(), namespace(), key()) :: {:ok, item()} | :error | {:error, term()}
  @callback delete(store(), namespace(), key()) :: :ok | {:error, term()}
  @callback search(store(), namespace(), keyword()) :: [item()] | {:error, term()}
  @callback list_namespaces(store(), keyword()) :: [namespace()] | {:error, term()}
  @callback batch(store(), [struct()]) :: [term()] | {:error, term()}
end
