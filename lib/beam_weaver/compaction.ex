defmodule BeamWeaver.Compaction do
  @moduledoc "Provider-neutral conversation compaction with application-owned persistence."

  alias BeamWeaver.Compaction.{Engine, Request, Result}
  alias BeamWeaver.Core.Error

  @spec compact(map(), Request.t() | map()) :: {:ok, Result.t()} | {:error, Error.t()}
  def compact(agent_state, request), do: Engine.compact(agent_state, request)
end
