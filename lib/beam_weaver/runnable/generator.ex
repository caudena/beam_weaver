defmodule BeamWeaver.Runnable.Generator do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error

  defstruct [:fun, :name]

  @impl true
  def invoke(%__MODULE__{} = generator, input, opts) do
    with {:ok, stream} <- stream(generator, input, opts) do
      {:ok, Enum.to_list(stream)}
    end
  end

  @impl true
  def stream(%__MODULE__{fun: fun}, input, _opts) when is_function(fun, 1) do
    normalize_stream(fun.(input))
  rescue
    exception -> {:error, Error.new(:runnable_exception, Exception.message(exception))}
  end

  def stream(%__MODULE__{fun: fun}, input, opts) when is_function(fun, 2) do
    normalize_stream(fun.(input, opts))
  rescue
    exception -> {:error, Error.new(:runnable_exception, Exception.message(exception))}
  end

  def stream(%__MODULE__{}, _input, _opts),
    do: {:error, Error.new(:invalid_runnable, "generator runnable requires a function")}

  @impl true
  def transform(%__MODULE__{fun: fun}, input, _opts) when is_function(fun, 1) do
    normalize_stream(fun.(input))
  rescue
    exception -> {:error, Error.new(:runnable_exception, Exception.message(exception))}
  end

  def transform(%__MODULE__{fun: fun}, input, opts) when is_function(fun, 2) do
    normalize_stream(fun.(input, opts))
  rescue
    exception -> {:error, Error.new(:runnable_exception, Exception.message(exception))}
  end

  defp normalize_stream({:ok, stream}), do: normalize_stream(stream)
  defp normalize_stream({:error, %Error{} = error}), do: {:error, error}

  defp normalize_stream(stream),
    do: if(Enumerable.impl_for(stream), do: {:ok, stream}, else: {:ok, [stream]})
end
