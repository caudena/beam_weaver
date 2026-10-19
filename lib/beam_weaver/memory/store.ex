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

  @doc """
  Writes/replaces one value and metadata; returns {:ok, Memory.Item} or an error. ttl is minutes.
  """
  @callback put(store(), namespace(), key(), term(), keyword()) ::
              {:ok, item()} | {:error, term()}
  @doc """
  Returns {:ok, item}, :error for absence/expiry, or a storage error.
  """
  @callback get(store(), namespace(), key()) :: {:ok, item()} | :error | {:error, term()}
  @doc """
  Deletes one key; missing keys are ignored by the built-in adapters.
  """
  @callback delete(store(), namespace(), key()) :: :ok | {:error, term()}
  @doc """
  Searches a namespace prefix, including descendants. Returns items or an error; default page size is 10.
  """
  @callback search(store(), namespace(), keyword()) :: [item()] | {:error, term()}
  @doc """
  Lists namespaces with optional prefix, suffix, depth and pagination filters.
  """
  @callback list_namespaces(store(), keyword()) :: [namespace()] | {:error, term()}
  @doc """
  Executes validated operations in order and returns corresponding results; atomicity is adapter-specific.
  """
  @callback batch(store(), [struct()]) :: [term()] | {:error, term()}
end
