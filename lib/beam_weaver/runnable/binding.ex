defmodule BeamWeaver.Runnable.Binding do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Runnable

  defstruct [:runnable, bound_opts: []]

  @impl true
  def invoke(%__MODULE__{runnable: runnable, bound_opts: bound_opts}, input, opts) do
    Runnable.invoke(runnable, input, Keyword.merge(bound_opts, opts))
  end

  @impl true
  def batch(%__MODULE__{runnable: runnable, bound_opts: bound_opts}, inputs, opts) do
    Runnable.batch(runnable, inputs, Keyword.merge(bound_opts, opts))
  end

  @impl true
  def stream(%__MODULE__{runnable: runnable, bound_opts: bound_opts}, input, opts) do
    Runnable.stream(runnable, input, Keyword.merge(bound_opts, opts))
  end

  @impl true
  def transform(%__MODULE__{runnable: runnable, bound_opts: bound_opts}, input, opts) do
    Runnable.transform(runnable, input, Keyword.merge(bound_opts, opts))
  end
end

defimpl BeamWeaver.Runnable.Spec, for: BeamWeaver.Runnable.Binding do
  def to_spec(%{runnable: runnable, bound_opts: opts}) do
    with {:ok, spec} <- BeamWeaver.Runnable.to_spec(runnable) do
      {:ok, %{"type" => "binding", "runnable" => spec, "opts" => Map.new(opts)}}
    end
  end
end
