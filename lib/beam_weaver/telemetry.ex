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

defmodule BeamWeaver.Telemetry.WeaveScopeEvent do
  @moduledoc false
  defstruct [
    :operation,
    :queue,
    :run_id,
    :trace_id,
    :attempts,
    :reason,
    :result,
    :error,
    metadata: %{}
  ]
end

defmodule BeamWeaver.Telemetry do
  @moduledoc """
  Thin helper for typed BeamWeaver telemetry metadata.
  """

  alias BeamWeaver.Telemetry.AdapterEvent
  alias BeamWeaver.Telemetry.WeaveScopeEvent

  @spec emit([atom()], map(), struct() | map()) :: :ok
  def emit(event, measurements, metadata) when is_list(event) do
    if Code.ensure_loaded?(:telemetry) do
      :telemetry.execute(event, measurements, to_map(metadata))
    end

    :ok
  end

  @spec to_map(struct() | map()) :: map()
  def to_map(%AdapterEvent{} = event), do: event |> Map.from_struct() |> clean()
  def to_map(%WeaveScopeEvent{} = event), do: event |> Map.from_struct() |> clean()
  def to_map(%{__struct__: _module} = struct), do: struct |> Map.from_struct() |> clean()
  def to_map(map) when is_map(map), do: clean(map)
  def to_map(_value), do: %{}

  defp clean(map) do
    map
    |> Enum.reject(fn
      {_key, nil} -> true
      {_key, value} when is_map(value) and map_size(value) == 0 -> true
      _entry -> false
    end)
    |> Map.new()
  end
end
