defmodule BeamWeaver.Compaction do
  @moduledoc """
  Provider-neutral conversation compaction with application-owned persistence.

  The engine accepts one validated, ordered conversation lane and returns a
  pure `BeamWeaver.Compaction.Result`. It may call the request's renderer and
  summarizer functions, but it starts no process and owns no provider,
  database, checkpoint pointer, or recovery loop.

  Applications must persist and activate a returned checkpoint under their own
  transaction and fencing rules. A returned checkpoint is only a candidate;
  it is not durable or current until that application transaction succeeds.

  Possible successful result statuses are:

    * `:skipped` — no checkpoint and no summary call;
    * `:pruned` — deterministic tool projection produced a checkpoint without
      a summary call;
    * `:compacted` — portable semantic summarization produced a checkpoint.

  See the **Application-Owned Compaction** guide for event construction,
  callback contracts, persistence, and recovery examples.
  """

  alias BeamWeaver.Compaction.{Engine, Request, Result}
  alias BeamWeaver.Core.Error

  @doc """
  Compacts one application-owned conversation lane.

  `agent_state` is the existing BeamWeaver agent-state slot. This engine does
  not currently read or mutate it; applications without agent state pass
  `%{}`.

  The request is validated before callbacks run. Errors, including callback
  exceptions and ineffective compaction, are returned as
  `BeamWeaver.Core.Error` values.
  """
  @spec compact(map(), Request.t() | map()) :: {:ok, Result.t()} | {:error, Error.t()}
  def compact(agent_state, request), do: Engine.compact(agent_state, request)
end
