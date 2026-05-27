defmodule BeamWeaver.Runnable.WithTypes do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Runnable

  defstruct [:runnable, input_schema: nil, output_schema: nil]

  @impl true
  def invoke(%__MODULE__{runnable: runnable}, input, opts),
    do: Runnable.invoke(runnable, input, opts)

  @impl true
  def batch(%__MODULE__{runnable: runnable}, inputs, opts),
    do: Runnable.batch(runnable, inputs, opts)

  @impl true
  def stream(%__MODULE__{runnable: runnable}, input, opts),
    do: Runnable.stream(runnable, input, opts)

  @impl true
  def transform(%__MODULE__{runnable: runnable}, input, opts),
    do: Runnable.transform(runnable, input, opts)
end

defimpl BeamWeaver.Runnable.Introspect, for: BeamWeaver.Runnable.WithTypes do
  def graph(%{runnable: runnable}, opts), do: BeamWeaver.Runnable.get_graph(runnable, opts)
  def input_schema(%{input_schema: nil}), do: %{"type" => "any"}
  def input_schema(%{input_schema: schema}), do: schema
  def output_schema(%{output_schema: nil}), do: %{"type" => "any"}
  def output_schema(%{output_schema: schema}), do: schema
  def config_specs(%{runnable: runnable}), do: BeamWeaver.Runnable.config_specs(runnable)
end
