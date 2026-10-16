defmodule BeamWeaver.Graph.Channels.DeltaSnapshot do
  @moduledoc false

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}
end
