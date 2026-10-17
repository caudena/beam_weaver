defmodule BeamWeaver.Telemetry.AdapterEvent do
  @moduledoc false
  defstruct [
    :adapter,
    :operation,
    :namespace,
    :key,
    :thread_id,
    :checkpoint_ns,
    :checkpoint_id,
    :query,
    :filter,
    :k,
    :result,
    :error,
    metadata: %{}
  ]
end

defmodule BeamWeaver.Telemetry do
  @moduledoc false

  @spec emit([atom()], map(), struct() | map()) :: :ok
  def emit(event, measurements, metadata) when is_list(event) do
    metadata = metadata |> Map.delete(:__struct__) |> BeamWeaver.MapShape.compact([nil, :empty_map])
    :telemetry.execute(event, measurements, metadata)
  end
end
