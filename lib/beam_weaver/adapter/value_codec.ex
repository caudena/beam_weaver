defmodule BeamWeaver.Adapter.ValueCodec do
  @moduledoc """
  Shared safe value encoding boundary for durable adapters.

  It wraps `BeamWeaver.Serialization` so adapters do not each invent their own
  tagged JSON policy.
  """

  alias BeamWeaver.Serialization

  @spec dump(term(), keyword()) :: {:ok, binary()} | {:error, BeamWeaver.Core.Error.t()}
  def dump(value, opts \\ []) do
    Serialization.dump(value, serialization: serialization(opts))
  end

  @spec load(binary(), keyword()) :: {:ok, term()} | {:error, BeamWeaver.Core.Error.t()}
  def load(value, opts \\ []) do
    Serialization.load(value, serialization: serialization(opts))
  end

  @spec dump_json_value(term(), keyword()) :: {:ok, term()} | {:error, BeamWeaver.Core.Error.t()}
  def dump_json_value(value, opts \\ []) do
    Serialization.dump_json_value(value, serialization: serialization(opts))
  end

  @spec load_json_value(term(), keyword()) :: {:ok, term()} | {:error, BeamWeaver.Core.Error.t()}
  def load_json_value(value, opts \\ []) do
    Serialization.load_json_value(value, serialization: serialization(opts))
  end

  defp serialization(opts) do
    Keyword.get(opts, :serialization, opts)
  end
end
