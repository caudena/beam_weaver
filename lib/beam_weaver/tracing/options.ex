defmodule BeamWeaver.Tracing.Options do
  @moduledoc false

  @standard_keys [
    :thread_id,
    :user_id,
    :session_id,
    :execution_mode,
    :environment,
    :version
  ]
  @removed_metadata_keys ~w(agent_name agent_type)
  @secret_fragments ~w(api_key token secret password authorization)

  @spec name(term(), String.t() | atom()) :: String.t() | atom()
  def name(trace, default), do: trace_value(trace, :name) || default

  @spec metadata(map(), term()) :: map()
  def metadata(base, trace) do
    trace_map = trace_map(trace)

    base
    |> map_value()
    |> scrub_removed_metadata_keys()
    |> Map.merge(trace_map |> trace_value(:metadata) |> map_value() |> scrub_removed_metadata_keys())
    |> put_standard_fields(trace_map)
    |> put_custom_fields(trace_map)
  end

  @spec put_thread_id_config(map(), term()) :: map()
  def put_thread_id_config(config, trace) when is_map(config) do
    case trace_value(trace, :thread_id) do
      value when value in [nil, ""] ->
        config

      thread_id ->
        put_configurable_value(config, "thread_id", thread_id)
    end
  end

  def put_thread_id_config(config, _trace), do: config

  defp put_standard_fields(metadata, trace_map) do
    Enum.reduce(@standard_keys, metadata, fn key, acc ->
      case trace_value(trace_map, key) do
        value when value in [nil, ""] -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp put_custom_fields(metadata, trace_map) do
    fields =
      trace_map
      |> trace_value(:fields)
      |> custom_fields()
      |> Map.merge(custom_fields(trace_value(trace_map, :custom_fields)))

    if map_size(fields) == 0 do
      metadata
    else
      Map.put(metadata, :custom_fields, fields)
    end
  end

  defp custom_fields(value) when is_map(value) or is_list(value) do
    value
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      with key when is_binary(key) <- normalize_field_key(key),
           value when is_binary(value) <- normalize_field_value(value) do
        Map.put(acc, key, value)
      else
        _other -> acc
      end
    end)
  end

  defp custom_fields(_value), do: %{}

  defp normalize_field_key(key) do
    key = key |> to_string() |> String.trim()
    lower = String.downcase(key)

    cond do
      key == "" -> nil
      String.starts_with?(key, "__") -> nil
      lower in @removed_metadata_keys -> nil
      Enum.any?(@secret_fragments, &String.contains?(lower, &1)) -> nil
      true -> key
    end
  end

  defp normalize_field_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_field_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_field_value(value) when is_float(value), do: :erlang.float_to_binary(value, [:compact, decimals: 16])
  defp normalize_field_value(value) when is_boolean(value), do: to_string(value)
  defp normalize_field_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp normalize_field_value(_value), do: nil

  defp put_configurable_value(config, key, value) do
    {config_key, configurable} = configurable(config)

    if has_configurable_key?(configurable, key) do
      config
    else
      Map.put(config, config_key, Map.put(configurable, key, value))
    end
  end

  defp configurable(config) do
    cond do
      Map.has_key?(config, "configurable") -> {"configurable", map_value(Map.get(config, "configurable"))}
      Map.has_key?(config, :configurable) -> {:configurable, map_value(Map.get(config, :configurable))}
      true -> {"configurable", %{}}
    end
  end

  defp has_configurable_key?(configurable, key) do
    Map.has_key?(configurable, key) or Map.has_key?(configurable, String.to_atom(key))
  rescue
    ArgumentError -> Map.has_key?(configurable, key)
  end

  defp trace_value(trace, key), do: map_get(trace_map(trace), key)

  defp trace_map(trace) when is_list(trace), do: Map.new(trace)
  defp trace_map(trace) when is_map(trace), do: trace
  defp trace_map(_trace), do: %{}

  defp map_value(value) when is_map(value), do: value
  defp map_value(value) when is_list(value), do: Map.new(value)
  defp map_value(_value), do: %{}

  defp scrub_removed_metadata_keys(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {key, _value} -> to_string(key) in @removed_metadata_keys end)
    |> Map.new()
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end
end
