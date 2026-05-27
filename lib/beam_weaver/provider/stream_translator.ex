defmodule BeamWeaver.Provider.StreamTranslator do
  @moduledoc """
  Behaviour for converting provider stream events into BeamWeaver stream items.
  """

  alias BeamWeaver.Core.Error

  @callback decode_events([map()], keyword()) :: [term()]
  @callback final_message([term()], keyword()) :: {:ok, term()} | {:error, Error.t()}

  @optional_callbacks final_message: 2
end
