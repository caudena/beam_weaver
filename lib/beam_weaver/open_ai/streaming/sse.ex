defmodule BeamWeaver.OpenAI.Streaming.SSE do
  @moduledoc false

  @spec events(binary() | term()) :: [map()]
  def events(body), do: BeamWeaver.Provider.SSE.events(body)

  @spec process_chunk(binary(), binary() | term()) :: {[map()], binary()}
  def process_chunk(buffer, chunk), do: BeamWeaver.Provider.SSE.process_chunk(buffer, chunk)
end
