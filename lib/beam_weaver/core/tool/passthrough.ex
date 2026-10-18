defprotocol BeamWeaver.Core.Tool.Passthrough do
  @moduledoc false

  # A value a tool returns for the runtime that runs it to act on, such as a
  # graph's `Command`, rather than as its result: `Core.Tool` hands it on as
  # it is. Other values are false.
  @fallback_to_any true

  @spec passthrough?(term()) :: boolean()
  def passthrough?(value)
end

defimpl BeamWeaver.Core.Tool.Passthrough, for: Any do
  def passthrough?(_value), do: false
end
