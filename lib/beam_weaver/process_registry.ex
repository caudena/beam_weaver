defmodule BeamWeaver.ProcessRegistry do
  @moduledoc """
  OTP process lookup for BeamWeaver runtime processes.

  Runtime process lookup is isolated here so application processes have a
  single registry boundary.
  """

  @type key :: term()
  @type value :: term()

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: registry_name())
  end

  @doc """
  Returns the OTP registry name used for BeamWeaver runtime processes.
  """
  @spec registry_name() :: module()
  def registry_name, do: __MODULE__

  @doc """
  Registers the current process under `key`.
  """
  @spec register(key(), value()) :: {:ok, pid()} | {:error, {:already_registered, pid()}}
  def register(key, value \\ nil) do
    Registry.register(registry_name(), key, value)
  end

  @doc """
  Returns every process registered under `key`.
  """
  @spec lookup(key()) :: [{pid(), value()}]
  def lookup(key) do
    Registry.lookup(registry_name(), key)
  end

  @doc """
  Returns the single process registered under `key`.
  """
  @spec whereis(key()) :: {:ok, pid()} | :error
  def whereis(key) do
    case lookup(key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Unregisters the current process from `key`.
  """
  @spec unregister(key()) :: :ok
  def unregister(key) do
    Registry.unregister(registry_name(), key)
  end
end
