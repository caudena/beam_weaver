defmodule BeamWeaver.Telemetry.AdapterHelpers do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @spec adapter_name(term()) :: module() | String.t()
  def adapter_name(%{__struct__: module}), do: module
  def adapter_name(other), do: inspect(other)

  @spec metadata_get(map() | keyword() | term(), atom()) :: term()
  def metadata_get(metadata, key) when is_map(metadata), do: Map.get(metadata, key)
  def metadata_get(metadata, key) when is_list(metadata), do: Keyword.get(metadata, key)
  def metadata_get(_metadata, _key), do: nil

  @spec result_count(term()) :: non_neg_integer()
  def result_count(result) when is_list(result), do: length(result)
  def result_count({:ok, list}) when is_list(list), do: length(list)
  def result_count({:ok, _value}), do: 1
  def result_count(:ok), do: 1
  def result_count(:error), do: 0
  def result_count({:error, _error}), do: 0
  def result_count(_result), do: 1

  @spec sweep_count(term()) :: non_neg_integer()
  def sweep_count({:ok, count}) when is_integer(count), do: count
  def sweep_count(:ok), do: 1
  def sweep_count(_result), do: 0

  @spec result_type(term(), keyword()) :: atom()
  def result_type(result, opts \\ []) do
    miss_values = Keyword.get(opts, :miss_values, [])

    cond do
      match?({:error, _error}, result) -> :error
      Enum.any?(miss_values, &(&1 == result)) -> :miss
      true -> :ok
    end
  end

  @spec error_type(term()) :: atom() | String.t() | nil
  def error_type({:error, %Error{type: type}}), do: type
  def error_type({:error, %{type: type}}), do: type
  def error_type({:error, reason}), do: inspect(reason)
  def error_type(_result), do: nil
end
