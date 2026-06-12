defmodule BeamWeaver.Runnable.Lambda do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error

  defstruct [:fun, :name]

  @impl true
  def invoke(%__MODULE__{fun: fun}, input, _opts) when is_function(fun, 1) do
    fun.(input)
  rescue
    exception -> {:error, Error.new(:runnable_exception, Exception.message(exception))}
  end

  def invoke(%__MODULE__{fun: fun}, input, opts) when is_function(fun, 2) do
    fun.(input, opts)
  rescue
    exception -> {:error, Error.new(:runnable_exception, Exception.message(exception))}
  end

  def invoke(%__MODULE__{}, _input, _opts) do
    {:error, Error.new(:invalid_runnable, "lambda runnable requires a function")}
  end

  @impl true
  def stream(%__MODULE__{} = runnable, input, opts) do
    case invoke(runnable, input, opts) do
      {:ok, output} ->
        normalize_stream(output)

      {:error, %Error{} = error} ->
        {:error, error}

      output ->
        normalize_stream(output)
    end
  end

  defp normalize_stream(output) do
    if Enumerable.impl_for(output), do: {:ok, output}, else: {:ok, [output]}
  end
end
