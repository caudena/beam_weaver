defmodule BeamWeaver.Runnable.Config do
  @moduledoc """
  Normalized runtime configuration for runnable execution.

  This is BeamWeaver's Elixir-native equivalent of LangChain RunnableConfig.
  It is plain data and is propagated through runnable composition.
  """

  alias BeamWeaver.Core.ID

  defstruct tags: [],
            metadata: %{},
            run_name: nil,
            run_id: nil,
            max_concurrency: System.schedulers_online(),
            recursion_limit: 25,
            configurable: %{},
            context: nil,
            opts: []

  @metadata_copy_keys [:model, :checkpoint_ns]
  @known_opt_keys [
    :config,
    :tags,
    :metadata,
    :run_name,
    :run_id,
    :max_concurrency,
    :recursion_limit,
    :configurable,
    :context,
    :task_supervisor
  ]

  @type t :: %__MODULE__{
          tags: [String.t() | atom()],
          metadata: map(),
          run_name: String.t() | atom() | nil,
          run_id: String.t() | nil,
          max_concurrency: pos_integer(),
          recursion_limit: non_neg_integer(),
          configurable: map(),
          context: term(),
          opts: keyword()
        }

  @spec normalize(keyword() | t()) :: t()
  def normalize(%__MODULE__{} = config), do: config

  def normalize(opts) when is_list(opts) do
    base =
      case Keyword.get(opts, :config) do
        %__MODULE__{} = config -> config
        config when is_map(config) -> from_map(config)
        _other -> %__MODULE__{}
      end

    configurable =
      base.configurable
      |> merge_map_opt(opts, :configurable)
      |> copy_top_level_configurable(opts)

    metadata =
      base.metadata
      |> merge_map_opt(opts, :metadata)
      |> copy_config_metadata(configurable)

    %__MODULE__{
      base
      | tags: merge_list_opt(base.tags, opts, :tags),
        metadata: metadata,
        run_name: Keyword.get(opts, :run_name, base.run_name),
        run_id: Keyword.get(opts, :run_id, base.run_id || new_run_id()),
        max_concurrency: positive_int(Keyword.get(opts, :max_concurrency, base.max_concurrency)),
        recursion_limit: non_negative_int(Keyword.get(opts, :recursion_limit, base.recursion_limit)),
        configurable: configurable,
        context: Keyword.get(opts, :context, base.context),
        opts: opts
    }
  end

  @spec to_opts(t()) :: keyword()
  def to_opts(%__MODULE__{} = config) do
    Keyword.merge(config.opts,
      config: config,
      tags: config.tags,
      metadata: config.metadata,
      run_name: config.run_name,
      run_id: config.run_id,
      max_concurrency: config.max_concurrency,
      recursion_limit: config.recursion_limit,
      configurable: config.configurable,
      context: config.context
    )
  end

  @spec merge(keyword() | t(), keyword()) :: keyword()
  def merge(opts, extra) do
    opts
    |> normalize()
    |> Map.from_struct()
    |> Map.merge(Map.new(extra))
    |> Enum.into([])
  end

  @doc """
  Returns metadata that is safe to inherit into tracing/listener runs.

  Explicit metadata wins over configurable and provider-level options. Secret,
  private, nil, and nested values are intentionally not propagated.
  """
  @spec inheritable_metadata(keyword() | t()) :: map()
  def inheritable_metadata(config_or_opts) do
    config = normalize(config_or_opts)

    config.opts
    |> safe_provider_opts()
    |> Map.merge(safe_configurable(config.configurable))
    |> Map.merge(config.metadata)
  end

  defp from_map(map) do
    configurable =
      map
      |> Map.get(:configurable, Map.get(map, "configurable", %{}))
      |> map_value()
      |> copy_map_top_level_configurable(map)

    %__MODULE__{
      tags: list_value(Map.get(map, :tags, Map.get(map, "tags", []))),
      metadata:
        map
        |> Map.get(:metadata, Map.get(map, "metadata", %{}))
        |> map_value()
        |> copy_config_metadata(configurable),
      run_name: Map.get(map, :run_name, Map.get(map, "run_name")),
      run_id: Map.get(map, :run_id, Map.get(map, "run_id")),
      max_concurrency: positive_int(Map.get(map, :max_concurrency, Map.get(map, "max_concurrency", 1))),
      recursion_limit: non_negative_int(Map.get(map, :recursion_limit, Map.get(map, "recursion_limit", 25))),
      configurable: configurable,
      context: Map.get(map, :context, Map.get(map, "context")),
      opts: []
    }
  end

  defp merge_list_opt(base, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, ^base} -> list_value(base)
      {:ok, value} -> list_value(base) ++ list_value(value)
      :error -> list_value(base)
    end
  end

  defp merge_map_opt(base, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, ^base} -> map_value(base)
      {:ok, value} -> Map.merge(map_value(base), map_value(value))
      :error -> map_value(base)
    end
  end

  defp list_value(value) when is_list(value), do: value
  defp list_value(nil), do: []
  defp list_value(value), do: [value]
  defp map_value(value) when is_map(value), do: value
  defp map_value(_value), do: %{}

  defp copy_top_level_configurable(configurable, opts) do
    Enum.reduce(@metadata_copy_keys, configurable, fn key, acc ->
      case Keyword.fetch(opts, key) do
        {:ok, nil} -> acc
        {:ok, value} -> put_new_configurable(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp copy_map_top_level_configurable(configurable, map) do
    Enum.reduce(@metadata_copy_keys, configurable, fn key, acc ->
      value = Map.get(map, key) || Map.get(map, to_string(key))
      if is_nil(value), do: acc, else: put_new_configurable(acc, key, value)
    end)
  end

  defp copy_config_metadata(metadata, configurable) do
    Enum.reduce(@metadata_copy_keys, metadata, fn key, acc ->
      case fetch_configurable(configurable, key) do
        nil -> acc
        value -> put_new_metadata(acc, key, value)
      end
    end)
  end

  defp fetch_configurable(configurable, key) do
    Map.get(configurable, key) || Map.get(configurable, to_string(key))
  end

  defp put_new_configurable(configurable, key, value) do
    cond do
      Map.has_key?(configurable, key) -> configurable
      Map.has_key?(configurable, to_string(key)) -> configurable
      true -> Map.put(configurable, key, value)
    end
  end

  defp put_new_metadata(metadata, key, value) do
    cond do
      Map.has_key?(metadata, key) -> metadata
      Map.has_key?(metadata, to_string(key)) -> metadata
      true -> Map.put(metadata, key, value)
    end
  end

  defp safe_provider_opts(opts) when is_list(opts) do
    opts
    |> Keyword.drop(@known_opt_keys ++ @metadata_copy_keys)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if trace_metadata_key?(key) and trace_metadata_value?(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp safe_configurable(configurable) do
    Enum.reduce(configurable, %{}, fn {key, value}, acc ->
      if trace_metadata_key?(key) and trace_metadata_value?(value) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp trace_metadata_key?(key) do
    key = to_string(key)
    not String.contains?(key, "api_key") and not String.starts_with?(key, "__")
  end

  defp trace_metadata_value?(nil), do: false
  defp trace_metadata_value?(value) when is_binary(value), do: true
  defp trace_metadata_value?(value) when is_number(value), do: true
  defp trace_metadata_value?(value) when is_boolean(value), do: true
  defp trace_metadata_value?(value) when is_atom(value), do: true
  defp trace_metadata_value?(_value), do: false

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: 1
  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value), do: 25

  defp new_run_id do
    ID.uuidv7()
  end
end
