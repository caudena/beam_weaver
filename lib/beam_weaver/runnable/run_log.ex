defmodule BeamWeaver.Runnable.RunLogPatch do
  @moduledoc false
  defstruct ops: []
end

defmodule BeamWeaver.Runnable.RunLog do
  @moduledoc false
  defstruct id: nil, logs: %{}, streamed_output: [], final_output: nil, error: nil
end
