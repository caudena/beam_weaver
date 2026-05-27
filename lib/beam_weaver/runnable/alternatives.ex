defmodule BeamWeaver.Runnable.Alternatives do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable
  alias BeamWeaver.Runnable.ConfigSpec

  defstruct [:default, :field, alternatives: %{}, opts: []]

  @impl true
  def invoke(%__MODULE__{} = alternatives, input, opts) do
    with {:ok, runnable, opts} <- selected(alternatives, opts) do
      Runnable.invoke(runnable, input, opts)
    end
  end

  @impl true
  def batch(%__MODULE__{} = alternatives, inputs, opts) do
    with {:ok, runnable, opts} <- selected(alternatives, opts) do
      Runnable.batch(runnable, inputs, opts)
    end
  end

  @impl true
  def stream(%__MODULE__{} = alternatives, input, opts) do
    with {:ok, runnable, opts} <- selected(alternatives, opts) do
      Runnable.stream(runnable, input, opts)
    end
  end

  @impl true
  def transform(%__MODULE__{} = alternatives, input, opts) do
    with {:ok, runnable, opts} <- selected(alternatives, opts) do
      Runnable.transform(runnable, input, opts)
    end
  end

  def config_specs(%__MODULE__{
        field: field,
        default: default,
        alternatives: runnable_alts,
        opts: opts
      }) do
    id = field_id(field)
    default_key = Keyword.get(opts, :default_key, "default") |> to_string()
    prefix? = Keyword.get(opts, :prefix_keys, false)

    select_spec =
      %ConfigSpec{
        id: id,
        field: field,
        name: to_string(field),
        description: "Selects a runnable alternative"
      }

    child_specs =
      child_config_specs(default, maybe_prefix(prefix?, id, default_key)) ++
        Enum.flat_map(runnable_alts, fn {key, runnable} ->
          if is_function(runnable, 0) do
            []
          else
            child_config_specs(runnable, maybe_prefix(prefix?, id, key))
          end
        end)

    uniq_specs([select_spec | child_specs])
  end

  defp selected(%__MODULE__{} = alternatives, opts) do
    config = BeamWeaver.Runnable.Config.normalize(opts)
    id = field_id(alternatives.field)
    default_key = Keyword.get(alternatives.opts, :default_key, "default") |> to_string()
    selection = Map.get(config.configurable, id, Map.get(config.configurable, alternatives.field))
    selection_key = if is_nil(selection), do: default_key, else: normalize_key(selection)
    opts = maybe_strip_prefixed_config(alternatives, opts, selection_key)

    if selection_key == default_key do
      {:ok, alternatives.default, opts}
    else
      case Map.fetch(normalize_alternatives(alternatives.alternatives), selection_key) do
        {:ok, runnable} ->
          {:ok, lazy(runnable), opts}

        :error ->
          unknown(selection_key, Map.keys(normalize_alternatives(alternatives.alternatives)))
      end
    end
  end

  defp maybe_strip_prefixed_config(
         %__MODULE__{opts: opts, field: field},
         call_opts,
         selection_key
       ) do
    if Keyword.get(opts, :prefix_keys, false) do
      config = BeamWeaver.Runnable.Config.normalize(call_opts)
      prefix = "#{field_id(field)}==#{selection_key}/"

      configurable =
        Map.new(config.configurable, fn {key, value} ->
          key = to_string(key)

          if String.starts_with?(key, prefix) do
            {String.replace_prefix(key, prefix, ""), value}
          else
            {key, value}
          end
        end)

      put_configurable(call_opts, configurable)
    else
      call_opts
    end
  end

  defp put_configurable(call_opts, configurable) when is_list(call_opts),
    do: Keyword.put(call_opts, :configurable, configurable)

  defp put_configurable(call_opts, configurable) when is_map(call_opts),
    do: Map.put(call_opts, :configurable, configurable)

  defp lazy(fun) when is_function(fun, 0), do: fun.()
  defp lazy(runnable), do: runnable

  defp child_config_specs(runnable, nil), do: BeamWeaver.Runnable.config_specs(runnable)

  defp child_config_specs(runnable, prefix) do
    runnable
    |> BeamWeaver.Runnable.config_specs()
    |> Enum.map(fn spec -> %{spec | id: "#{prefix}/#{spec.id}"} end)
  end

  defp maybe_prefix(false, _id, _key), do: nil
  defp maybe_prefix(true, id, key), do: "#{id}==#{normalize_key(key)}"

  defp uniq_specs(specs) do
    specs
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.id)
    |> Enum.reverse()
  end

  defp normalize_alternatives(alternatives) do
    Map.new(alternatives, fn {key, runnable} -> {normalize_key(key), runnable} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
  defp field_id(%{id: id}), do: to_string(id)
  defp field_id(field), do: to_string(field)

  defp unknown(key, choices) do
    {:error,
     Error.new(:unknown_runnable_alternative, "unknown runnable alternative", %{
       selection: key,
       choices: choices
     })}
  end
end

defimpl BeamWeaver.Runnable.Introspect, for: BeamWeaver.Runnable.Alternatives do
  alias BeamWeaver.Runnable.Graph

  def graph(%{default: default, alternatives: alternatives, field: field}, _opts) do
    root = "alternative_#{to_string(field)}"

    nodes =
      alternatives
      |> Map.keys()
      |> Enum.map(fn key -> {"alt_#{key}", %{label: "alternative:#{key}"}} end)
      |> Map.new()
      |> Map.put(root, %{label: "Alternatives"})
      |> Map.put("default", %{label: Graph.label(default)})

    edges =
      [{root, "default", "default"}] ++
        Enum.map(alternatives, fn {key, _runnable} -> {root, "alt_#{key}", to_string(key)} end)

    %Graph{nodes: nodes, edges: edges}
  end

  def input_schema(%{default: default}), do: BeamWeaver.Runnable.input_schema(default)
  def output_schema(%{default: default}), do: BeamWeaver.Runnable.output_schema(default)
  def config_specs(alternatives), do: BeamWeaver.Runnable.Alternatives.config_specs(alternatives)
end
