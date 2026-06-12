defmodule BeamWeaver.Tracing.Redactor do
  @moduledoc """
  Redacts secrets from trace inputs, outputs, metadata, usage, and errors.
  """

  @doc """
  Redacts the same secret shapes protected by transport redaction.
  """
  @spec redact(term()) :: term()
  def redact(value), do: BeamWeaver.Transport.Redactor.redact(value)
end
