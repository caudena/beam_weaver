defmodule BeamWeaver.Graph.Node do
  @moduledoc """
  Behaviour for module-backed graph nodes.
  """

  @callback invoke(map(), BeamWeaver.Graph.Runtime.t()) :: term()
  @callback input_schema(term()) :: map() | nil
  @callback output_schema(term()) :: map() | nil
  @callback destinations(term()) :: [atom() | String.t()]
  @callback metadata(term()) :: map()
  @optional_callbacks input_schema: 1, output_schema: 1, destinations: 1, metadata: 1
end
