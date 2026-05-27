defmodule BeamWeaver.Runnable.WithConfig do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Runnable

  defstruct [:runnable, opts: []]

  @impl true
  def invoke(%__MODULE__{runnable: runnable, opts: defaults}, input, opts) do
    Runnable.invoke(runnable, input, merge(defaults, opts))
  end

  @impl true
  def batch(%__MODULE__{runnable: runnable, opts: defaults}, inputs, opts) do
    Runnable.batch(runnable, inputs, merge(defaults, opts))
  end

  @impl true
  def stream(%__MODULE__{runnable: runnable, opts: defaults}, input, opts) do
    Runnable.stream(runnable, input, merge(defaults, opts))
  end

  @impl true
  def transform(%__MODULE__{runnable: runnable, opts: defaults}, input, opts) do
    Runnable.transform(runnable, input, merge(defaults, opts))
  end

  defp merge(defaults, opts) do
    base = BeamWeaver.Runnable.Config.normalize(defaults)

    opts
    |> Keyword.put(:config, base)
    |> BeamWeaver.Runnable.Config.normalize()
    |> BeamWeaver.Runnable.Config.to_opts()
  end
end

defimpl BeamWeaver.Runnable.Spec, for: BeamWeaver.Runnable.WithConfig do
  def to_spec(%{runnable: runnable, opts: opts}) do
    with {:ok, spec} <- BeamWeaver.Runnable.to_spec(runnable) do
      {:ok, %{"type" => "with_config", "runnable" => spec, "opts" => Map.new(opts)}}
    end
  end
end
