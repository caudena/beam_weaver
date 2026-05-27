defmodule BeamWeaver.Runnable.Pick do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error

  defstruct keys: []

  @impl true
  def invoke(%__MODULE__{keys: [key]}, input, _opts) when is_map(input) do
    if Map.has_key?(input, key) do
      {:ok, Map.fetch!(input, key)}
    else
      {:error, Error.new(:missing_key, "pick key is missing", %{key: key})}
    end
  end

  def invoke(%__MODULE__{keys: keys}, input, _opts) when is_map(input) do
    missing = Enum.reject(keys, &Map.has_key?(input, &1))

    if missing == [] do
      {:ok, Map.take(input, keys)}
    else
      {:error, Error.new(:missing_key, "pick keys are missing", %{missing: missing})}
    end
  end

  def invoke(%__MODULE__{}, _input, _opts),
    do: {:error, Error.new(:invalid_runnable_input, "pick requires a map input")}
end

defimpl BeamWeaver.Runnable.Spec, for: BeamWeaver.Runnable.Pick do
  def to_spec(%{keys: keys}), do: {:ok, %{"type" => "pick", "keys" => keys}}
end
