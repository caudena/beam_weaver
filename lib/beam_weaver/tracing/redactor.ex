defmodule BeamWeaver.Tracing.Redactor do
  @moduledoc false

  @spec redact(term()) :: term()
  defdelegate redact(value), to: BeamWeaver.Transport.Redactor
end
