defmodule BeamWeaver.Tracing.Exporter do
  @moduledoc """
  Exporter behaviour for BeamWeaver trace events.
  """

  alias BeamWeaver.Tracing.Run

  @type event :: :started | :ok | :error

  @callback export(event(), Run.t(), keyword()) :: :ok | {:error, term()}
end
