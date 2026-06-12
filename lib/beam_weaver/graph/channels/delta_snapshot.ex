defmodule BeamWeaver.Graph.Channels.DeltaSnapshot do
  @moduledoc """
  Stored snapshot blob for `DeltaChannel`.

  Normal `DeltaChannel` checkpoints are missing. When the runtime decides a
  full snapshot is due, it stores this wrapper so restore can distinguish a
  deliberate delta snapshot from a legacy plain channel value.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}
end
