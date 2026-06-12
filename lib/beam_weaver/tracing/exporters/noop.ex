defmodule BeamWeaver.Tracing.Exporters.Noop do
  @moduledoc """
  No-op trace exporter.
  """

  @behaviour BeamWeaver.Tracing.Exporter

  @impl true
  def export(_event, _run, _opts), do: :ok
end
