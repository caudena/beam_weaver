defmodule BeamWeaver.Graph.Channels.DeltaSnapshot do
  @moduledoc false

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}

  # A stored value, a snapshot's unwrapped. A snapshot saved before the
  # struct was registered loads as a map under its old key.
  @spec unwrap(term()) :: term()
  def unwrap(%__MODULE__{value: value}), do: value
  def unwrap(%{"__beam_weaver_delta_snapshot__" => value}), do: value
  def unwrap(%{__beam_weaver_delta_snapshot__: value}), do: value
  def unwrap(value), do: value

  @spec snapshot?(term()) :: boolean()
  def snapshot?(%__MODULE__{}), do: true
  def snapshot?(%{"__beam_weaver_delta_snapshot__" => _value}), do: true
  def snapshot?(%{__beam_weaver_delta_snapshot__: _value}), do: true
  def snapshot?(_value), do: false
end
