defmodule BeamWeaver.Runnable.Configured do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable
  alias BeamWeaver.Runnable.ConfigField
  alias BeamWeaver.Runnable.ConfigSpec

  defstruct [:runnable, fields: %{}]

  @impl true
  def invoke(%__MODULE__{} = configured, input, opts) do
    with {:ok, runnable} <- configured_runnable(configured, opts) do
      Runnable.invoke(runnable, input, opts)
    end
  end

  @impl true
  def batch(%__MODULE__{} = configured, inputs, opts) do
    with {:ok, runnable} <- configured_runnable(configured, opts) do
      Runnable.batch(runnable, inputs, opts)
    end
  end

  @impl true
  def stream(%__MODULE__{} = configured, input, opts) do
    with {:ok, runnable} <- configured_runnable(configured, opts) do
      Runnable.stream(runnable, input, opts)
    end
  end

  @impl true
  def transform(%__MODULE__{} = configured, input, opts) do
    with {:ok, runnable} <- configured_runnable(configured, opts) do
      Runnable.transform(runnable, input, opts)
    end
  end

  def config_specs(%__MODULE__{fields: fields}) do
    fields
    |> Map.values()
    |> Enum.map(&ConfigSpec.from_field/1)
  end

  defp configured_runnable(%__MODULE__{runnable: runnable, fields: fields}, opts) do
    config = BeamWeaver.Runnable.Config.normalize(opts)

    values =
      fields
      |> Enum.reduce(%{}, fn {_name, %ConfigField{} = field}, acc ->
        case configurable_value(config.configurable, field) do
          {:ok, value} ->
            Map.put(acc, field.field, value)

          :missing ->
            if field.required do
              Map.put(acc, field.field, {:missing, field.id})
            else
              acc
            end
        end
      end)

    case Enum.find(values, fn {_field, value} -> match?({:missing, _id}, value) end) do
      {field, {:missing, id}} ->
        {:error,
         Error.new(:missing_configurable, "required configurable value is missing", %{
           field: field,
           id: id
         })}

      nil ->
        Runnable.Configurable.configure(runnable, values)
    end
  end

  defp configurable_value(configurable, %ConfigField{} = field) do
    cond do
      Map.has_key?(configurable, field.id) -> {:ok, Map.fetch!(configurable, field.id)}
      Map.has_key?(configurable, field.field) -> {:ok, Map.fetch!(configurable, field.field)}
      not is_nil(field.default) -> {:ok, field.default}
      true -> :missing
    end
  end
end

defimpl BeamWeaver.Runnable.Introspect, for: BeamWeaver.Runnable.Configured do
  def graph(%{runnable: runnable}, opts), do: BeamWeaver.Runnable.get_graph(runnable, opts)
  def input_schema(%{runnable: runnable}), do: BeamWeaver.Runnable.input_schema(runnable)
  def output_schema(%{runnable: runnable}), do: BeamWeaver.Runnable.output_schema(runnable)
  def config_specs(configured), do: BeamWeaver.Runnable.Configured.config_specs(configured)
end
