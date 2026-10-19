defmodule BeamWeaver.Tracing.Exporter do
  @moduledoc """
  Exporter behaviour for BeamWeaver trace events.

  `export/3` gets each run, already redacted, when it starts (`:started`) and
  when it ends (`:ok` or `:error`), in the process of the run. When that
  process exits before the run ends, such as a tool task killed at its
  timeout, the exporter the run started with gets its `:error` event from
  another process, with `error: %{kind: :exit, reason: ...}`.
  """

  alias BeamWeaver.Tracing.Run

  @type event :: :started | :ok | :error

  @callback export(event(), Run.t(), keyword()) :: :ok | {:error, term()}
end
